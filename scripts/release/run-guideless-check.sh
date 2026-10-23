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
  --out-json "$out/old.json" --out-md "$out/old.md" | tee "$out/old.stdout.json"

echo "== scenario B (new note, 2 markers) =="
python3 "$(dirname "$0")/count-guideless-added.py" \
  --tag v0.52.0 --note-path "$out/note-new.md" \
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
  --out-json "$out/english.json" --out-md "$out/english.md" | tee "$out/english.stdout.json"

echo "== summary =="
python3 - "$out" <<'PY'
import json, sys, pathlib
out = pathlib.Path(sys.argv[1])
old = json.loads((out / "old.json").read_text(encoding="utf-8"))
new = json.loads((out / "new.json").read_text(encoding="utf-8"))
english = json.loads((out / "english.json").read_text(encoding="utf-8"))
assert old["guideless_total"] == 0, old
assert new["added_total"] == 3 and new["guideless_total"] == 2, new
assert english["added_total"] == 3 and english["guideless_total"] == 2, english
print("PASS: old 0 guideless (safe), new 3 added / 2 guideless, english 3 added / 2 guideless")
PY
