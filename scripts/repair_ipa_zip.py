#!/usr/bin/env python3
"""Repair an IPA that carries trailing decoy data after the real end-of-central
directory (anti-unzip trick used by some TrollStore IPA mirrors).

Usage: repair_ipa_zip.py <in.ipa> <out.ipa>

Copies the archive up to the last *consistent* EOCD (whose declared central
directory offset + size lands exactly at the EOCD record itself), dropping any
appended decoy records.
"""

import struct
import sys

EOCD = b"PK\x05\x06"


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: repair_ipa_zip.py <in.ipa> <out.ipa>", file=sys.stderr)
        return 64
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, "rb") as fh:
        data = fh.read()

    cursor = 0
    valid_end = None
    while True:
        here = data.find(EOCD, cursor)
        if here < 0 or here + 22 > len(data):
            break
        _, disk, cd_disk, this_disk, total, cd_size, cd_off, comment_len = (
            struct.unpack_from("<4sHHHHIIH", data, here)
        )
        # A genuine EOCD's central directory starts with a PK\x01\x02 entry and
        # runs exactly up to this record. A decoy EOCD reproduces only the
        # numeric values, so it fails the magic probe.
        if (
            data[cd_off : cd_off + 4] == b"PK\x01\x02"
            and cd_off + cd_size == here
            and here + 22 + comment_len <= len(data)
        ):
            valid_end = here + 22 + comment_len
        cursor = here + 1

    if valid_end is None:
        raise SystemExit(f"{src}: no consistent EOCD found; not a usable zip?")
    if valid_end == len(data):
        print(f"{src}: clean archive, copying as-is")
    else:
        print(f"{src}: dropped {len(data) - valid_end} trailing decoy bytes")

    with open(dst, "wb") as fh:
        fh.write(data[:valid_end])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())