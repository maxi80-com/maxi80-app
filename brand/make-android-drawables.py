"""Generate the Android drawable copies of the generic "no cover" artwork (issue #80).

Run from the repo root; needs Pillow and optipng:

    python3 brand/make-android-drawables.py

Android needs its own copies because it cannot read the Apple asset catalog: the notification /
lock screen / Android Auto card resolves `android.resource://…/drawable/<name>` (see
`NowPlayingController.androidDrawableName`), and resource names allow only lowercase letters,
digits and underscores — so `NoCover-25ans-2` ships as `nocover_25ans_2`.

Re-run this whenever a cover is added to or replaced in `PlaceholderCover`, then commit the output.
Every name in `PlaceholderCover.all + .anniversary` must have a drawable, or a coverless song given
that cover falls back to the station logo on the card while the carousel shows the cover.

They must stay **raster PNGs**: media3's ImageDecoder cannot rasterize an adaptive-icon XML, which
is the #41 trap that made the car show a blank square.

Two things this does that a plain `sips -Z 1024` does not, and why it is a script rather than a
one-liner:

- **It preserves each source's color depth.** Three sources (`NoCover-25ans-{2,3,4}`) are 8-bit
  palette PNGs; anything that decodes them to truecolor makes the 1024 output *larger than the 1440
  source* (872KB -> 1.9MB), and the seven drawables cost 8.0MB of APK instead of 3.9MB. Re-quantizing
  a palette source back to 256 colors loses nothing the shipped iOS asset has.
- **It runs optipng.** Lossless, ~10%, free.
"""

import os
import pathlib
import subprocess
import sys

from PIL import Image

SIZE = 1024

REPO = pathlib.Path(__file__).resolve().parent.parent
ASSETS = REPO / "Sources/Maxi80/Resources/Assets.xcassets"
DRAWABLES = REPO / "Android/app/src/main/res/drawable-nodpi"


def main() -> int:
    sources = sorted(ASSETS.glob("NoCover-*.imageset/*.png"))
    if not sources:
        print(f"no NoCover-*.imageset sources under {ASSETS}", file=sys.stderr)
        return 1

    outputs = []
    for src in sources:
        # `NoCover-25ans-2.imageset/nocover-25ans-2.png` -> `nocover_25ans_2.png`
        dest = DRAWABLES / (src.stem.replace("-", "_") + ".png")

        image = Image.open(src)
        was_palette = image.mode == "P"
        has_alpha = "A" in image.getbands()

        mode = "RGBA" if has_alpha else "RGB"
        resized = image.convert(mode).resize((SIZE, SIZE), Image.LANCZOS)

        if was_palette:
            resized = resized.quantize(
                colors=256, method=Image.MEDIANCUT, dither=Image.FLOYDSTEINBERG
            )
        resized.save(dest, optimize=True)
        outputs.append(dest)

    subprocess.run(
        ["optipng", "-o2", "-quiet", *[str(p) for p in outputs]], check=True
    )

    total = 0
    for dest in outputs:
        size = os.path.getsize(dest)
        total += size
        with Image.open(dest) as out:
            print(f"{dest.name:<24} {size:>9,}  {out.mode}  {out.size[0]}x{out.size[1]}")
    print(f"{'total':<24} {total:>9,}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
