#!/usr/bin/env bash
# Build inside the Linux release container, before the OCaml SQLite bindings.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
sqlite_version=3.53.4
sqlite_archive=sqlite-autoconf-3530400
sqlite_sha3=454e45f61c6bd75b7420e7190732dea03ce6639c63ada47bbc592f67fc340338
sqlite_build_dir=$(mktemp -d /tmp/masc-release-sqlite-XXXXXX)
curl -fsSL "https://sqlite.org/2026/${sqlite_archive}.tar.gz" -o "$sqlite_build_dir/source.tar.gz"
actual_sha3=$(openssl dgst -sha3-256 "$sqlite_build_dir/source.tar.gz" | awk '{print $NF}')
test "$actual_sha3" = "$sqlite_sha3" || { echo 'SQLite source digest mismatch' >&2; exit 1; }
tar -xzf "$sqlite_build_dir/source.tar.gz" -C "$sqlite_build_dir"
cd "$sqlite_build_dir/$sqlite_archive"
# PIC lets the OCaml binding shared stub use this same static archive. Keep
# FTS and RTree support and the column metadata API supplied by distro SQLite.
./configure --prefix=/usr/local --disable-shared --enable-static --fts4 --fts5 --rtree \
  CFLAGS='-O2 -fPIC -DSQLITE_ENABLE_COLUMN_METADATA'
make -j "${1:-2}"
make install
test "$(pkg-config --modversion sqlite3)" = "$sqlite_version"
test "$(pkg-config --variable=prefix sqlite3)" = /usr/local
pkg-config --cflags --libs sqlite3
echo "== SQLite $sqlite_version source SHA3-256 $sqlite_sha3"
result=$(/usr/local/bin/sqlite3 :memory: < "$script_dir/check-release-sqlite.sql")
test "$result" = $'1\n1' || { printf 'SQLite lifecycle transition check failed: %s\n' "$result" >&2; exit 1; }
echo '== SQLite STRICT REAL lifecycle transitions passed'
