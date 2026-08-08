#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
case "${DUNE_BUILD_DIR:-}" in
  "") build_root="${repo_root}/_build" ;;
  /*) build_root="${DUNE_BUILD_DIR}" ;;
  *) build_root="${repo_root}/${DUNE_BUILD_DIR}" ;;
esac
probe_source="${build_root}/default/test/model_catalog_standalone_probe.exe"
isolated_dir="$(mktemp -d)"

cleanup() {
  rm -rf "${isolated_dir}"
}
trap cleanup EXIT

"${repo_root}/scripts/dune-local.sh" build test/model_catalog_standalone_probe.exe
install -m 0755 "${probe_source}" "${isolated_dir}/model-catalog-probe"

cd "${isolated_dir}"
OAS_MODEL_CATALOG="${isolated_dir}/must-not-be-read.toml" ./model-catalog-probe
