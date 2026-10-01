#!/usr/bin/env bash
# Exercise the real pin script and lease wrapper with an isolated opam command.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/masc-pin-status.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repo/scripts" "$work/bin"
cp "$repo/scripts/opam-pin-external-deps.sh" "$repo/scripts/opam-switch-rw-lock.sh" "$work/repo/scripts/"
cp "$repo/dune-project" "$work/repo/"
chmod +x "$work/repo/scripts/"*.sh
version=$(sed -nE '/^[[:space:]]*\(ocaml[[:space:]]+\(=[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+)\)\).*$/ { s//\1/; p; q; }' "$repo/dune-project")
cat >"$work/bin/opam" <<'OPAM'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "switch show") echo fixture-switch ;;
  "var prefix") echo "$PIN_TEST_ROOT/switch" ;;
  "exec --") echo "$PIN_TEST_VERSION" ;;
  "pin list") : ;;
  "pin add")
    printf 'pin %s\n' "$3" >>"$PIN_TEST_CALLS"
    attempts=$(wc -l <"$PIN_TEST_CALLS")
    if (( PIN_TEST_FAILURES < 0 || attempts <= PIN_TEST_FAILURES )); then
      exit "$PIN_TEST_STATUS"
    fi
    ;;
  "install --yes") echo install >>"$PIN_TEST_CALLS" ;;
  *) echo "unexpected opam call: $*" >&2; exit 64 ;;
esac
OPAM
chmod +x "$work/bin/opam"

run_case() {
  local name=$1 failures=$2 failure_status=$3 expected=$4
  shift 4
  local out="$work/$name"
  mkdir "$out"
  : >"$out/calls"
  local actual=0
  env -u OPAM_SWITCH_PREFIX -u MASC_OPAM_READ_LEASE_HELD -u MASC_OPAM_WRITE_LEASE_HELD \
    PATH="$work/bin:$PATH" MASC_OPAM_LOCK_PATH="$out/lease" \
    PIN_TEST_ROOT="$work" PIN_TEST_VERSION="$version" PIN_TEST_CALLS="$out/calls" \
    PIN_TEST_FAILURES="$failures" PIN_TEST_STATUS="$failure_status" \
    OPAM_PIN_RETRIES=2 OPAM_PIN_RETRY_DELAY_SEC=0 \
    bash "$work/repo/scripts/opam-pin-external-deps.sh" "$@" \
    >"$out/stdout" 2>"$out/stderr" || actual=$?
  if [[ "$actual" != "$expected" ]]; then
    cat "$out/stderr" >&2
    echo "$name: expected exit $expected, got $actual" >&2
    exit 1
  fi
}

check_failure() {
  local name=$1
  [[ $(wc -l <"$work/$name/calls") -eq 2 ]]
  [[ $(sort -u "$work/$name/calls" | wc -l) -eq 1 ]]
  ! grep -q '^install$' "$work/$name/calls"
}

run_case exhausted -1 99 99
check_failure exhausted
run_case exhausted-install -1 99 99 --install
check_failure exhausted-install
run_case other-status -1 7 7
check_failure other-status
run_case success 0 99 0
pin_count=$(grep -c '^pin ' "$work/success/calls")
[[ "$pin_count" -gt 1 ]]
! grep -q '^install$' "$work/success/calls"
run_case success-install 0 99 0 --install
[[ $(grep -c '^pin ' "$work/success-install/calls") -eq "$pin_count" ]]
[[ $(grep -c '^install$' "$work/success-install/calls") -eq 1 ]]
run_case retry-success 1 99 0 --install
[[ $(grep -c '^pin ' "$work/retry-success/calls") -eq $((pin_count + 1)) ]]
[[ $(grep -c '^install$' "$work/retry-success/calls") -eq 1 ]]
echo 'opam pin exit propagation: PASS (6 isolated command scenarios)'
