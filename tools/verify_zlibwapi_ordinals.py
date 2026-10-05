#!/usr/bin/env python3
"""Verify that a built zlibwapi.dll honours the ordinals cuDNN imports from.

cuDNN 8 on Windows imports zlibwapi.dll BY ORDINAL. A DLL whose export ordinals
are laid out differently still loads successfully -- and then cuDNN calls the
wrong function through the wrong signature, corrupting memory. This check turns
that silent failure into a build error.

Two independent assertions are made:

1. The cuDNN ABI contract. Ordinals 6/19/20/21 must be
   deflateEnd/inflate/inflateEnd/inflateInit2_. This is hard-coded here on
   purpose: it is the contract, and this file must be able to contradict
   packaging/windows/zlibwapi.def if that file is ever edited wrongly.
2. Consistency with packaging/windows/zlibwapi.def, so the built binary and the
   file the build applied cannot drift apart.

Usage:
    python tools/verify_zlibwapi_ordinals.py <zlibwapi.dll> [--def <path.def>]

Exits 0 when every check passes, 1 otherwise. Pure standard library so it can
run on any build machine or CI runner without extra dependencies.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

# The contract cuDNN depends on. Verified against CUDA 11.8 cuDNN 8.x on
# Windows x64: cudnn_cnn_infer64_8.dll imports exactly these four ordinals.
CUDNN_REQUIRED_ORDINALS = {
    6: "deflateEnd",
    19: "inflate",
    20: "inflateEnd",
    21: "inflateInit2_",
}

IMAGE_FILE_MACHINE_AMD64 = 0x8664


class PEError(RuntimeError):
    """Raised when the file is not a PE image we can read."""


def _u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def _u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


class PEImage:
    """Just enough PE parsing to read the export directory."""

    def __init__(self, path: Path):
        self.path = path
        self.data = path.read_bytes()
        if self.data[:2] != b"MZ":
            raise PEError(f"{path} is not a PE image (missing MZ header)")
        self.pe_offset = _u32(self.data, 0x3C)
        if self.data[self.pe_offset:self.pe_offset + 4] != b"PE\0\0":
            raise PEError(f"{path} is not a PE image (missing PE signature)")

        coff = self.pe_offset + 4
        self.machine = _u16(self.data, coff)
        section_count = _u16(self.data, coff + 2)
        optional_size = _u16(self.data, coff + 16)
        optional = coff + 20
        magic = _u16(self.data, optional)
        self.is_64bit = magic == 0x20B
        directories = optional + (112 if self.is_64bit else 96)
        directory_count = _u32(self.data, directories - 4)
        self.directories = [
            (_u32(self.data, directories + i * 8), _u32(self.data, directories + i * 8 + 4))
            for i in range(directory_count)
        ]

        self.sections = []
        section_base = optional + optional_size
        for i in range(section_count):
            base = section_base + i * 40
            self.sections.append((
                _u32(self.data, base + 12),   # VirtualAddress
                _u32(self.data, base + 16),   # SizeOfRawData
                _u32(self.data, base + 20),   # PointerToRawData
                _u32(self.data, base + 8),    # VirtualSize
            ))

    def rva_to_offset(self, rva: int) -> int | None:
        for vaddr, raw_size, raw_ptr, virtual_size in self.sections:
            if vaddr <= rva < vaddr + max(virtual_size, raw_size):
                return raw_ptr + (rva - vaddr)
        return None

    def _cstring(self, offset: int) -> str:
        end = self.data.find(b"\0", offset)
        return self.data[offset:end].decode("ascii", "replace")

    def exports(self) -> dict[int, str]:
        """Return {ordinal: name} for the exported symbols."""
        if not self.directories or self.directories[0][0] == 0:
            return {}
        offset = self.rva_to_offset(self.directories[0][0])
        if offset is None:
            return {}
        ordinal_base = _u32(self.data, offset + 16)
        name_count = _u32(self.data, offset + 24)
        names_offset = self.rva_to_offset(_u32(self.data, offset + 32))
        ordinals_offset = self.rva_to_offset(_u32(self.data, offset + 36))
        if names_offset is None or ordinals_offset is None:
            return {}

        result: dict[int, str] = {}
        for i in range(name_count):
            name_rva = _u32(self.data, names_offset + i * 4)
            name_offset = self.rva_to_offset(name_rva)
            if name_offset is None:
                continue
            name = self._cstring(name_offset)
            ordinal = ordinal_base + _u16(self.data, ordinals_offset + i * 2)
            result[ordinal] = name
        return result

    def imports(self) -> dict[str, list[str]]:
        """Return {dll_name_lower: [symbol, ...]} for the import table."""
        if len(self.directories) < 2 or self.directories[1][0] == 0:
            return {}
        offset = self.rva_to_offset(self.directories[1][0])
        if offset is None:
            return {}

        result: dict[str, list[str]] = {}
        index = 0
        pointer_size = 8 if self.is_64bit else 4
        high_bit = 1 << (63 if self.is_64bit else 31)
        while True:
            descriptor = offset + index * 20
            original_first = _u32(self.data, descriptor)
            name_rva = _u32(self.data, descriptor + 12)
            first_thunk = _u32(self.data, descriptor + 16)
            if original_first == 0 and name_rva == 0 and first_thunk == 0:
                break
            name_offset = self.rva_to_offset(name_rva)
            if name_offset is None:
                break
            dll = self._cstring(name_offset).lower()
            thunks = self.rva_to_offset(original_first or first_thunk)
            if thunks is None:
                break
            symbols: list[str] = []
            slot = 0
            while True:
                cursor = thunks + slot * pointer_size
                value = (struct.unpack_from("<Q", self.data, cursor)[0]
                         if self.is_64bit else _u32(self.data, cursor))
                if value == 0:
                    break
                if value & high_bit:
                    symbols.append(f"ordinal#{value & 0xFFFF}")
                else:
                    symbol_offset = self.rva_to_offset(value)
                    symbols.append(self._cstring(symbol_offset + 2) if symbol_offset else "<unnamed>")
                slot += 1
            result.setdefault(dll, []).extend(symbols)
            index += 1
        return result


def parse_def_ordinals(def_path: Path) -> dict[int, str]:
    """Read `name @ordinal` pairs from a .def file."""
    result: dict[int, str] = {}
    for raw_line in def_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.split(";", 1)[0].strip()
        if not line or line.upper() == "EXPORTS":
            continue
        parts = line.split()
        if len(parts) != 2 or not parts[1].startswith("@"):
            raise PEError(f"{def_path}: cannot parse export line: {raw_line!r}")
        name, ordinal_text = parts
        try:
            ordinal = int(ordinal_text[1:])
        except ValueError as exc:
            raise PEError(f"{def_path}: bad ordinal in {raw_line!r}") from exc
        if ordinal in result:
            raise PEError(f"{def_path}: ordinal {ordinal} assigned twice")
        result[ordinal] = name
    return result


def verify(dll_path: Path, def_path: Path | None) -> list[str]:
    problems: list[str] = []
    image = PEImage(dll_path)

    if image.machine != IMAGE_FILE_MACHINE_AMD64:
        problems.append(
            f"{dll_path.name} targets machine 0x{image.machine:04x}, expected x64 (0x8664)"
        )

    actual = image.exports()
    if not actual:
        problems.append(f"{dll_path.name} exports no named symbols")

    # 1. The cuDNN ABI contract.
    for ordinal, expected_name in sorted(CUDNN_REQUIRED_ORDINALS.items()):
        found = actual.get(ordinal)
        if found is None:
            problems.append(f"ordinal {ordinal} is not exported; cuDNN requires {expected_name}")
        elif found != expected_name:
            problems.append(
                f"ordinal {ordinal} is {found!r}, but cuDNN requires {expected_name!r} "
                "-- this DLL would load and then corrupt memory"
            )

    # 2. Consistency with the .def the build applied.
    if def_path is not None:
        declared = parse_def_ordinals(def_path)
        for ordinal, name in sorted(declared.items()):
            found = actual.get(ordinal)
            if found is None:
                problems.append(f"{def_path.name} declares ordinal {ordinal} ({name}) but the DLL does not export it")
            elif found != name:
                problems.append(
                    f"ordinal {ordinal}: {def_path.name} declares {name!r}, the DLL exports {found!r}"
                )

    # Cross-check the declared ordinals against the contract too, so a bad .def
    # is caught even when no DLL has been built yet.
    if def_path is not None:
        for ordinal, expected_name in sorted(CUDNN_REQUIRED_ORDINALS.items()):
            declared_name = parse_def_ordinals(def_path).get(ordinal)
            if declared_name != expected_name:
                problems.append(
                    f"{def_path.name} assigns ordinal {ordinal} to {declared_name!r}, "
                    f"but cuDNN requires {expected_name!r}"
                )

    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dll", type=Path, help="path to the built zlibwapi.dll")
    parser.add_argument(
        "--def",
        dest="def_path",
        type=Path,
        default=None,
        help="path to zlibwapi.def; defaults to packaging/windows/zlibwapi.def next to the repo root",
    )
    args = parser.parse_args(argv)

    def_path = args.def_path
    if def_path is None:
        candidate = Path(__file__).resolve().parents[1] / "packaging" / "windows" / "zlibwapi.def"
        def_path = candidate if candidate.is_file() else None

    try:
        problems = verify(args.dll, def_path)
    except (PEError, OSError) as exc:
        print(f"[ERR] {exc}", file=sys.stderr)
        return 1

    if problems:
        print(f"[ERR] zlibwapi.dll ABI check failed for {args.dll}:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    checked = ", ".join(f"{o}={n}" for o, n in sorted(CUDNN_REQUIRED_ORDINALS.items()))
    print(f"[OK] {args.dll.name} honours the cuDNN zlibwapi ABI ({checked})")
    if def_path is not None:
        print(f"[OK] matches {def_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
