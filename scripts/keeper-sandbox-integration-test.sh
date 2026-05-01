#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_tag="${MASC_KEEPER_SANDBOX_DOCKER_IMAGE:-masc-keeper-sandbox:local}"

# Build image if missing
if ! docker image inspect "$image_tag" >/dev/null 2>&1; then
  "$repo_root/scripts/build-keeper-sandbox-image.sh" "$image_tag"
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

playground="$tmpdir/playground"
mkdir -p "$playground"

# Extract required dune version from dune-project: (lang dune X.Y)
req_dune_ver="$(grep -E '^\(lang dune\b' "$repo_root/dune-project" \
                | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"

# Seed playground with realistic repo content
printf 'alpha\nbeta\ngamma\n' > "$playground/demo.txt"
mkdir -p "$playground/lib/keeper"
printf 'let x = 42\n' > "$playground/lib/keeper/foo.ml"
printf 'let y = \"hello\"\n' > "$playground/lib/keeper/bar.ml"
printf '{"name": "test", "version": "1.0.0"}\n' > "$playground/package.json"
printf 'all:\n\techo "make works"\n' > "$playground/Makefile"

# Initialize a git repo for git ops testing
git -C "$playground" init -q
git -C "$playground" config user.email "keeper@test"
git -C "$playground" config user.name "Keeper"
git -C "$playground" add .
git -C "$playground" commit -q -m "initial" >/dev/null 2>&1

pass=0
fail=0

run_test() {
  local name="$1"
  local network="${2:-none}"
  local cmd="$3"
  local expect_ok="${4:-true}"

  local extra_args=()
  if [[ "$network" == "bridge" ]]; then
    extra_args+=("--network" "bridge")
  else
    extra_args+=("--network" "none")
  fi

  local output
  local status=0
  output=$(
    docker run --rm -i \
      --user "$(id -u):$(id -g)" \
      --read-only \
      --tmpfs /tmp:rw,nosuid,nodev,noexec,size=64m \
      --cap-drop=ALL \
      --security-opt no-new-privileges \
      --pids-limit 64 \
      --memory 512m \
      -e "MASC_REQ_DUNE_VER=$req_dune_ver" \
      -v "$playground:/workspace:rw" \
      --workdir /workspace \
      "${extra_args[@]}" \
      "$image_tag" \
      bash -lc "$cmd 2>&1"
  ) || status=$?

  if [[ "$expect_ok" == "true" && "$status" -eq 0 ]]; then
    printf '  [PASS] %s\n' "$name"
    pass=$((pass + 1))
  elif [[ "$expect_ok" == "false" && "$status" -ne 0 ]]; then
    printf '  [PASS] %s (expected failure)\n' "$name"
    pass=$((pass + 1))
  else
    printf '  [FAIL] %s (status=%d)\n' "$name" "$status"
    printf '    output: %s\n' "$(head -c 200 <<< "$output" | tr '\n' ' ')"
    fail=$((fail + 1))
  fi
}

printf '=== Keeper Sandbox Integration Tests (%s) ===\n' "$image_tag"

# T1: pwd
run_test "T1: pwd" none \
  'test "$(pwd)" = "/workspace"' true

# T2: basic echo
run_test "T2: basic shell" none \
  'test "$(echo hello)" = "hello"' true

# T3: playground file write/read/append
run_test "T3: playground write/read" none \
  'printf "delta\n" > write.txt && test "$(cat write.txt)" = "delta"' true

# T4: cat file
run_test "T4: cat" none \
  'test "$(cat demo.txt)" = $'"'"'alpha\nbeta\ngamma'"'"'' true

# T5: ls -la directory
run_test "T5: ls directory" none \
  'ls -la /workspace >/dev/null' true

# T6: rg search with type filter
run_test "T6: rg with type filter" none \
  'rg -n -m 10 --type ml "let" /workspace >/dev/null' true

# T7: find files
run_test "T7: find" none \
  'find /workspace -maxdepth 5 -name "*.ml" -not -path "*/.git/*" >/dev/null' true

# T8: head/tail/wc
run_test "T8: head" none \
  'test "$(head -n 1 demo.txt)" = "alpha"' true
run_test "T8: tail" none \
  'test "$(tail -n 1 demo.txt)" = "gamma"' true
run_test "T8: wc" none \
  'test "$(wc -l < demo.txt)" = "3"' true

# T9: tree simulation (find-based)
run_test "T9: tree (find)" none \
  'find /workspace -maxdepth 3 -print -not -path "*/.git/*" >/dev/null' true

# T10: git status/log/diff
run_test "T10: git status" none \
  'git --no-optional-locks status --short --branch >/dev/null 2>&1' true
run_test "T10: git log" none \
  'git --no-optional-locks log --format="%h %s" -1 >/dev/null 2>&1' true
run_test "T10: git diff" none \
  'git --no-optional-locks diff --stat >/dev/null 2>&1' true

# T11: git worktree list
run_test "T11: git worktree" none \
  'git worktree list >/dev/null' true

# T12: jq parse
run_test "T12: jq" none \
  'test "$(jq -r .name package.json)" = "test"' true

# T13: python3 run script
run_test "T13: python3" none \
  'python3 -c "print(2+2)" >/dev/null' true

# T14: node/npm check
run_test "T14: node" none \
  'node -e "console.log(1+1)" >/dev/null' true
run_test "T14: npm" none \
  'npm --version >/dev/null' true

# T15: make target
run_test "T15: make" none \
  'make all >/dev/null 2>&1' true

# T16: opam/dune check
run_test "T16: opam" none \
  'opam --version >/dev/null' true
run_test "T16: dune" none \
  'dune --version >/dev/null' true
run_test "T16: dune version >= dune-project" none \
  'actual=$(dune --version); printf "%s\n%s\n" "$MASC_REQ_DUNE_VER" "$actual" | sort -V -C' true

# T17: gh check (gh binary exists)
run_test "T17: gh binary" none \
  'gh --version >/dev/null' true

# T18: read-only root write attempt (should fail)
run_test "T18: read-only root blocked" none \
  'printf "x" > /etc/test_ro.txt 2>/dev/null; test ! -f /etc/test_ro.txt' true

# T19: tmpfs write
run_test "T19: tmpfs write" none \
  'printf "tmpdata" > /tmp/tmpfs.txt && test "$(cat /tmp/tmpfs.txt)" = "tmpdata"' true

# T20: git clone with network bridge (shallow clone of public repo)
run_test "T20: git clone (network)" bridge \
  'git clone --depth 1 https://github.com/octocat/Hello-World.git /workspace/cloned 2>/dev/null && test -f /workspace/cloned/README' true

# T21: playground append
run_test "T21: playground append" none \
  'printf "appended\n" >> demo.txt && test "$(tail -n 1 demo.txt)" = "appended"' true

printf '\n=== Results ===\n'
printf 'Passed: %d\n' "$pass"
printf 'Failed: %d\n' "$fail"

if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
