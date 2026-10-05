param(
    [Parameter(Mandatory = $true)]
    [string]$BundledPythonPath,
    [string]$PythonPath = "python",
    [string]$InnoCompiler = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-RepoRoot {
    $scriptDir = Split-Path -Parent $PSCommandPath
    return (Resolve-Path (Join-Path $scriptDir "..")).Path
}

function Find-Tool {
    param(
        [string]$ToolName,
        [string[]]$Candidates
    )

    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return (Resolve-Path $candidate).Path
        }
    }

    $command = Get-Command $ToolName -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) {
        return $command.Source
    }

    throw "Could not find $ToolName."
}

function Write-Sha256File {
    param([string]$Path)

    $hash = (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLowerInvariant()
    $shaPath = "$Path.sha256"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($shaPath, "$hash  $(Split-Path -Leaf $Path)`n", $utf8NoBom)
    return $hash
}

function Test-PythonHttpsRuntime {
    param([string]$PythonExe)

    if (-not (Test-Path $PythonExe)) {
        throw "Python HTTPS verification target is missing: $PythonExe"
    }

    $code = @'
import json
import pathlib
import ssl
import sys
import urllib.request

handlers = [type(h).__name__ for h in urllib.request.build_opener().handlers]
result = {
    "executable": str(pathlib.Path(sys.executable).resolve()),
    "openssl": ssl.OPENSSL_VERSION,
    "handlers": handlers,
}
print(json.dumps(result, ensure_ascii=False))
if "HTTPSHandler" not in handlers:
    raise SystemExit("urllib HTTPSHandler is unavailable")
'@
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $verifyScript = Join-Path ([System.IO.Path]::GetTempPath()) ("latexsnipper_verify_python_https_{0}.py" -f ([System.Guid]::NewGuid().ToString("N")))
    try {
        [System.IO.File]::WriteAllText($verifyScript, $code, $utf8NoBom)
        $verifyJson = & $PythonExe $verifyScript
        if ($LASTEXITCODE -ne 0) {
            throw "Python HTTPS verification failed for $PythonExe"
        }
        $verify = $verifyJson | ConvertFrom-Json
        Write-Host "Python HTTPS runtime verified:"
        Write-Host "  executable: $($verify.executable)"
        Write-Host "  openssl: $($verify.openssl)"
    }
    finally {
        if (Test-Path $verifyScript) {
            Remove-Item -LiteralPath $verifyScript -Force
        }
    }
}

function Normalize-BundledPythonSeed {
    param([string]$SeedRoot)

    $pythonExe = Join-Path $seedRoot "python.exe"
    if (-not (Test-Path $pythonExe)) {
        throw "Bundled Python seed is missing python.exe: $pythonExe"
    }

    $pyvenvCfg = Join-Path $seedRoot "pyvenv.cfg"
    if (Test-Path $pyvenvCfg) {
        Remove-Item -LiteralPath $pyvenvCfg -Force
    }

    $pthPath = Join-Path $seedRoot "python311._pth"
    $pthLines = @(
        "python311.zip",
        ".",
        "DLLs",
        "Lib",
        "Lib\site-packages",
        "import site"
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($pthPath, (($pthLines -join "`n") + "`n"), $utf8NoBom)

    $sitePackages = Join-Path $seedRoot "Lib\site-packages"
    if (Test-Path $sitePackages) {
        $keepNames = @(
            "_distutils_hack",
            "distutils-precedence.pth",
            "packaging",
            "pip",
            "pkg_resources",
            "README.txt",
            "setuptools",
            "wheel"
        )
        $keepPrefixes = @(
            "packaging-",
            "pip-",
            "setuptools-",
            "wheel-"
        )
        foreach ($child in Get-ChildItem -LiteralPath $sitePackages -Force) {
            $keep = $keepNames -contains $child.Name
            foreach ($prefix in $keepPrefixes) {
                if ($child.Name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $keep = $true
                    break
                }
            }
            if (-not $keep) {
                Remove-Item -LiteralPath $child.FullName -Recurse -Force
                Write-Host "Pruned bundled Python package: $($child.Name)"
            }
        }
    }

    $scriptsDir = Join-Path $seedRoot "Scripts"
    if (Test-Path $scriptsDir) {
        foreach ($child in Get-ChildItem -LiteralPath $scriptsDir -Force) {
            $name = $child.Name.ToLowerInvariant()
            if ($name.StartsWith("pip") -or $name.StartsWith("easy_install") -or $name.StartsWith("wheel")) {
                continue
            }
            Remove-Item -LiteralPath $child.FullName -Recurse -Force
            Write-Host "Pruned bundled Python script: $($child.Name)"
        }
    }

    $removePaths = @(
        "include",
        "libs",
        "tcl",
        "NEWS.txt",
        "Lib\venv",
        "Lib\idlelib",
        "Lib\lib2to3",
        "Lib\pydoc_data",
        "Lib\tkinter",
        "Lib\turtledemo",
        "Lib\unittest",
        "Lib\ctypes\test",
        "Lib\distutils\tests",
        "Lib\doctest.py",
        "Lib\pdb.py",
        "Lib\pydoc.py",
        "Lib\turtle.py",
        "DLLs\_ctypes_test.pyd",
        "DLLs\_testbuffer.pyd",
        "DLLs\_testcapi.pyd",
        "DLLs\_testconsole.pyd",
        "DLLs\_testimportmultiple.pyd",
        "DLLs\_testinternalcapi.pyd",
        "DLLs\_testmultiphase.pyd",
        "DLLs\_tkinter.pyd",
        "DLLs\tcl86t.dll",
        "DLLs\tk86t.dll",
        "DLLs\py.ico",
        "DLLs\pyc.ico",
        "DLLs\pyd.ico",
        "DLLs\python_lib.cat",
        "DLLs\python_tools.cat"
    )
    foreach ($relativePath in $removePaths) {
        $target = Join-Path $seedRoot $relativePath
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
            Write-Host "Pruned bundled Python runtime artifact: $relativePath"
        }
    }

    Remove-PythonCache -Root $seedRoot

    $verifyCode = @'
import json
import importlib
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
paths = [pathlib.Path(p).resolve() for p in sys.path]
bad = [str(p) for p in paths if not (p == root or root in p.parents)]
toolchain = {}
for module_name in ("ensurepip", "setuptools", "wheel", "packaging", "pip"):
    module = importlib.import_module(module_name)
    toolchain[module_name] = getattr(module, "__version__", "available")
pip_check = subprocess.run(
    [sys.executable, "-m", "pip", "--version"],
    check=False,
    capture_output=True,
    text=True,
)
result = {
    "executable": str(pathlib.Path(sys.executable).resolve()),
    "prefix": str(pathlib.Path(sys.prefix).resolve()),
    "base_prefix": str(pathlib.Path(sys.base_prefix).resolve()),
    "paths": [str(p) for p in paths],
    "outside_paths": bad,
    "toolchain": toolchain,
    "pip": pip_check.stdout.strip(),
}
print(json.dumps(result, ensure_ascii=False))
if pathlib.Path(sys.prefix).resolve() != root:
    raise SystemExit("sys.prefix does not point to bundled python311")
if pathlib.Path(sys.base_prefix).resolve() != root:
    raise SystemExit("sys.base_prefix does not point to bundled python311")
if bad:
    raise SystemExit("sys.path contains paths outside bundled python311")
if pip_check.returncode != 0:
    raise SystemExit(f"bundled pip is not executable: {pip_check.stderr.strip()}")
'@
    $verifyScript = Join-Path ([System.IO.Path]::GetTempPath()) ("latexsnipper_verify_python_seed_{0}.py" -f ([System.Guid]::NewGuid().ToString("N")))
    try {
        [System.IO.File]::WriteAllText($verifyScript, $verifyCode, $utf8NoBom)
        $verifyJson = & $pythonExe $verifyScript $seedRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Bundled Python seed verification failed."
        }
    }
    finally {
        if (Test-Path $verifyScript) {
            Remove-Item -LiteralPath $verifyScript -Force
        }
    }
    $verify = $verifyJson | ConvertFrom-Json
    Write-Host "Bundled Python seed normalized:"
    Write-Host "  executable: $($verify.executable)"
    Write-Host "  prefix: $($verify.prefix)"
    Write-Host "  pip: $($verify.pip)"
    Test-PythonHttpsRuntime -PythonExe $pythonExe
    Remove-PythonCache -Root $seedRoot
}

function Remove-PythonCache {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        return
    }
    Get-ChildItem -LiteralPath $Root -Recurse -Force -Directory -Filter "__pycache__" |
        Remove-Item -Recurse -Force
    Get-ChildItem -LiteralPath $Root -Recurse -Force -File |
        Where-Object { $_.Extension -in @(".pyc", ".pyo") } |
        Remove-Item -Force
}

# --- zlibwapi.dll ---------------------------------------------------------
# cuDNN 8 imports zlibwapi.dll by ordinal from its convolver DLL
# (cudnn_cnn_infer64_8.dll). A stock CUDA/cuDNN install does not include it, and
# without it the GPU backend reports CUDA as ready and then dies with
# STATUS_STACK_BUFFER_OVERRUN on the first convolution.
#
# It is built here from official zlib source rather than vendored as a binary,
# so the shipped DLL is reproducible and carries the export ordinals cuDNN
# imports. packaging/windows/zlibwapi.def pins that ordinal layout.

$ZlibVersion = "1.3.2"
$ZlibSourceUri = "https://zlib.net/zlib-$ZlibVersion.tar.gz"
$ZlibSourceSha256 = "bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"

$ZlibCompileUnits = @(
    "adler32", "compress", "crc32", "deflate", "gzclose", "gzlib", "gzread",
    "gzwrite", "infback", "inffast", "inflate", "inftrees", "trees", "uncompr",
    "zutil"
)

function Find-MsvcEnvironment {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw "vswhere.exe not found. Install Visual Studio Build Tools with the C++ x64 toolset to build zlibwapi.dll."
    }
    $installation = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $installation) {
        throw "No Visual Studio installation providing the MSVC x64 toolset was found."
    }
    $vcvars = Join-Path $installation "VC\Auxiliary\Build\vcvars64.bat"
    if (-not (Test-Path -LiteralPath $vcvars)) {
        throw "vcvars64.bat not found under $installation"
    }
    return $vcvars
}

function Install-ZlibWapiDll {
    param(
        [Parameter(Mandatory = $true)][string]$SeedRoot,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$PythonExe
    )

    $defFile = Join-Path $RepoRoot "packaging\windows\zlibwapi.def"
    if (-not (Test-Path -LiteralPath $defFile)) {
        throw "zlibwapi export definition not found: $defFile"
    }
    $verifier = Join-Path $RepoRoot "tools\verify_zlibwapi_ordinals.py"
    if (-not (Test-Path -LiteralPath $verifier)) {
        throw "zlibwapi ordinal verifier not found: $verifier"
    }

    $vcvars = Find-MsvcEnvironment
    $work = Join-Path $env:RUNNER_TEMP ("latexsnipper-zlib-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $archive = Join-Path $work "zlib.tar.gz"
        Write-Host "Fetching official zlib $ZlibVersion source: $ZlibSourceUri"
        Invoke-WebRequest -Uri $ZlibSourceUri -OutFile $archive

        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
        if ($hash -ne $ZlibSourceSha256) {
            throw "zlib source checksum mismatch: expected $ZlibSourceSha256 but got $hash"
        }

        $extractRoot = Join-Path $work "source"
        New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
        & tar -xzf $archive -C $extractRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Extracting the zlib source failed with exit code $LASTEXITCODE."
        }

        $zlibSource = Join-Path $extractRoot "zlib-$ZlibVersion"
        if (-not (Test-Path -LiteralPath (Join-Path $zlibSource "zlib.h"))) {
            throw "Unexpected zlib source layout, zlib.h not found under: $zlibSource"
        }

        $buildDir = Join-Path $work "build"
        New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
        $output = Join-Path $buildDir "zlibwapi.dll"

        # Compile through a batch file: cl and link need the environment that
        # vcvars64.bat sets up, and cmd keeps the quoting readable.
        $sourceArgs = ($ZlibCompileUnits | ForEach-Object { "`"$zlibSource\$_.c`"" }) -join " "
        $objectArgs = ($ZlibCompileUnits | ForEach-Object { "$_.obj" }) -join " "
        $batch = @(
            "@echo off",
            "call `"$vcvars`" >nul",
            "if errorlevel 1 exit /b 1",
            "cd /d `"$buildDir`"",
            "cl /nologo /O2 /MD /D_CRT_SECURE_NO_DEPRECATE /D_CRT_NONSTDC_NO_DEPRECATE /I`"$zlibSource`" /c $sourceArgs",
            "if errorlevel 1 exit /b 2",
            "link /nologo /DLL /INCREMENTAL:NO /DEF:`"$defFile`" /OUT:`"$output`" $objectArgs",
            "if errorlevel 1 exit /b 3"
        ) -join "`r`n"
        $batchPath = Join-Path $work "build-zlibwapi.cmd"
        Set-Content -LiteralPath $batchPath -Value $batch -Encoding ASCII

        Write-Host "Compiling zlibwapi.dll from official zlib $ZlibVersion source..."
        & cmd.exe /c $batchPath
        if ($LASTEXITCODE -ne 0) {
            throw "Building zlibwapi.dll failed with exit code $LASTEXITCODE."
        }
        if (-not (Test-Path -LiteralPath $output)) {
            throw "zlibwapi.dll was not produced at $output"
        }

        # Export ordinals are an ABI contract with cuDNN: a DLL that merely loads
        # but resolves the wrong functions corrupts memory instead of failing.
        & $PythonExe $verifier $output
        if ($LASTEXITCODE -ne 0) {
            throw "zlibwapi.dll failed the cuDNN ordinal check."
        }

        Copy-Item -LiteralPath $output -Destination (Join-Path $SeedRoot "zlibwapi.dll") -Force
        Write-Host "Installed zlibwapi.dll into the bundled Python seed."
    }
    finally {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$root = Resolve-RepoRoot
$python = (Get-Command $PythonPath -CommandType Application -ErrorAction Stop |
    Select-Object -First 1).Source
$bundledPython = (Resolve-Path -LiteralPath $BundledPythonPath).Path
$runnerTemp = (Resolve-Path -LiteralPath $env:RUNNER_TEMP).Path.TrimEnd('\') + '\'
if (-not $bundledPython.StartsWith($runnerTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Bundled Python must be prepared inside RUNNER_TEMP: $bundledPython"
}
Normalize-BundledPythonSeed -SeedRoot $bundledPython
Install-ZlibWapiDll -SeedRoot $bundledPython -RepoRoot $root -PythonExe $python

$isccCandidates = @()
if ($InnoCompiler) {
    $isccCandidates += $InnoCompiler
}
if (${env:ProgramFiles(x86)}) {
    $isccCandidates += (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe")
}
if ($env:ProgramFiles) {
    $isccCandidates += (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe")
}
$iscc = Find-Tool -ToolName "ISCC.exe" -Candidates $isccCandidates

$buildName = "LaTeXSnipper"
$spec = Join-Path $root "LaTeXSnipper.spec"
$iss = Join-Path $root "Inno\latexsnipper.iss"
$distRoot = Join-Path $root "dist"
$distAppDir = Join-Path $distRoot $buildName
$pyinstallerWorkDir = Join-Path $root "build\pyinstaller_windows"
$installerOutputDir = Join-Path $root "dist\installer"

if (-not (Test-Path $spec)) {
    throw "PyInstaller spec not found: $spec"
}
if (-not (Test-Path $iss)) {
    throw "Inno Setup script not found: $iss"
}

$oldBuildName = $env:LATEXSNIPPER_BUILD_NAME
$oldBundledPython = $env:LATEXSNIPPER_BUNDLED_PYTHON
try {
    $env:LATEXSNIPPER_BUILD_NAME = $buildName
    $env:LATEXSNIPPER_BUNDLED_PYTHON = $bundledPython

    foreach ($path in @($distAppDir, $pyinstallerWorkDir)) {
        if (Test-Path -LiteralPath $path) {
            $resolvedPath = (Resolve-Path -LiteralPath $path).Path
            $expectedPrefix = $root.TrimEnd('\') + '\'
            if (-not $resolvedPath.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to remove build output outside repository: $resolvedPath"
            }
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }

    Push-Location $root
    try {
        & $python -m PyInstaller `
            --distpath $distRoot `
            --workpath $pyinstallerWorkDir `
            --clean `
            --noconfirm `
            $spec
    }
    finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) {
        throw "PyInstaller failed with exit code $LASTEXITCODE"
    }
    & (Join-Path $root "scripts\normalize_windows_crt.ps1") -DistributionRoot $distAppDir
    $distPython = Join-Path $distAppDir "_internal\deps\python311\python.exe"
    Test-PythonHttpsRuntime -PythonExe $distPython
    Remove-PythonCache -Root (Join-Path $distAppDir "_internal\deps\python311")
}
finally {
    $env:LATEXSNIPPER_BUILD_NAME = $oldBuildName
    $env:LATEXSNIPPER_BUNDLED_PYTHON = $oldBundledPython
}

$appExe = Join-Path $distAppDir "$buildName.exe"
if (-not (Test-Path $appExe)) {
    throw "PyInstaller output exe not found: $appExe"
}

if (Test-Path $installerOutputDir) {
    Get-ChildItem -LiteralPath $installerOutputDir -Filter "LaTeXSnipper_*_amd64.exe" -File |
        Remove-Item -Force
}
& $iscc $iss
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup failed with exit code $LASTEXITCODE"
}

$installer = Get-ChildItem -LiteralPath $installerOutputDir -Filter "LaTeXSnipper_*_amd64.exe" -File |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
if (-not $installer -or -not (Test-Path -LiteralPath $installer.FullName)) {
    throw "Installer output not found in: $installerOutputDir"
}

$hash = Write-Sha256File -Path $installer.FullName

Write-Host ""
Write-Host "GitHub release installer created:"
Write-Host "  $($installer.FullName)"
Write-Host "SHA256:"
Write-Host "  $hash"
Write-Host "Signing is handled by the release workflow through SignPath."
