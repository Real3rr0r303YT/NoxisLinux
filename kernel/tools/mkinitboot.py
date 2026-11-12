#!/usr/bin/env python3
"""Replace the ramdisk inside an Android boot image (header v3/v4).

Usage: mkinitboot.py <orig.img> <new-ramdisk> <out.img>

Keeps every header field of the original (os_version, cmdline, ...)
and only swaps the ramdisk payload. Header v3/v4 have a fixed 4096
byte page size and no second stage / dtb in the image body.
"""
import struct
import sys

PAGE = 4096
MAGIC = b"ANDROID!"


def pad(n, page=PAGE):
    return (n + page - 1) // page * page


def main(orig_path, rd_path, out_path):
    with open(orig_path, "rb") as f:
        orig = f.read()
    with open(rd_path, "rb") as f:
        rd = f.read()

    if orig[:8] != MAGIC:
        sys.exit("error: %s is not an Android boot image" % orig_path)

    kernel_size, ramdisk_size, os_version, header_size = struct.unpack_from("<4I", orig, 8)
    (header_version,) = struct.unpack_from("<I", orig, 40)

    if header_version not in (3, 4):
        sys.exit("error: header version %d not supported (need 3 or 4)" % header_version)

    hdr = bytearray(orig[:header_size])
    struct.pack_into("<I", hdr, 12, len(rd))          # ramdisk_size
    if header_version == 4:
        struct.pack_into("<I", hdr, header_size - 4, 0)  # signature_size = 0

    kernel = orig[PAGE:PAGE + kernel_size]

    out = bytearray()
    out += hdr
    out += b"\0" * (pad(len(hdr)) - len(hdr))
    out += kernel
    out += b"\0" * (pad(len(kernel)) - len(kernel))
    out += rd
    out += b"\0" * (pad(len(rd)) - len(rd))

    with open(out_path, "wb") as f:
        f.write(out)

    print("header v%d  kernel %d B  ramdisk %d B -> %d B  total %d B"
          % (header_version, kernel_size, ramdisk_size, len(rd), len(out)))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3])
