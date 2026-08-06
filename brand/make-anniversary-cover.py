"""Build the 1440x1440 anniversary placeholder cover from brand/25 ans.png (issue #71).

One-shot generator, kept because the output can't be re-derived from the PNG alone. Run from the
repo root; needs only Pillow:

    python3 brand/make-anniversary-cover.py \
        Sources/Maxi80/Resources/Assets.xcassets/NoCover-25ans.imageset/nocover-25ans.png

It also prints the 40x40-average dominant color, sampled the same way `ImageColorSampler` samples
real artwork — that value is what `PlaceholderCover.anniversary` carries as its `dominantColor`
(currently rgb(47, 31, 55)), so re-run this if the artwork is ever replaced.

The source is a flattened Photoshop export: what looks like a white background is the
transparency checkerboard (241/253 greys, ~24px cells), and the logo's wide neon glow
is flattened *over* it. The artwork therefore has to be un-flattened — keyed off the
checker and recomposited on a dark canvas — or every glow reads as a pale patchwork
halo instead of as light.

Three things make that work:

1.  Reconstruct the checker exactly. Each flattened pixel is `C = a*F + (1-a)*B`, so
    B has to be the right cell. The export wasn't scaled by an integer factor (the
    period measures 23.77 x 24.49 px and the cell-boundary residuals drift up to 3px
    across the width), so the grid is recovered from the *measured* boundaries — the
    subpixel crossings of the mid-level along a pure-background row and column —
    rather than from a nominal 24px pitch. Assuming one flat B instead leaves the two
    cells at different alphas, and unpremultiplying amplifies that difference back
    into a visible checker.

2.  Solve alpha off the darkest channel. Neon is saturated, so its min channel is ~0
    and `min(C) == (1-a)*B` reads alpha directly; F follows by unpremultiplying.

3.  Only key where the checker is really behind the artwork. Doing it everywhere also
    dissolves the genuinely white ink ("LE SON DES ANNEES 80", "WWW.MAXI80.COM") and
    the chrome "25" highlights. Those are enclosed by saturated neon, so a flood fill
    that can cross background and glow — but not saturated ink — reaches all of the
    former and stops at the latter.
"""

import bisect
import sys
from collections import deque

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SRC = "brand/25 ans.png"
OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/25ans/nocover-25ans.png"
SIZE = 1440
MARGIN = float(sys.argv[2]) if len(sys.argv) > 2 else 0.05

# The two checker greys, measured off the flattened background, and the level halfway
# between them (cell boundaries are that level's crossings).
CELL_DARK = 241.0
CELL_LIGHT = 253.5
CELL_MID = 247.0

# Flood-fill passability, i.e. "the checker is visible here". Glow over white stays
# bright and fairly desaturated, so DIM..BRIGHT admits it only while it is
# desaturated; at or above BRIGHT so little glow is left that the pixel has to be
# background. Saturated neon and the dark perspective grid fail both tests and wall
# off the white ink enclosed by them.
FLOOD_DIM = 110
FLOOD_SPREAD = 35
FLOOD_BRIGHT = 230

# Drop alpha below this. Reconstructing B per cell puts bare checker at ~0, so this
# only trims the faintest fringe of glow — invisible against a dark cover.
ALPHA_FLOOR = 0.02

# Backdrop: the deep blue-violet of the logo's own perspective grid, lifted behind the
# wordmark by a soft radial so the square doesn't read as a flat black slab.
BASE_COLOR = (14, 9, 26)
LIFT_COLOR = (48, 23, 76)

src = Image.open(SRC).convert("RGB")
W, H = src.size
px = src.load()

r, g, b = src.split()
# Darkest / brightest channel per pixel: `dark` is what the checker shows through most
# cleanly (neon is saturated), and their difference is the saturation test.
dark = ImageChops.darker(ImageChops.darker(r, g), b).load()
light = ImageChops.lighter(ImageChops.lighter(r, g), b).load()


# --- 1. Reconstruct the checkerboard -----------------------------------------
def crossings(values):
    """Subpixel positions where the profile crosses the mid-level — cell boundaries."""
    out = []
    for i in range(1, len(values)):
        lo, hi = values[i - 1] - CELL_MID, values[i] - CELL_MID
        if (lo > 0) != (hi > 0) and lo != hi:
            out.append(i - 1 + lo / (lo - hi))
    return out


# Row 3 and column 3 are pure background for their whole length, so their crossings
# are the true cell boundaries.
col_edges = crossings([dark[x, 3] for x in range(W)])
row_edges = crossings([dark[3, y] for y in range(H)])
col_band = [bisect.bisect_right(col_edges, x) for x in range(W)]
row_band = [bisect.bisect_right(row_edges, y) for y in range(H)]
print(f"checker: {len(col_edges)} column edges, {len(row_edges)} row edges")

# Which parity is the light cell — decided by whichever assignment better predicts the
# known background, so the choice is measured rather than assumed.
err = [0.0, 0.0]
samples = 0
for y in range(0, H, 7):
    for x in range(0, W, 7):
        v = dark[x, y]
        if v < 235:  # background only
            continue
        even = (col_band[x] + row_band[y]) % 2 == 0
        err[0] += abs(v - (CELL_LIGHT if even else CELL_DARK))
        err[1] += abs(v - (CELL_DARK if even else CELL_LIGHT))
        samples += 1
even_is_light = err[0] <= err[1]
print(
    f"parity: even cell is {'light' if even_is_light else 'dark'} "
    f"({min(err) / samples:.2f} vs {max(err) / samples:.2f} levels mean error)"
)


def backdrop(x, y):
    """The checker grey that was flattened behind this pixel."""
    even = (col_band[x] + row_band[y]) % 2 == 0
    return CELL_LIGHT if even == even_is_light else CELL_DARK


# --- 2. Flood the checker in from the border ----------------------------------
def passable(x, y):
    v = dark[x, y]
    if v >= FLOOD_BRIGHT:
        return True
    return v >= FLOOD_DIM and light[x, y] - v <= FLOOD_SPREAD


keyable = bytearray(W * H)
q = deque()


def seed(x, y):
    if not keyable[y * W + x] and passable(x, y):
        keyable[y * W + x] = 1
        q.append((x, y))


for x in range(W):
    seed(x, 0)
    seed(x, H - 1)
for y in range(H):
    seed(0, y)
    seed(W - 1, y)
while q:
    x, y = q.popleft()
    for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
        if 0 <= nx < W and 0 <= ny < H and not keyable[ny * W + nx]:
            if passable(nx, ny):
                keyable[ny * W + nx] = 1
                q.append((nx, ny))
print(f"keyable: {sum(keyable)} px ({100 * sum(keyable) / (W * H):.1f}%)")

# --- 3. Un-flatten ------------------------------------------------------------
keyed = Image.new("RGBA", (W, H))
kp = keyed.load()
for y in range(H):
    for x in range(W):
        c = px[x, y]
        if not keyable[y * W + x]:
            kp[x, y] = (c[0], c[1], c[2], 255)
            continue
        bg = backdrop(x, y)
        a = 1.0 - dark[x, y] / bg
        if a < ALPHA_FLOOR:
            kp[x, y] = (0, 0, 0, 0)
            continue
        a = min(a, 1.0)
        kp[x, y] = tuple(
            max(0, min(255, round((ch - (1.0 - a) * bg) / a))) for ch in c
        ) + (round(a * 255),)

# --- 4. Trim to the artwork and centre it on the square canvas ---------------
bbox = keyed.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
logo = keyed.crop(bbox)
print("logo bbox:", bbox, "->", logo.size)

# Fit inside a margin so the glow never touches the edge and the carousel's rounded
# corners / `.fill` crop can't clip the wordmark.
target_w = round(SIZE * (1 - 2 * MARGIN))
logo = logo.resize(
    (target_w, max(1, round(logo.height * target_w / logo.width))), Image.LANCZOS
)

canvas = Image.new("RGB", (SIZE, SIZE), BASE_COLOR)
mask = Image.new("L", (SIZE, SIZE), 0)
draw = ImageDraw.Draw(mask)
cx = cy = SIZE // 2
rx, ry = round(SIZE * 0.52), round(SIZE * 0.34)
steps = 48
for i in range(steps, 0, -1):
    t = i / steps
    draw.ellipse(
        [cx - rx * t, cy - ry * t, cx + rx * t, cy + ry * t],
        fill=round(255 * (1 - t) ** 1.6),
    )
mask = mask.filter(ImageFilter.GaussianBlur(SIZE * 0.06))
canvas = Image.composite(Image.new("RGB", (SIZE, SIZE), LIFT_COLOR), canvas, mask)

canvas.paste(logo, ((SIZE - logo.width) // 2, (SIZE - logo.height) // 2), logo)
canvas.save(OUT, optimize=True)
print("wrote", OUT, canvas.size)

# --- 5. Dominant color, sampled the way the app samples artwork (40x40 mean) --
small = canvas.resize((40, 40), Image.LANCZOS).load()
tot = [0, 0, 0]
for y in range(40):
    for x in range(40):
        for i in range(3):
            tot[i] += small[x, y][i]
print("dominant (r,g,b):", [round(t / 1600) for t in tot])
