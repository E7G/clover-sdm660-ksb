#!/usr/bin/env python3
"""Clover KS-SB Hybrid - Android boot image (header v2) unpack / repack / verify.

Repack strategy: FIXED-OFFSET KERNEL SPLICE + ZERO PADDING.

The boot image contains more than the header describes (a second dtb, a vbmeta
blob, an AVB footer near the end of the partition). Shifting that unknown
region around is a risk we do not need to take, so this tool refuses to move
anything: the new kernel must fit inside the old kernel's page-aligned region,
the remainder is zero-padded, and every byte from the ramdisk offset onwards is
copied verbatim at the same absolute offset. Only the 'kernel_size' header
field changes. The 'id' field is deliberately left untouched (it is not a
standard AOSP SHA1 in this image and nothing reads it).

Layout observed on Mi Pad 4 (clover), boot partition mmcblk0p12, 64 MiB:

    0x0000000  ANDROID! boot header v2 (header_size 1660, page_size 4096)
    0x0001000  kernel   gzip                       18537940 B (region 18538496 B)
    0x0011AF000 ramdisk lz4 legacy                  3821660 B (region 3825664 B)
    0x001555000 dtb[0]  FDT                        319604 B
    0x0015A4000 other high-entropy data -> dtb[1] @ 0x15BE000
    0x00296B000 AVB vbmeta
    end        AVB footer ('AVBf')
"""

import argparse
import hashlib
import json
import os
import struct
import sys

MAGIC = b"ANDROID!"
HDRV2_MIN = 1660

# (name, struct format, offset)
FIELDS = [
    ("kernel_size", "<I", 8),
    ("kernel_addr", "<I", 12),
    ("ramdisk_size", "<I", 16),
    ("ramdisk_addr", "<I", 20),
    ("second_size", "<I", 24),
    ("second_addr", "<I", 28),
    ("tags_addr", "<I", 32),
    ("page_size", "<I", 36),
    ("header_version", "<I", 40),
    ("os_version", "<I", 44),
    ("recovery_dtbo_size", "<I", 1632),
    ("recovery_dtbo_offset", "<Q", 1636),
    ("header_size", "<I", 1644),
    ("dtb_size", "<I", 1648),
    ("dtb_addr", "<Q", 1652),
]


def pages(n, page):
    return (n + page - 1) // page


def parse_header(data):
    if data[:8] != MAGIC:
        raise SystemExit("error: not an Android boot image (bad magic %r)" % data[:8])
    h = {}
    for name, fmt, off in FIELDS:
        h[name] = struct.unpack_from(fmt, data, off)[0]
    h["name"] = data[48:64].split(b"\x00")[0].decode("ascii", "replace")
    h["cmdline"] = data[64:64 + 512].split(b"\x00")[0].decode("ascii", "replace")
    h["extra_cmdline"] = data[608:608 + 1024].split(b"\x00")[0].decode("ascii", "replace")
    h["id"] = data[576:608].hex()
    if h["header_version"] != 2:
        raise SystemExit("error: header_version=%d unsupported (expected 2)"
                         % h["header_version"])
    if h["second_size"]:
        raise SystemExit("error: second_size=%d unsupported" % h["second_size"])
    return h


def layout(h):
    """Return absolute offsets of kernel / ramdisk / dtb and the kernel region size."""
    pg = h["page_size"]
    kern_off = pg
    kern_region = pages(h["kernel_size"], pg) * pg
    ram_off = kern_off + kern_region
    ram_region = pages(h["ramdisk_size"], pg) * pg
    dtb_off = ram_off + ram_region
    return {
        "page_size": pg,
        "kernel_offset": kern_off,
        "kernel_region": kern_region,
        "kernel_end": kern_off + h["kernel_size"],
        "ramdisk_offset": ram_off,
        "ramdisk_region": ram_region,
        "ramdisk_end": ram_off + h["ramdisk_size"],
        "dtb_offset": dtb_off,
        "dtb_end": dtb_off + h["dtb_size"],
    }


def summarize(data):
    h = parse_header(data)
    lay = layout(h)
    out = dict(h)
    out.update(lay)
    out["image_size"] = len(data)
    out["image_md5"] = hashlib.md5(data).hexdigest()
    return out


def cmd_info(args):
    data = open(args.image, "rb").read()
    info = summarize(data)
    for k in ("image_size", "image_md5", "header_size", "page_size", "kernel_size",
              "kernel_offset", "kernel_region", "ramdisk_size", "ramdisk_offset",
              "dtb_size", "dtb_offset", "cmdline"):
        print("%-16s %s" % (k, info[k]))
    return 0


def cmd_unpack(args):
    data = open(args.image, "rb").read()
    info = summarize(data)
    os.makedirs(args.dir, exist_ok=True)
    open(os.path.join(args.dir, "kernel.gz"), "wb").write(
        data[info["kernel_offset"]:info["kernel_end"]])
    open(os.path.join(args.dir, "ramdisk.img"), "wb").write(
        data[info["ramdisk_offset"]:info["ramdisk_end"]])
    open(os.path.join(args.dir, "dtb.img"), "wb").write(
        data[info["dtb_offset"]:info["dtb_end"]])
    open(os.path.join(args.dir, "header.bin"), "wb").write(data[:info["page_size"]])
    open(os.path.join(args.dir, "meta.json"), "w").write(json.dumps(info, indent=1))
    print("unpacked %s -> %s" % (args.image, args.dir))
    print("  kernel   %d B at 0x%x" % (info["kernel_size"], info["kernel_offset"]))
    print("  ramdisk  %d B at 0x%x" % (info["ramdisk_size"], info["ramdisk_offset"]))
    print("  dtb      %d B at 0x%x" % (info["dtb_size"], info["dtb_offset"]))
    return 0


def splice_kernel(orig, new_kernel):
    """Return a new image identical to orig except the kernel region."""
    h = parse_header(orig)
    lay = layout(h)
    region = lay["kernel_region"]
    if len(new_kernel) > region:
        raise SystemExit(
            "error: new kernel is %d B but the kernel region is only %d B "
            "(overflow %d B). Fixed-offset splice is impossible; do NOT shift the "
            "rest of the image blindly - re-evaluate the compression or the layout."
            % (len(new_kernel), region, len(new_kernel) - region))
    out = bytearray(orig)
    start = lay["kernel_offset"]
    out[start:start + len(new_kernel)] = new_kernel
    out[start + len(new_kernel):start + region] = b"\x00" * (region - len(new_kernel))
    if bytes(out[start + region:]) != bytes(orig[start + region:]):
        raise SystemExit("internal error: bytes after the kernel region changed")
    # The kernel_size field at offset 8 is the only thing allowed to differ
    # ahead of the kernel, so compare the rest of that region byte for byte.
    if bytes(out[:8]) != bytes(orig[:8]) or bytes(out[12:start]) != bytes(orig[12:start]):
        raise SystemExit("internal error: bytes before the kernel changed "
                         "(other than the kernel_size field)")
    struct.pack_into("<I", out, 8, len(new_kernel))
    return bytes(out), h, lay


def cmd_repack(args):
    orig = open(args.orig, "rb").read()
    new_kernel = open(args.kernel, "rb").read()
    out, h, lay = splice_kernel(orig, new_kernel)
    open(args.out, "wb").write(out)
    print("repacked  %s + %s -> %s" % (args.orig, args.kernel, args.out))
    print("  kernel %d B -> %d B (region %d B, %d B spare)"
          % (h["kernel_size"], len(new_kernel), lay["kernel_region"],
             lay["kernel_region"] - len(new_kernel)))
    print("  md5    %s" % hashlib.md5(out).hexdigest())
    return 0


def cmd_verify(args):
    """Repack with the ORIGINAL kernel; the result must be byte identical."""
    orig = open(args.image, "rb").read()
    h = parse_header(orig)
    lay = layout(h)
    kernel = orig[lay["kernel_offset"]:lay["kernel_end"]]
    out, _, _ = splice_kernel(orig, kernel)
    ok = out == orig
    print("verify: repack with the original kernel -> %s"
          % ("BYTE-IDENTICAL" if ok else "MISMATCH"))
    if not ok:
        for i, (a, b) in enumerate(zip(out, orig)):
            if a != b:
                print("  first difference at 0x%x: %02x != %02x" % (i, a, b))
                break
        print("  sizes %d vs %d" % (len(out), len(orig)))
        return 1
    print("  md5 %s" % hashlib.md5(out).hexdigest())
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("info", help="print header and region layout")
    p.add_argument("image")
    p.set_defaults(func=cmd_info)

    p = sub.add_parser("unpack", help="extract kernel/ramdisk/dtb/header")
    p.add_argument("image")
    p.add_argument("dir")
    p.set_defaults(func=cmd_unpack)

    p = sub.add_parser("repack", help="splice a new kernel into a copy of the original")
    p.add_argument("orig")
    p.add_argument("kernel")
    p.add_argument("out")
    p.set_defaults(func=cmd_repack)

    p = sub.add_parser("verify", help="round-trip proof: repack with the original kernel")
    p.add_argument("image")
    p.set_defaults(func=cmd_verify)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
