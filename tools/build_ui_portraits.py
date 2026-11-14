"""Pack the editable UI_Bust PNG ZIP into Godot UI atlases. Requires Pillow.

Usage: python tools/build_ui_portraits.py /path/to/UI_Bust_600_PNG_Frames.zip
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import zipfile

from PIL import Image

SOURCES = (
    "01-man-idle", "02-man-angry", "03-man-stunned", "04-man-proud", "05-man-sad",
    "06-woman-idle", "07-woman-angry", "08-woman-stunned", "09-woman-proud", "10-woman-sad",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    output = Path(__file__).resolve().parents[1] / "assets/ui/portraits"
    output.mkdir(parents=True, exist_ok=True)
    manifest = {
        "source_archive": args.archive.name,
        "source_sha256": hashlib.sha256(args.archive.read_bytes()).hexdigest(),
        "frame_count": 60, "fps": 20, "tile_size": 256, "columns": 8,
        "source_frame_size": [512, 512], "animations": [],
    }
    with zipfile.ZipFile(args.archive) as archive:
        if archive.testzip() is not None:
            raise ValueError("The source archive failed its CRC check")
        for source in SOURCES:
            character = "man" if "-man-" in source else "woman"
            state = source.rsplit("-", 1)[1].replace("stunned", "fallen")
            atlas = Image.new("RGBA", (2048, 2048))
            hashes = []
            for frame in range(60):
                entry = f"png_frames/{source}/frame_{frame + 1:04d}.png"
                raw = archive.read(entry)
                hashes.append(hashlib.sha256(raw).hexdigest())
                with Image.open(io.BytesIO(raw)) as image:
                    if image.size != (512, 512) or image.mode != "RGBA":
                        raise ValueError(f"Unexpected source format: {entry}")
                    # Keep the original fixed framing, colours and soft alpha.
                    tile = image.resize((256, 256), Image.Resampling.LANCZOS)
                    atlas.paste(tile, ((frame % 8) * 256, (frame // 8) * 256))
            filename = f"{character}_{state}.png"
            atlas.save(output / filename, optimize=True)
            manifest["animations"].append({
                "character": character, "state": state, "source": source,
                "atlas": filename, "source_frame_sha256": hashes,
                "atlas_sha256": hashlib.sha256((output / filename).read_bytes()).hexdigest(),
            })
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Packed {len(SOURCES)} animations, 600 frames, 20 fps into {output}")


if __name__ == "__main__":
    main()
