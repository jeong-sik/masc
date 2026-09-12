#!/usr/bin/env bash
# Does the bench dependency install survive a Terminal-Bench task base image?
#
# The 2026-09-11 matrix lost 36 of 72 trials per MASC arm before a single LLM
# token was spent, because bootstrap.sh asked apt for `libssl3t64` — a package
# that exists only on ubuntu 24.04. This probe answers the same question for
# free: it runs driver/deps.sh against a base image and reports whether the
# masc binary can run and sshd exists afterwards. No API key, no task, no
# server.
#
#   ./image/probe_bases.sh                    # the 4.0 set's distinct bases
#   ./image/probe_bases.sh ubuntu:22.04 ...   # specific images
#
# Base images seen in terminal-bench@4.0.0 (66 tasks, counted 2026-09-12):
#   ubuntu:24.04 x14, python:3.1x-slim(-bookworm) x30+, ubuntu:22.04 x3,
#   mambaorg/micromamba x3, plus fedora, coq, node, bun, playwright, cuda,
#   temurin, vllm and debian:12-slim singletons.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(dirname "$HERE")"
DIST_DIR="${BENCH_DIR}/dist"
PLATFORM="${PROBE_PLATFORM:-linux/amd64}"
TIMEOUT_SEC="${PROBE_TIMEOUT_SEC:-600}"

DEFAULT_IMAGES=(
  ubuntu:24.04
  ubuntu:22.04
  python:3.13-slim
  python:3.12-slim-bookworm
  debian:12-slim
  fedora:42
  node:22-bookworm-slim
  mambaorg/micromamba:1.5
)

images=("$@")
[[ ${#images[@]} -eq 0 ]] && images=("${DEFAULT_IMAGES[@]}")

[[ -x "${DIST_DIR}/masc" ]] || { echo "run image/fetch_masc.sh first" >&2; exit 1; }

# deps.sh is bash and is meant to be sourced; the probe reproduces exactly what
# bootstrap.sh does with it, and nothing else.
probe='set -o pipefail
BENCH=/opt/masc-bench
. "$BENCH/driver/deps.sh"
if bench_install_deps; then
  printf "DEPS_OK version=%s sshd=%s gh=%s\n" \
    "$("$BENCH/bin/masc" --version 2>/dev/null | head -1)" \
    "$(command -v sshd || echo /usr/sbin/sshd)" \
    "$(command -v gh || echo none)"
else
  echo "DEPS_FAIL"
fi'

pass=0
fail=0
for image in "${images[@]}"; do
  printf '%-34s ' "$image"
  out="$(timeout "${TIMEOUT_SEC}" docker run --rm --platform "${PLATFORM}" \
    -v "${DIST_DIR}:/opt/masc-bench/bin:ro" \
    -v "${BENCH_DIR}/driver:/opt/masc-bench/driver:ro" \
    "${image}" bash -c "${probe}" 2>&1)"
  if grep -q DEPS_OK <<<"${out}"; then
    pass=$((pass + 1))
    grep -o 'DEPS_OK.*' <<<"${out}" | head -1
  else
    fail=$((fail + 1))
    # The last few lines carry the package manager's own complaint, which is
    # the thing worth reading.
    echo "FAIL"
    tail -4 <<<"${out}" | sed 's/^/    /'
  fi
done
echo "---"
echo "pass ${pass} / $((pass + fail))"
[[ ${fail} -eq 0 ]]
