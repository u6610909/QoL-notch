#!/usr/bin/env python3
"""Writes every QoL Notch logo file into Branding/ from one set of numbers.

Run from the repo root:  python3 scripts/make_logo.py
Then:                    ./scripts/render_logo.sh   (PNG exports and the app icon)
"""
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "Branding"

CORAL_DARK = "#FF6A55"
CORAL_LIGHT = "#E8492F"
INK_DARK = "#FFFFFF"
INK_LIGHT = "#0B0C1A"

# ---------------------------------------------------------------- mark

TILE = dict(x=100, y=100, w=824, h=824, r=185)
ISLAND = ("M172,180 C199.28,180 216,196.72 216,224 L216,510 Q216,620 326,620 "
          "L698,620 Q808,620 808,510 L808,224 C808,196.72 824.72,180 852,180 Z")
ISLAND_SMALL = ("M188,196 C215.28,196 232,212.72 232,240 L232,480 Q232,600 352,600 "
                "L672,600 Q792,600 792,480 L792,240 C792,212.72 808.72,196 836,196 Z")
ISLAND_TINY = "M232,196 L232,480 Q232,600 352,600 L672,600 Q792,600 792,480 L792,196 Z"


def tile_rect(**attrs):
    extra = " ".join(f'{k.replace("_", "-")}="{v}"' for k, v in attrs.items())
    t = TILE
    return f'<rect x="{t["x"]}" y="{t["y"]}" width="{t["w"]}" height="{t["h"]}" rx="{t["r"]}" {extra}/>'


def mark_body(p, shadow=False):
    """The full mark's layers. `p` prefixes ids so several marks can share one file."""
    defs = f"""
    <linearGradient id="{p}bg" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#343A8C"/><stop offset="0.55" stop-color="#1A1C4A"/><stop offset="1" stop-color="#0A0B1E"/>
    </linearGradient>
    <radialGradient id="{p}aura">
      <stop offset="0" stop-color="#A9B4FF" stop-opacity="0.95"/>
      <stop offset="0.35" stop-color="#5B6CFF" stop-opacity="0.9"/>
      <stop offset="0.7" stop-color="#4338CA" stop-opacity="0.55"/>
      <stop offset="1" stop-color="#4338CA" stop-opacity="0"/>
    </radialGradient>
    <clipPath id="{p}tile">{tile_rect()}</clipPath>
    <clipPath id="{p}island"><path d="{ISLAND}"/></clipPath>
    <filter id="{p}auraBlur" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="18"/></filter>
    <filter id="{p}coralBlur" x="-30%" y="-100%" width="160%" height="300%"><feGaussianBlur stdDeviation="10"/></filter>
    <filter id="{p}shadow" x="-10%" y="-10%" width="120%" height="125%"><feGaussianBlur stdDeviation="12"/></filter>"""
    dim = 'fill="#FFFFFF" fill-opacity="0.32"'
    body = ""
    if shadow:
        body += f'<g transform="translate(0,12)" filter="url(#{p}shadow)">{tile_rect(fill="#000000", fill_opacity="0.3")}</g>'
    body += f"""
  <g clip-path="url(#{p}tile)">
    {tile_rect(fill=f"url(#{p}bg)")}
    <path d="M100,100 H924 V180 H100 Z {ISLAND}" fill="#000000"/>
    <g clip-path="url(#{p}island)">
      <ellipse cx="512" cy="628" rx="250" ry="170" fill="url(#{p}aura)" filter="url(#{p}auraBlur)"/>
    </g>
    <rect x="288" y="272" width="136" height="44" rx="22" {dim}/>
    <rect x="444" y="272" width="188" height="44" rx="22" {dim}/>
    <rect x="652" y="272" width="84" height="44" rx="22" {dim}/>
    <rect x="288" y="352" width="100" height="44" rx="22" fill="#FFFFFF"/>
    <rect x="408" y="352" width="172" height="44" rx="22" fill="{CORAL_DARK}" fill-opacity="0.55" filter="url(#{p}coralBlur)"/>
    <rect x="408" y="352" width="172" height="44" rx="22" fill="{CORAL_DARK}"/>
    <rect x="600" y="352" width="136" height="44" rx="22" {dim}/>
  </g>
  <rect x="102" y="102" width="820" height="820" rx="183" fill="none" stroke="#FFFFFF" stroke-opacity="0.1" stroke-width="4"/>"""
    return defs, body


def simple_body(island):
    return f"""
  {tile_rect(fill="#262B6B")}
  <g clip-path="url(#t)"><rect x="100" y="100" width="824" height="96" fill="#000000"/><path d="{island}" fill="#000000"/></g>
  <rect x="312" y="354" width="400" height="88" rx="44" fill="{CORAL_DARK}"/>"""


def svg(width, height, defs, body, extra=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
            f'viewBox="0 0 {width} {height}"{extra}>\n  <defs>{defs}\n  </defs>{body}\n</svg>\n')


def mono_mark(colour):
    defs = f"""
    <mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
      {tile_rect(fill="#FFFFFF")}
      <rect x="100" y="100" width="824" height="96" fill="#000000"/>
      <path d="{ISLAND_SMALL}" fill="#000000"/>
    </mask>"""
    body = f"""
  {tile_rect(fill=colour, mask="url(#m)")}
  <rect x="312" y="354" width="400" height="88" rx="44" fill="{colour}"/>"""
    return svg(1024, 1024, defs, body)


# ---------------------------------------------------------------- wordmark

# Centrelines on a 10-unit grid: stroke 20, cap height 140, x-height 100. Total 962 x 140.
LETTERS = [
    (0, ['<circle cx="70" cy="70" r="60"/>']),                                        # Q ring (tail added apart)
    (156, ['<circle cx="50" cy="90" r="40"/>']),                                      # o
    (272, ['<polyline points="10,10 10,130 80,130"/>']),                              # L
    (418, ['<polyline points="10,130 10,10 110,130 110,10"/>']),                      # N
    (554, ['<circle cx="50" cy="90" r="40"/>']),                                      # o
    (670, ['<path d="M30,20 L30,105 A25,25 0 0 0 55,130 L60,130"/>',                  # t
           '<line x1="10" y1="50" x2="60" y2="50"/>']),
    (756, ['<path d="M78.28,61.72 A40,40 0 1 0 78.28,118.28"/>']),                    # c
    (862, ['<line x1="10" y1="10" x2="10" y2="130"/>',                                # h
           '<path d="M10,90 A40,40 0 0 1 90,90 L90,130"/>']),
]


def wordmark_group(ink, accent):
    parts = []
    for x, shapes in LETTERS:
        inner = "".join(shapes)
        parts.append(f'<g transform="translate({x},0)">{inner}</g>')
    return (f'<g fill="none" stroke="{ink}" stroke-width="20" stroke-linecap="round" stroke-linejoin="round">'
            + "".join(parts)
            + f'<line x1="92" y1="92" x2="126" y2="126" stroke="{accent}"/></g>')


def wordmark(ink, accent, extra=""):
    return svg(962, 140, "", "\n  " + wordmark_group(ink, accent), extra)


# ---------------------------------------------------------------- lockups

SCALE = 240 / 824


def horizontal(ink, accent, prefix="h"):
    defs, body = mark_body(prefix)
    group = (f'\n  <g transform="scale({SCALE:.5f}) translate(-100,-100)">{body}\n  </g>'
             f'\n  <g transform="translate(296,50)">{wordmark_group(ink, accent)}</g>')
    return defs, group


def social_preview():
    defs, lockup = horizontal(INK_DARK, CORAL_DARK, "s")
    defs += """
    <radialGradient id="glow">
      <stop offset="0" stop-color="#5B6CFF" stop-opacity="0.55"/>
      <stop offset="0.5" stop-color="#4338CA" stop-opacity="0.3"/>
      <stop offset="1" stop-color="#4338CA" stop-opacity="0"/>
    </radialGradient>
    <filter id="glowBlur" x="-20%" y="-40%" width="140%" height="180%"><feGaussianBlur stdDeviation="40"/></filter>"""
    dots = "".join(
        f'<circle cx="{514 + 28 * i}" cy="516" r="6" fill="{CORAL_DARK if i == 0 else "#FFFFFF"}"'
        + ("" if i == 0 else ' fill-opacity="0.3"') + "/>"
        for i in range(10))
    body = f"""
  <rect width="1280" height="640" fill="#07080F"/>
  <ellipse cx="640" cy="700" rx="620" ry="300" fill="url(#glow)" filter="url(#glowBlur)"/>
  <g transform="translate(200,176) scale(0.7)">{lockup}
  </g>
  <text x="640" y="432" text-anchor="middle" font-family="Inter, 'Helvetica Neue', Arial, sans-serif"
        font-size="34" font-weight="500" letter-spacing="0.2" fill="#A9B0D6">A voice-following teleprompter and everyday tools, in your notch.</text>
  {dots}"""
    return svg(1280, 640, defs, body)


def main():
    OUT.mkdir(exist_ok=True)
    files = {}

    defs, body = mark_body("a")
    files["logo-mark.svg"] = svg(1024, 1024, defs, body)
    defs, body = mark_body("a", shadow=True)
    files["icon-full.svg"] = svg(1024, 1024, defs, body)

    clip = f'\n    <clipPath id="t">{tile_rect()}</clipPath>'
    files["logo-mark-small.svg"] = svg(1024, 1024, clip, simple_body(ISLAND_SMALL))
    files["logo-mark-tiny.svg"] = svg(1024, 1024, clip, simple_body(ISLAND_TINY))
    files["logo-mark-mono-black.svg"] = mono_mark("#000000")
    files["logo-mark-mono-white.svg"] = mono_mark("#FFFFFF")

    files["logo-wordmark-dark.svg"] = wordmark(INK_DARK, CORAL_DARK)
    files["logo-wordmark-light.svg"] = wordmark(INK_LIGHT, CORAL_LIGHT)
    files["logo-wordmark-mono.svg"] = wordmark("currentColor", "currentColor")

    for name, ink, accent in (("dark", INK_DARK, CORAL_DARK), ("light", INK_LIGHT, CORAL_LIGHT)):
        defs, group = horizontal(ink, accent)
        files[f"logo-horizontal-{name}.svg"] = svg(1258, 240, defs, group)

    files["social-preview.svg"] = social_preview()

    for name, text in files.items():
        (OUT / name).write_text(text)
    print(f"Wrote {len(files)} files to {OUT}")


if __name__ == "__main__":
    main()
