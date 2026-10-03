#!/usr/bin/env bash
# Scan tracked dune files: test_* executables must be declared as tests.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scan() {
  python3 - "$REPO_ROOT" "$@" <<'PY'
import pathlib
import re
import shlex
import subprocess
import sys
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / 'scripts' / 'ci'))
from dune_suite_scope import top_level_stanzas


def scan_forms(path, ancestors=()):
    resolved = path.resolve()
    if resolved in ancestors:
        raise SystemExit(f'Include cycle: {path}')
    for form in top_level_stanzas(path.read_text(encoding='utf-8')):
        include = re.fullmatch(r'\(include\s+([^\s)]+)\s*\)', form.strip())
        if include:
            included = path.parent / include.group(1)
            if not included.is_file():
                raise SystemExit(f'Missing dune include: {included}')
            yield from scan_forms(included, (*ancestors, resolved))
        else:
            yield path, form


paths = [pathlib.Path(p) for p in sys.argv[2:]]
if not paths:
    root = pathlib.Path(sys.argv[1])
    if not (root / 'test' / 'dune').is_file():
        raise SystemExit('Root test/dune is missing')
    tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z']).decode().split('\0')
    paths = [root / p for p in tracked if p and pathlib.Path(p).name == 'dune']
total = 0
bad = []
for path in paths:
    for source, form in scan_forms(path):
        head = re.match(r'\(\s*(executable|executables|test|tests)\b', form)
        if not head:
            continue
        fields = top_level_stanzas(form[1:-1])
        field = next((child for child in fields
                      if re.match(r'\(\s*names?\s', child)), None)
        if field is None:
            continue
        atoms = shlex.shlex(field[1:-1], posix=True)
        atoms.whitespace_split = True
        atoms.commenters = ';'
        names = list(atoms)[1:]
        for name in names:
            total += 1
            if head.group(1).startswith('executable') and name.startswith('test_'):
                bad.append(f'{source}: {name}')
print(total, len(paths))
print('\n'.join(bad), end='\n' if bad else '')
PY
}
self_test() {
  local tmp out
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/packages/core/test/stanzas"
  printf '(test (name test_alpha))\n(executable (name helper))\n' > "$tmp/dune"
  printf '(include stanzas/suites.inc)\n' > "$tmp/packages/core/test/dune"
  printf '(executables (names test_beta helper_beta))\n' > "$tmp/packages/core/test/stanzas/suites.inc"
  out="$(scan "$tmp/dune" "$tmp/packages/core/test/dune")"
  [[ "$(printf '%s\n' "$out" | head -1)" == '4 2' ]]
  [[ "$(printf '%s\n' "$out" | tail -n +2)" == "$tmp/packages/core/test/stanzas/suites.inc: test_beta" ]]
  echo '[PASS] nested package/include/plural executable is reported'
  printf '(tests (names test_beta test_gamma))\n' > "$tmp/packages/core/test/stanzas/suites.inc"
  out="$(scan "$tmp/dune" "$tmp/packages/core/test/dune")"
  [[ "$(printf '%s\n' "$out" | head -1)" == '4 2' ]]
  [[ -z "$(printf '%s\n' "$out" | tail -n +2)" ]]
  echo '[PASS] test stanzas and diagnostic executables are accepted'
  cat > "$tmp/comments" <<'DUNE'
(executable
 ; (name test_comment)
 (action (echo "(name test_string)"))
 (name "helper"))
(executable
 ; (name helper_comment)
 (name "test_quoted"))
DUNE
  out="$(scan "$tmp/comments")"
  [[ "$(printf '%s\n' "$out" | head -1)" == '2 1' ]]
  [[ "$(printf '%s\n' "$out" | tail -n +2)" == "$tmp/comments: test_quoted" ]]
  echo '[PASS] comments/strings do not replace direct declaration names'
  printf '(include suites.inc)\n' > "$tmp/packages/core/test/stanzas/nested.inc"
  printf '(include stanzas/nested.inc)\n' > "$tmp/packages/core/test/dune"
  out="$(scan "$tmp/dune" "$tmp/packages/core/test/dune")"
  [[ "$(printf '%s\n' "$out" | head -1)" == '4 2' ]]
  printf '(include absent.inc)\n' > "$tmp/packages/core/test/stanzas/nested.inc"
  if scan "$tmp/packages/core/test/dune" > "$tmp/error" 2>&1; then
    echo '[FAIL] missing include was accepted' >&2; return 1
  fi
  grep -q 'Missing dune include:' "$tmp/error"
  printf '(include nested.inc)\n' > "$tmp/packages/core/test/stanzas/nested.inc"
  if scan "$tmp/packages/core/test/dune" > "$tmp/error" 2>&1; then
    echo '[FAIL] include cycle was accepted' >&2; return 1
  fi
  grep -q 'Include cycle:' "$tmp/error"
  echo '[PASS] recursive includes are read; missing/cyclic includes fail'

  mkdir -p "$tmp/repo/scripts/lint" "$tmp/repo/scripts/ci" "$tmp/repo/test" "$tmp/repo/packages/core/test" "$tmp/repo/.worktrees/ignored"
  cp "$REPO_ROOT/scripts/lint/test-suites-are-declared-as-tests.sh" "$tmp/repo/scripts/lint/"
  cp "$REPO_ROOT/scripts/ci/dune_suite_scope.py" "$tmp/repo/scripts/ci/"
  printf '(test (name test_root))\n' > "$tmp/repo/test/dune"
  printf '(executable (name test_package))\n' > "$tmp/repo/packages/core/test/dune"
  printf '(executable (name test_untracked))\n' > "$tmp/repo/.worktrees/ignored/dune"
  git -C "$tmp/repo" init -q
  git -C "$tmp/repo" add test/dune packages/core/test/dune
  local status=0
  bash "$tmp/repo/scripts/lint/test-suites-are-declared-as-tests.sh" > "$tmp/report" 2>&1 || status=$?
  [[ "$status" == 1 ]]
  grep -q 'test_package' "$tmp/report"
  grep -q 'scanned 2 dune files' "$tmp/report"
  if grep -q 'test_untracked' "$tmp/report"; then
    echo '[FAIL] untracked worktree was scanned' >&2; return 1
  fi
  printf '(test (name test_package))\n' > "$tmp/repo/packages/core/test/dune"
  bash "$tmp/repo/scripts/lint/test-suites-are-declared-as-tests.sh" > "$tmp/report"
  grep -q 'in 2 dune files' "$tmp/report"
  echo '[PASS] actual repository scan fails for a package offender and passes after repair'
}
if [[ "${1:-}" == '--self-test' ]]; then
  self_test
  exit 0
fi
output="$(scan)"
read -r total files <<< "$(printf '%s\n' "$output" | head -1)"
offenders="$(printf '%s\n' "$output" | tail -n +2)"
# Structural coverage replaces a fixed stanza count: declarations must exist.
if (( files == 0 || total == 0 )); then
  echo '[suite-kind] No dune files or executable/test declarations were read.' >&2
  exit 2
fi
if [[ -n "$offenders" ]]; then
  echo "[suite-kind] scanned ${files} dune files, ${total} declarations; test_-named executables:" >&2
  printf '%s\n' "$offenders" >&2
  exit 1
fi
echo "test suite stanzas: 0 test_-named (executable) across ${total} declarations in ${files} dune files"
