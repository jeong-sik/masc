#!/bin/bash
# Regenerate the vendored keeper-v2 webfonts and their @font-face sheets.
#
#   scripts/fetch-v2-fonts.sh
#
# Downloads latin/latin-ext woff2 subsets of EB Garamond and JetBrains Mono
# plus the 124 unicode-range slices of the variable Noto Sans KR from the
# Google Fonts css2 API, writes them to public/assets/fonts/, and regenerates
# src/styles/fonts.css and src/styles/fonts-noto-sans-kr.css. Nothing in the
# app requests fonts.googleapis.com at runtime; this script is the only place
# the network is involved.
#
# The Cinzel TTF (public/assets/fonts/Cinzel-Regular.ttf) predates this script
# and is left in place untouched.
#
# The same run also fills prototypes/keeper-v2/styles/fonts/ with the static
# TTFs the prototype's own colors_and_type.css @font-face rules point at
# (Cinzel + Noto Sans KR). Without them the prototype side of the parity
# harness renders those faces from system fallbacks while the vendored side
# loads real files, and the SSIM delta measures font availability, not skin
# drift. That directory is gitignored; run this script after cloning.
#
# The UA matters: css2 serves different files per client, and the parity
# harness browses with Playwright's headless Chromium, so the woff2 bytes the
# dashboard serves must be the bytes that same browser would fetch itself —
# "same font, same bytes" (e2e/design-parity-css.mjs). If the Playwright
# version changes its UA, update it here and re-run.
set -euo pipefail

cd "$(dirname "$0")/.."
DEST=public/assets/fonts
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/149.0.7827.55 Safari/537.36"

mkdir -p "$DEST"
curl -s "https://fonts.googleapis.com/css2?family=EB+Garamond:ital,wght@0,400;0,600;1,400&family=JetBrains+Mono:wght@400;500;700&display=swap" -H "User-Agent: $UA" -o /tmp/v2fonts-ebjb.css
curl -s "https://fonts.googleapis.com/css2?family=Noto+Sans+KR:wght@400;500;700&display=swap" -H "User-Agent: $UA" -o /tmp/v2fonts-noto.css

python3 - << 'PYEOF'
import re, os, urllib.request

DEST = 'public/assets/fonts'

def parse(css):
    out = []
    for body in re.findall(r'@font-face \{([^}]+)\}', css):
        g = lambda k: (re.search(k + r':\s*([^;]+);', body) or [None, None])[1]
        out.append(dict(fam=g('font-family'), style=g('font-style'),
                        weight=g('font-weight'),
                        url=re.search(r'url\((\S+?)\)', body).group(1),
                        rng=g('unicode-range')))
    return out

eb_jb = [b for b in parse(open('/tmp/v2fonts-ebjb.css').read())
         if 'U+0000' in b['rng'] or 'U+0100' in b['rng']]
noto_all = parse(open('/tmp/v2fonts-noto.css').read())
seen, noto = set(), []
for b in noto_all:
    if b['url'] not in seen:
        seen.add(b['url']); noto.append(b)

def fname(b):
    fam = 'EBGaramond' if 'Garamond' in b['fam'] else ('JetBrainsMono' if 'JetBrains' in b['fam'] else 'NotoSansKR')
    w = b['weight'].replace(' ', '')
    s = 'i' if b['style'] == 'italic' else ''
    m = re.search(r'\.(\d+)\.woff2$', b['url'])
    sub = f"-{m.group(1)}" if m else ('-latin' if 'U+0000' in b['rng'] else '-latinext')
    return f"{fam}-{w}{s}{sub}.woff2"

for b in eb_jb + noto:
    b['file'] = fname(b)
    path = os.path.join(DEST, b['file'])
    if not os.path.exists(path):
        urllib.request.urlretrieve(b['url'], path)

eb_jb.sort(key=lambda b: (b['fam'], b['weight'], b['style']))
blocks = [f"""@font-face {{
  font-family: {b['fam']};
  font-style: {b['style']};
  font-weight: {b['weight']};
  font-display: swap;
  src: url('/dashboard/assets/fonts/{b['file']}') format('woff2');
  unicode-range: {b['rng']};
}}""" for b in eb_jb]

open('src/styles/fonts.css', 'w').write(f"""/* Keeper-v2 brand fonts
 *
 * All three faces the keeper-v2 skin names in --font-display / --font-body /
 * --font-mono load locally from /dashboard/assets/fonts/:
 *   Cinzel (display, TTF) and EB Garamond + JetBrains Mono (latin &
 *   latin-ext woff2 subsets, ~30KB each). Korean text is covered by
 *   fonts-noto-sans-kr.css. No stylesheet in this app fetches Google Fonts:
 *   the subsets are vendored so a clean machine renders the design's metrics
 *   (see docs/DESIGN-PARITY.md, "the body face is the same one").
 */

@font-face {{
  font-family: 'Cinzel';
  font-style: normal;
  font-weight: 400;
  font-display: swap;
  src: url('/dashboard/assets/fonts/Cinzel-Regular.ttf') format('truetype');
}}

""" + "\n\n".join(blocks) + "\n")

noto.sort(key=lambda b: (int(m.group(1)) if (m := re.search(r'-(\d+)\.woff2$', b['file'])) else -1))
nb = [f"""@font-face {{
  font-family: 'Noto Sans KR';
  font-style: normal;
  font-weight: 400 700;
  font-display: swap;
  src: url('/dashboard/assets/fonts/{b['file']}') format('woff2');
  unicode-range: {b['rng']};
}}""" for b in noto]

open('src/styles/fonts-noto-sans-kr.css', 'w').write(f"""/* Noto Sans KR — split woff2 subsets, generated from the Google Fonts
 * css2 response (v39). The browser downloads only the slices a screen's
 * characters fall into (typically 3-6 files, ~150KB) instead of the 9.9MB
 * full TTF, so the first paint stays on system fallback for a moment
 * (font-display: swap) and never blocks on the full family.
 * Regenerate with scripts/fetch-v2-fonts.sh; do not hand-edit.
 */

""" + "\n\n".join(nb) + "\n")

n = len(eb_jb) + len(noto)
total = sum(os.path.getsize(os.path.join(DEST, f)) for f in os.listdir(DEST) if f.endswith('.woff2'))
print(f"wrote {len(eb_jb)} latin faces + {len(noto)} Noto KR slices ({n} files, {total/1024/1024:.2f}MB total)")
PYEOF

# ── Prototype-side TTFs ──────────────────────────────────────────────────────
# css2 answers with static TTF urls when the client sends no modern UA.
mkdir -p prototypes/keeper-v2/styles/fonts
fetch_ttf() {  # family-arg, out-file
  local url
  url=$(curl -s "https://fonts.googleapis.com/css2?family=$1&display=swap" \
        | sed -n 's/.*src: url(\([^)]*\)) format.*/\1/p')
  [ -n "$url" ] || { echo "no ttf url for $1" >&2; exit 1; }
  [ -f "prototypes/keeper-v2/styles/fonts/$2" ] || curl -s -o "prototypes/keeper-v2/styles/fonts/$2" "$url"
  echo "proto font: $2"
}
fetch_ttf "Cinzel:wght@400" "Cinzel-Regular.ttf"
fetch_ttf "Noto+Sans+KR:wght@400" "NotoSansKR-Regular.ttf"
