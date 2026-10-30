#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
fixture="$(cd "$fixture" && pwd -P)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/package/dist/extension" "$fixture/bin" "$fixture/base"
printf '%s\n' fresh > "$fixture/package/dist/extension/manifest.json"
tar -czf "$fixture/package.tgz" -C "$fixture" package
digest="sha512-$(openssl dgst -sha512 -binary "$fixture/package.tgz" | base64 | tr -d '\n')"
sed "s|^integrity=\".*\"$|integrity=\"$digest\"|" \
  "$repo_root/connectors/browser/install-stagehand-extension.sh" > "$fixture/installer.sh"

cat > "$fixture/bin/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = pack ] || exit 2
cp "$MASC_TEST_STAGEHAND_ARCHIVE" stagehand-4.1.0.tgz
printf '%s\n' stagehand-4.1.0.tgz
EOF
cat > "$fixture/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${MASC_TEST_FAIL_INSTALL_MOVE:-}" = 1 ] && [ "$2" = "$MASC_TEST_STAGEHAND_TARGET" ]; then
  case "$1" in
    */.stagehand-extension-stage.*/extension) exit 73 ;;
  esac
fi
exec "$MASC_TEST_REAL_MV" "$@"
EOF
cat > "$fixture/bin/chmod" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${MASC_TEST_FAIL_STAGE_CHMOD:-}" = 1 ] && [ "$1" = -R ]; then
  exit 74
fi
exec "$MASC_TEST_REAL_CHMOD" "$@"
EOF
chmod +x "$fixture/bin/npm" "$fixture/bin/mv" "$fixture/bin/chmod"

target="$fixture/base/.masc/browser-lane/stagehand-extension/4.1.0"
export MASC_TEST_STAGEHAND_ARCHIVE="$fixture/package.tgz"
export MASC_TEST_STAGEHAND_TARGET="$target"
MASC_TEST_REAL_MV="$(command -v mv)"
MASC_TEST_REAL_CHMOD="$(command -v chmod)"
export MASC_TEST_REAL_MV MASC_TEST_REAL_CHMOD
export PATH="$fixture/bin:$PATH"

bash "$fixture/installer.sh" --base-path "$fixture/base" > "$fixture/first.out"
[ "$(cat "$target/manifest.json")" = fresh ]
printf '%s\n' previous > "$target/manifest.json"

if MASC_TEST_FAIL_INSTALL_MOVE=1 bash "$fixture/installer.sh" --base-path "$fixture/base" \
    > "$fixture/move.out" 2>&1; then
  echo "installation should fail when the final move fails" >&2
  cat "$fixture/move.out" >&2
  exit 1
fi
[ "$(cat "$target/manifest.json")" = previous ]

if MASC_TEST_FAIL_STAGE_CHMOD=1 bash "$fixture/installer.sh" --base-path "$fixture/base" \
    > "$fixture/chmod.out" 2>&1; then
  echo "installation should fail when staged permissions cannot be set" >&2
  exit 1
fi
[ "$(cat "$target/manifest.json")" = previous ]

cp "$fixture/package.tgz" "$fixture/tampered.tgz"
printf x >> "$fixture/tampered.tgz"
if MASC_TEST_STAGEHAND_ARCHIVE="$fixture/tampered.tgz" \
    bash "$fixture/installer.sh" --base-path "$fixture/base" \
    > "$fixture/integrity.out" 2>&1; then
  echo "installation should reject a tarball with a different digest" >&2
  exit 1
fi
[ "$(cat "$target/manifest.json")" = previous ]

bash "$fixture/installer.sh" --base-path "$fixture/base" > "$fixture/reinstall.out"
[ "$(cat "$target/manifest.json")" = fresh ]
remaining="$(find "$(dirname "$target")" -maxdepth 1 -name '.stagehand-extension-*' -print -quit)"
if [ -n "$remaining" ]; then
  echo "a successful reinstall left a staging or backup directory" >&2
  exit 1
fi

echo "stagehand installer preserves the previous extension on move, chmod, and digest failures"
