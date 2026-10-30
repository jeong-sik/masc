#!/usr/bin/env bash
# task-2244 첫 실전 계수 — v0.52.0 드라이 노트 시나리오 영수증 스크립트.
# 용도: scripts/release/count-guideless-added.py 의 시나리오를 파일로 남긴다.
#  - 시나리오 A(AC1): 마커 없는 구형 노트 → guideless_total=0
#  - 시나리오 B(AC2): 한국어 마커 2건 포함 노트 → added_total=3, guideless_total=2
#  - 시나리오 C(task-2321): 영어 마커 "No guide yet (" 포함 노트 → guideless_total=2
# 실행: bash scripts/release/run-guideless-check.sh <out-dir>
set -euo pipefail

out="${1:-/tmp/guideless-check}"
mkdir -p "$out"

cat > "$out/note-old.md" <<'EOF'
## v0.51.0

### Added

- First feature (#42001).
- Second feature (#42002).

### Fixed

- A fix (#42003).
EOF

cat > "$out/note-new.md" <<'EOF'
## v0.52.0

### Added

- The fenced late-approval journal gets a defined exit (#42266). Usage:
  - What it does: ...
  - Turn it on: nothing to enable.
- BiDi host cgroup default (#42250). 가이드 없음(대상 문서: docs/design/browser-bidi-live-host.md)
- Stability fix for 4.0.7 hosts (#42186). 가이드 없음(문서 없음)

### Fixed

- unrelated (#42999)
EOF

echo "== scenario A (old note, no markers) =="
python3 "$(dirname "$0")/count-guideless-added.py" \
  --tag v0.51.0 --note-path "$out/note-old.md" \
  --expect-added 2 --expect-guideless 0 \
  --out-json "$out/old.json" --out-md "$out/old.md" | tee "$out/old.stdout.json"

echo "== scenario B (new note, 2 markers) =="
python3 "$(dirname "$0")/count-guideless-added.py" \
  --tag v0.52.0 --note-path "$out/note-new.md" \
  --expect-added 3 --expect-guideless 2 \
  --out-json "$out/new.json" --out-md "$out/new.md" | tee "$out/new.stdout.json"

cat > "$out/note-english.md" <<'EOF'
## v0.54.0

### Added

- A feature with docs (#42901).
- An English-spelled guideless entry (#42902). No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md)
- Another English guideless (#42903). No guide yet (…)

### Fixed

- unrelated (#42999)
EOF

echo "== scenario C (English marker, 2 guideless) =="
python3 "$(dirname "$0")/count-guideless-added.py" \
  --tag v0.54.0 --note-path "$out/note-english.md" \
  --expect-added 3 --expect-guideless 2 \
  --out-json "$out/english.json" --out-md "$out/english.md" | tee "$out/english.stdout.json"

echo "== scenario R (real v0.54.0 CHANGELOG extract, AC1) =="
# task-2321 거절 대응: 실제 발행 노트(v0.54.0 태그의 CHANGELOG.md)에서 Added
# 섹션을 발췌해 --from-github 없이 독립 실행한다. 기대값 17/9는 발췌본에서
# 직접 확인한 것이 아니라 스크립트가 대조한다.
python3 - "$out" <<'PY'
import pathlib, re, subprocess, sys
out = pathlib.Path(sys.argv[1])
# v0.54.0 태그의 CHANGELOG.md에서 ### Added 섹션만 발췌
text = subprocess.run(
    ["git", "show", "v0.54.0:CHANGELOG.md"],
    check=True, capture_output=True, text=True,
).stdout
m = re.search(r"^### Added\n(.*?)(?=^### )", text, re.S | re.M)
assert m, "v0.54.0 Added section not found in tag CHANGELOG.md"
(out / "v0.54.0-real-added.md").write_text(
    "## v0.54.0\n\n### Added\n" + m.group(1), encoding="utf-8")
PY
python3 "$(dirname "$0")/count-guideless-added.py" \
  --tag v0.54.0 --note-path "$out/v0.54.0-real-added.md" \
  --expect-added 17 --expect-guideless 9 \
  --out-json "$out/real-v0.54.0.json" --out-md "$out/real-v0.54.0.md" \
  | tee "$out/real-v0.54.0.stdout.json"

echo "== summary =="
python3 - "$out" <<'PY'
import json, sys, pathlib
out = pathlib.Path(sys.argv[1])
old = json.loads((out / "old.json").read_text(encoding="utf-8"))
new = json.loads((out / "new.json").read_text(encoding="utf-8"))
english = json.loads((out / "english.json").read_text(encoding="utf-8"))
real = json.loads((out / "real-v0.54.0.json").read_text(encoding="utf-8"))
print(f"scenario A: {old['added_total']} added, {old['guideless_total']} guideless")
print(f"scenario B: {new['added_total']} added, {new['guideless_total']} guideless")
print(f"scenario C: {english['added_total']} added, {english['guideless_total']} guideless")
print(f"scenario R: {real['added_total']} added, {real['guideless_total']} guideless (real v0.54.0 CHANGELOG)")
print("PASS: --expect-* assertions all held")
PY
