#!/usr/bin/env python3
"""Convert MacHelper's square PNG artwork to a complete native macOS app icon."""
import argparse
import os
import struct
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ICON_SIZES = (
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
)


def build_icon(source, output):
    source = source.resolve()
    output = output.resolve()
    if not source.is_file():
        raise ValueError(f"MacHelper app icon artwork is missing: {source}. Add AppIcon.png before building the app.")
    with source.open("rb") as stream:
        header = stream.read(33)
    if len(header) != 33 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError(f"MacHelper app icon artwork must be a PNG image: {source}")
    width, height = struct.unpack(">II", header[16:24])
    if width < 1 or width != height:
        raise ValueError(f"MacHelper app icon artwork must be square; received {width}×{height} pixels.")
    if source == output:
        raise ValueError("The PNG artwork and generated ICNS must use different paths.")
    with tempfile.TemporaryDirectory(prefix="MacHelperIcon-") as temporary:
        temporary = Path(temporary)
        iconset = temporary / "AppIcon.iconset"
        iconset.mkdir()
        for filename, size in ICON_SIZES:
            # sips retains the PNG alpha channel. Every density starts from the
            # original artwork, avoiding repeated resampling or flattening.
            subprocess.run([
                "/usr/bin/sips", "--setProperty", "format", "png",
                "--resampleHeightWidth", str(size), str(size), str(source),
                "--out", str(iconset / filename),
            ], check=True, capture_output=True, text=True)
        generated = temporary / "AppIcon.icns"
        subprocess.run([
            "/usr/bin/iconutil", "--convert", "icns", "--output", str(generated), str(iconset),
        ], check=True, capture_output=True, text=True)
        output.parent.mkdir(parents=True, exist_ok=True)
        # Publish only a complete conversion, including across filesystem mounts.
        with tempfile.NamedTemporaryFile(prefix=".AppIcon-", suffix=".icns", dir=output.parent, delete=False) as staged:
            stage = Path(staged.name)
            try:
                staged.write(generated.read_bytes())
                staged.flush()
                os.fchmod(staged.fileno(), 0o644)
                os.replace(stage, output)
            finally:
                stage.unlink(missing_ok=True)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "MacHelper/Assets/AppIcon.png")
    parser.add_argument("--output", type=Path, default=ROOT / "MacHelper/Assets/AppIcon.icns")
    args = parser.parse_args()
    try:
        output = build_icon(args.source, args.output)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        details = getattr(error, "stderr", None)
        parser.exit(1, f"App icon build failed: {error}" + (f"\n{details.strip()}" if details else "") + "\n")
    print(f"Built {output}")


if __name__ == "__main__":
    main()
