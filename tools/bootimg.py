#!/usr/bin/env python3
"""Clover KS-SB Hybrid - Android boot image (header v2) unpack / repack / verify.

Repack strategy: FIXED-OFFSET KERNEL SPLICE + ZERO PADDING.

The boot image contains more than the header describes (an appended DTB inside the
kernel region, a second dtb, a vbmeta blob, an AVB footer near the end of the
partition). Shifting that unknown region around is a risk we do not need to take,
so this tool refuses to move anything: the new kernel plus whatever trailing bytes
the stock image kept after the kernel's gzip stream (on clover: the appended
clover DTB, d00dfeed) must fit inside the old kernel's page-aligned region, the
remainder is zero-padded, and every byte from the ramdisk offset onwards is copied
verbatim at the same absolute offset. Only the 'kernel_size' header field changes.
The 'id' field is deliberately left untouched (it is not a standard AOSP SHA1 in
this image and nothing reads it).

The appended DTB matters: kernel_size on the stock Mi Pad 4 image is
18,537,940 B, of which the gzip stream is only 18,218,336 B; the remaining
319,604 B is the clover DTB (byte-identical to the header dtb at 0x1555000).
A repack that drops it produces an image the bootloader will not boot.

Layout observed on Mi Pad 4 (clover), boot partition mmcblk0p12, 64 MiB:

    0x0000000  ANDROID! boot header v2 (header_size 1660, page_size 4096)
    0x0001000  kernel   gzip 18218336 B + appended DTB 319604 B  (kernel_size 18537940 B, region 18538496 B)
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
import zlib

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


def gzip_stream_len(data):
    """Length of the first complete gzip member in data (RFC1952, single member)."""
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    d.decompress(data)
    d.flush()
    if not d.eof:
        raise SystemExit("error: no complete gzip stream at the start of the kernel "
                         "region (truncated or not gzip)")
    return len(data) - len(d.unused_data)


def kernel_parts(data):
    """Split the stock kernel region into (gzip stream, trailing bytes kept verbatim)."""
    h = parse_header(data)
    lay = layout(h)
    start = lay["kernel_offset"]
    ks = h["kernel_size"]
    blob = data[start:start + ks]
    if len(blob) != ks:
        raise SystemExit("error: kernel_size %d runs past the end of the image" % ks)
    gzlen = gzip_stream_len(blob)
    return blob[:gzlen], blob[gzlen:], h, lay


def summarize(data):
    h = parse_header(data)
    lay = layout(h)
    out = dict(h)
    out.update(lay)
    out["image_size"] = len(data)
    out["image_md5"] = hashlib.md5(data).hexdigest()
    try:
        gz, trailer, _, _ = kernel_parts(data)
        out["kernel_gzip_size"] = len(gz)
        out["kernel_appended_size"] = len(trailer)
        out["kernel_appended_magic"] = trailer[:4].hex()
    except SystemExit:
        out["kernel_gzip_size"] = None
        out["kernel_appended_size"] = None
    return out


def cmd_info(args):
    data = open(args.image, "rb").read()
    info = summarize(data)
    for k in ("image_size", "image_md5", "header_size", "page_size", "kernel_size",
              "kernel_offset", "kernel_region", "kernel_gzip_size",
              "kernel_appended_size", "kernel_appended_magic", "ramdisk_size",
              "ramdisk_offset", "dtb_size", "dtb_offset", "cmdline"):
        print("%-24s %s" % (k, info[k]))
    return 0


def cmd_unpack(args):
    data = open(args.image, "rb").read()
    info = summarize(data)
    h = parse_header(data)
    lay = layout(h)
    os.makedirs(args.dir, exist_ok=True)
    gz, trailer, _, _ = kernel_parts(data)
    open(os.path.join(args.dir, "kernel.gz"), "wb").write(gz)
    open(os.path.join(args.dir, "kernel-appended.bin"), "wb").write(trailer)
    open(os.path.join(args.dir, "ramdisk.img"), "wb").write(
        data[info["ramdisk_offset"]:info["ramdisk_end"]])
    open(os.path.join(args.dir, "dtb.img"), "wb").write(
        data[info["dtb_offset"]:info["dtb_end"]])
    open(os.path.join(args.dir, "header.bin"), "wb").write(data[:info["page_size"]])
    open(os.path.join(args.dir, "meta.json"), "w").write(json.dumps(info, indent=1))
    print("unpacked %s -> %s" % (args.image, args.dir))
    print("  kernel   %d B gzip + %d B appended at 0x%x"
          % (len(gz), len(trailer), info["kernel_offset"]))
    print("  ramdisk  %d B at 0x%x" % (info["ramdisk_size"], info["ramdisk_offset"]))
    print("  dtb      %d B at 0x%x" % (info["dtb_size"], info["dtb_offset"]))
    return 0


def splice_kernel(orig, new_kernel):
    """Return a new image identical to orig except the kernel region.

    The header's kernel_size is PRESERVED, not recomputed: the bootloader derives
    the ramdisk offset from it (ramdisk = page_align(kernel_size) + page_size), so
    shrinking it would make the bootloader look for the ramdisk in the middle of
    the zero padding. The new content is written first and the rest of the region
    is zero-filled, exactly like the stock image's own tail padding.
    """
    _, trailer, h, lay = kernel_parts(orig)
    region = lay["kernel_region"]
    target = h["kernel_size"]
    blob = new_kernel + trailer
    if len(blob) > target:
        raise SystemExit(
            "error: new kernel %d B + appended %d B = %d B but the stock kernel_size "
            "is %d B (overflow %d B). Fixed-offset splice is impossible; do NOT "
            "shift the rest of the image blindly - shrink the kernel or re-evaluate "
            "the compression."
            % (len(new_kernel), len(trailer), len(blob), target, len(blob) - target))
    if len(new_kernel) < 4 or new_kernel[:2] != b"\x1f\x8b":
        print("warning: new kernel does not start with the gzip magic 1f8b",
              file=sys.stderr)
    out = bytearray(orig)
    start = lay["kernel_offset"]
    out[start:start + len(blob)] = blob
    out[start + len(blob):start + region] = b"\x00" * (region - len(blob))
    if bytes(out[start + region:]) != bytes(orig[start + region:]):
        raise SystemExit("internal error: bytes after the kernel region changed")
    # The kernel_size field at offset 8 is the only thing allowed to differ
    # ahead of the kernel, so compare the rest of that region byte for byte.
    if bytes(out[:8]) != bytes(orig[:8]) or bytes(out[12:start]) != bytes(orig[12:start]):
        raise SystemExit("internal error: bytes before the kernel changed "
                         "(other than the kernel_size field)")
    struct.pack_into("<I", out, 8, target)
    return bytes(out), h, lay, len(trailer)


def splice_dtb(image, new_dtb):
    """Replace both Clover DTB copies in place without moving any region."""
    gz, trailer, h, lay = kernel_parts(image)
    size = h["dtb_size"]
    if len(new_dtb) != size:
        raise SystemExit("error: new DTB is %d B but boot header DTB is %d B; "
                         "fixed-offset replacement requires an exact size match"
                         % (len(new_dtb), size))
    if new_dtb[:4] != b"\xd0\x0d\xfe\xed":
        raise SystemExit("error: new DTB does not start with FDT magic d00dfeed")
    if len(trailer) < size:
        raise SystemExit("error: kernel appended area (%d B) is smaller than DTB (%d B)"
                         % (len(trailer), size))

    appended_off = lay["kernel_offset"] + len(gz)
    header_dtb_off = lay["dtb_offset"]
    old_appended = image[appended_off:appended_off + size]
    old_header = image[header_dtb_off:header_dtb_off + size]
    if old_appended != old_header:
        raise SystemExit("error: appended Clover DTB and header DTB differ; refusing "
                         "blind dual replacement")
    if old_header[:4] != b"\xd0\x0d\xfe\xed":
        raise SystemExit("error: existing DTB does not start with FDT magic")

    out = bytearray(image)
    out[appended_off:appended_off + size] = new_dtb
    out[header_dtb_off:header_dtb_off + size] = new_dtb
    return bytes(out), appended_off, header_dtb_off


def cmd_repack(args):
    orig = open(args.orig, "rb").read()
    new_kernel = open(args.kernel, "rb").read()
    out, h, lay, tlen = splice_kernel(orig, new_kernel)
    dtb_offsets = None
    if args.dtb:
        new_dtb = open(args.dtb, "rb").read()
        out, app_off, hdr_off = splice_dtb(out, new_dtb)
        dtb_offsets = (app_off, hdr_off, len(new_dtb))
    open(args.out, "wb").write(out)
    total = len(new_kernel) + tlen
    print("repacked  %s + %s -> %s" % (args.orig, args.kernel, args.out))
    print("  kernel %d B gzip + %d B appended = %d B (stock kernel_size %d B kept)"
          % (len(new_kernel), tlen, total, h["kernel_size"]))
    print("  region %d B, zero padding %d B, spare vs region %d B"
          % (lay["kernel_region"], h["kernel_size"] - total,
             lay["kernel_region"] - total))
    if dtb_offsets:
        print("  dtb    %d B replaced at appended 0x%x + header 0x%x"
              % (dtb_offsets[2], dtb_offsets[0], dtb_offsets[1]))
    print("  md5    %s" % hashlib.md5(out).hexdigest())
    return 0


def cmd_verify(args):
    """Repack with the ORIGINAL kernel; the result must be byte identical."""
    orig = open(args.image, "rb").read()
    _, _, h, lay = kernel_parts(orig)
    kernel = orig[lay["kernel_offset"]:lay["kernel_offset"] + h["kernel_size"] - 0]
    gz, trailer, _, _ = kernel_parts(orig)
    out, _, _, _ = splice_kernel(orig, gz)
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
    p.add_argument("--dtb", help="exact-size Clover DTB to replace in both fixed locations")
    p.set_defaults(func=cmd_repack)

    p = sub.add_parser("verify", help="round-trip proof: repack with the original kernel")
    p.add_argument("image")
    p.set_defaults(func=cmd_verify)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
