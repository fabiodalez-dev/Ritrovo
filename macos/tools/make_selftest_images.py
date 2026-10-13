#!/usr/bin/env python3
"""Disk images for the end-to-end self test of Ritrovo (SelfTest.swift).

Usage: make_selftest_images.py <output folder>
Writes:
  selftest.img  raw image, no partition table. With the default formats and
                the "no thumbnails" filter the engine recovers exactly 10 files:
                7 photos (3 JPEG, one an identical copy, two with an EXIF date;
                PNG, GIF, BMP, WebP), 1 MP4, 1 MP3, 1 PDF. Two small JPEG
                thumbnails and a PNG icon are discarded by the filter.
  fat.img       raw image, MBR with one FAT16 partition holding
                DCIM/100RITRO/IMG_0001.JPG and CLIP.MP4, then quick-formatted:
                "unformat" finds the names again.
Requirements: Python 3 with Pillow, ffmpeg, lame, hdiutil and diskutil
(macOS). No administrator rights are needed.
"""
import io, os, random, subprocess, sys, tempfile
from PIL import Image

out = sys.argv[1] if len(sys.argv) > 1 else "."
os.makedirs(out, exist_ok=True)
rng = random.Random(20261014)


def run(*args, **kw):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kw).stdout


def noise_image(w, h, seed):
    """Photo-like content: smooth gradients plus noise, so JPEGs are large."""
    r = random.Random(seed)
    img = Image.new("RGB", (w, h))
    px = img.load()
    a, b, c = r.random() * 255, r.random() * 255, r.random() * 255
    for y in range(h):
        for x in range(w):
            n = r.randint(-8, 8)
            px[x, y] = (int(a + x * 200 / w + n) % 256, int(b + y * 200 / h + n) % 256, int(c + (x + y) * 90 / (w + h) + n) % 256)
    return img


def encode(img, fmt, **kw):
    buf = io.BytesIO()
    img.save(buf, fmt, **kw)
    return buf.getvalue()


def jpeg(w, h, seed, date=None):
    img = noise_image(w, h, seed)
    kw = {"quality": 92}
    if date:
        exif = Image.Exif()
        exif[0x8769] = {0x9003: date}          # Exif IFD, DateTimeOriginal
        exif[0x0132] = date                    # TIFF DateTime
        kw["exif"] = exif.tobytes()
    return encode(img, "JPEG", **kw)


def media(tmp):
    mp4 = os.path.join(tmp, "clip.mp4")
    run("ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=15",
        "-pix_fmt", "yuv420p", "-c:v", "libx264", "-movflags", "+faststart", mp4)
    wav = os.path.join(tmp, "tone.wav")
    run("ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=3", wav)
    mp3 = os.path.join(tmp, "tone.mp3")
    run("lame", "--quiet", "-b", "128", wav, mp3)
    return open(mp4, "rb").read(), open(mp3, "rb").read()


def pdf():
    objs = ["<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"]
    text = b"BT /F1 24 Tf 72 760 Td (Ritrovo self test) Tj ET"
    objs.append("<< /Length %d >>\nstream\n%s\nendstream" % (len(text), text.decode()))
    objs.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    body = b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"
    offsets = []
    for i, o in enumerate(objs, 1):
        offsets.append(len(body))
        body += ("%d 0 obj\n%s\nendobj\n" % (i, o)).encode()
    xref = len(body)
    body += ("xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)).encode()
    for off in offsets:
        body += ("%010d 00000 n \n" % off).encode()
    body += ("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)).encode()
    return body


def write_raw(path, blobs, gap=65536, tail=1 << 20):
    """Each file starts on a 4096 byte boundary, zeros in between."""
    with open(path, "wb") as f:
        f.write(b"\0" * gap)
        for data in blobs:
            f.write(data)
            pad = (-f.tell()) % 4096 + gap
            f.write(b"\0" * pad)
        f.write(b"\0" * tail)


with tempfile.TemporaryDirectory() as tmp:
    mp4, mp3 = media(tmp)
    photo_a = jpeg(800, 600, 1, "2021:07:14 18:30:05")
    blobs = [
        photo_a,
        jpeg(1024, 768, 2, "2022:03:05 10:00:00"),
        photo_a,                                                  # identical copy
        encode(noise_image(640, 480, 3), "PNG"),
        encode(noise_image(400, 400, 4).convert("P", palette=Image.ADAPTIVE), "GIF"),
        encode(noise_image(500, 400, 5), "BMP"),
        encode(noise_image(600, 400, 6), "WEBP", quality=90),
        jpeg(120, 90, 7),                                         # thumbnail, filtered
        jpeg(100, 100, 8),                                        # thumbnail, filtered
        encode(noise_image(32, 32, 9), "PNG"),                    # icon, filtered
        mp4, mp3, pdf(),
    ]
    raw = os.path.join(out, "selftest.img")
    write_raw(raw, blobs)
    print("selftest.img", os.path.getsize(raw), "bytes,", len(blobs), "files")

    # FAT image: partition, copy two files into a camera folder, then a quick
    # format. newfs_msdos is not used for it: on macOS it clears the whole
    # partition. A quick format only resets the FATs and the root directory,
    # which is done here from the boot sector values.
    fat = os.path.join(out, "fat.img")
    with open(fat, "wb") as f:
        f.truncate(40 * 1024 * 1024)
    dev = run("hdiutil", "attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", fat).split()[0]
    try:
        run("diskutil", "partitionDisk", dev, "MBR", "MS-DOS FAT16", "RTEST", "100%")
        info = run("diskutil", "info", dev + "s1")
        point = [l.split(":", 1)[1].strip() for l in info.splitlines() if "Mount Point" in l][0]
        folder = os.path.join(point, "DCIM", "100RITRO")
        os.makedirs(folder)
        with open(os.path.join(folder, "IMG_0001.JPG"), "wb") as f:
            f.write(jpeg(800, 600, 10, "2023:05:01 12:00:00"))
        with open(os.path.join(folder, "CLIP.MP4"), "wb") as f:
            f.write(mp4)
        run("sync")
        run("diskutil", "unmount", dev + "s1")
    finally:
        subprocess.run(["hdiutil", "detach", dev], capture_output=True)
    with open(fat, "r+b") as f:
        mbr = f.read(512)
        start = int.from_bytes(mbr[0x1C6:0x1CA], "little") * 512     # first partition, LBA
        f.seek(start)
        boot = f.read(512)
        bps = int.from_bytes(boot[11:13], "little")
        reserved = int.from_bytes(boot[14:16], "little")
        nfats = boot[16]
        root_entries = int.from_bytes(boot[17:19], "little")
        fat_sectors = int.from_bytes(boot[22:24], "little")
        media = boot[21]
        for i in range(nfats):
            f.seek(start + (reserved + i * fat_sectors) * bps)
            f.write(bytes([media, 0xFF, 0xFF, 0xFF]) + b"\0" * (fat_sectors * bps - 4))
        f.seek(start + (reserved + nfats * fat_sectors) * bps)
        f.write(b"\0" * (root_entries * 32))
    print("fat.img", os.path.getsize(fat), "bytes")
