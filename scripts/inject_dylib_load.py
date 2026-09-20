#!/usr/bin/env python3
"""Add one LC_LOAD_DYLIB to a Mach-O in place.

Usage: inject_dylib_load.py <macho> <install_name>

The new load command is appended after the existing load commands using header
slack (the unused bytes between the end of the load-command table and the
lowest file-backed section — several KB for Filza). The command must fit, or
the script refuses; it never relocates segments.

Works on thin 64-bit arm64 Mach-Os and 64-bit fat files. Filza's release base
is a thin arm64 binary, so that path is the one CI exercises.
"""

import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
FAT_CIGAM = 0xBEBAFECA
FAT_CIGAM_64 = 0xBFBAFECA

LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC


def align8(value: int) -> int:
    return (value + 7) & ~7


def load_command_region(data: bytes, base: int):
    ncmds, sizeofcmds = struct.unpack_from("<II", data, base + 16)
    return ncmds, sizeofcmds


def first_filebacked_section(data: bytes, base: int):
    ncmds, _ = load_command_region(data, base)
    off = base + 32
    lowest = None
    for _ in range(ncmds):
        command, size = struct.unpack_from("<II", data, off)
        if command == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            if nsects > 4096:
                raise SystemExit("implausible nsects; not a Mach-O?")
            s0 = off + 72
            for j in range(nsects):
                sect_off = struct.unpack_from("<I", data, s0 + j * 80 + 48)[0]
                if sect_off and (lowest is None or sect_off < lowest):
                    lowest = sect_off
        off += size
    return lowest


def build_dylib_command(install_name: str, cmd_size: int) -> bytes:
    name = install_name.encode("utf-8") + b"\x00"
    name_len = len(name)
    payload = align8(name_len)  # name field is zero padded to alignment
    cmdsize = 24 + payload
    if cmdsize > cmd_size:
        raise SystemExit("internal cmd size mismatch")
    cmd = struct.pack(
        "<IIIIII",
        LC_LOAD_DYLIB,
        cmdsize,
        24,  # name file offset within this command
        2,   # timestamp
        0x00020000,  # current_version 2.0.0
        0x00020000,  # compat_version  2.0.0
    )
    return cmd + name + b"\x00" * (payload - name_len)


def patch_thin(data: bytearray, base: int, install_name: str, cmd_size: int) -> bool:
    ncmds, sizeofcmds = load_command_region(data, base)
    lowest = first_filebacked_section(data, base)
    cmds_end = base + 32 + sizeofcmds

    target = bytes(data[cmds_end : cmds_end + min(cmd_size, 64)])
    if install_name.encode("utf-8") in data[base + 32 : base + 32 + sizeofcmds]:
        print(f"already present: {install_name}")
        return False
    if lowest is not None and cmds_end + cmd_size > lowest:
        raise SystemExit(
            f"no header slack to insert LC_LOAD_DYLIB "
            f"(cmds end 0x{cmds_end - base:x}, first section 0x{lowest:x}); "
            f"refusing to relocate segments"
        )

    cmd = build_dylib_command(install_name, cmd_size)
    if len(cmd) != cmd_size:
        raise SystemExit("built command size mismatch")
    data[cmds_end : cmds_end + cmd_size] = cmd
    struct.pack_into("<II", data, base + 16, ncmds + 1, sizeofcmds + cmd_size)
    print(
        f"patched LC_LOAD_DYLIB {install_name} "
        f"({cmd_size} bytes at 0x{cmds_end - base:x}, {ncmds}+1 commands)"
    )
    return True


def process(data: bytearray, install_name: str, cmd_size: int) -> bool:
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic in (MH_MAGIC_64, MH_CIGAM_64):
        return patch_thin(data, 0, install_name, cmd_size)

    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        big = magic in (FAT_MAGIC, FAT_MAGIC_64) == (FAT_MAGIC,)
        if magic in (FAT_CIGAM, FAT_CIGAM_64):
            # not big-endian in our little-endian read
            big = True
        nfat = struct.unpack_from(">I" if big else "<I", data, 4)[0]
        sliced = False
        for i in range(nfat):
            ent = 8 + i * 20
            cpu, sub, offset, size, align = struct.unpack_from(">5I", data, ent)
            code, cmdsize, _, _ = struct.unpack_from("<IIII", data, offset)
            if code != MH_MAGIC_64:
                continue
            if patch_thin(data, offset, install_name, cmd_size):
                sliced = True
        if sliced:
            return True
        raise SystemExit("no usable arm64 slice in fat Mach-O")

    raise SystemExit(f"unsupported Mach-O magic 0x{magic:x} (only 64-bit / fat)")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: inject_dylib_load.py <macho> <install_name>", file=sys.stderr)
        return 64
    path, install_name = sys.argv[1], sys.argv[2]
    name = install_name.encode("utf-8")
    cmd_size = 24 + align8(len(name) + 1)
    with open(path, "rb") as fh:
        data = bytearray(fh.read())
    changed = process(data, install_name, cmd_size)
    if not changed:
        return 1
    with open(path, "wb") as fh:
        fh.write(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())