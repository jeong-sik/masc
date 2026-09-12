#!/usr/bin/env bash
# Dependency install for the MASC bench agent, split out of bootstrap.sh so
# image/probe_bases.sh can exercise it against a task base image on its own,
# without a rendered config, a token or a server. Sourced, not executed:
# bootstrap.sh calls bench_install_deps after it has set BENCH.
#
# Expects: BENCH (install root, with bin/masc already in place).

bench_install_deps() {
  # --- dependencies -----------------------------------------------------------
  # Terminal-Bench task images are not one distro. The 4.0 set alone ships
  # ubuntu 24.04 and 22.04, debian-based python:*-slim, fedora, micromamba, coq,
  # node, bun and cuda bases. The 2026-09-11 matrix lost 36 of 72 trials per arm
  # to a single hardcoded `libssl3t64`, which exists only on ubuntu 24.04.
  #
  # So: install by package-manager family, ask for the runtime libraries only if
  # the binary cannot already run, and fail with the distro named rather than
  # with apt's "Unable to locate package".
  export DEBIAN_FRONTEND=noninteractive

  masc_runs() { "$BENCH/bin/masc" --version >/dev/null 2>&1; }

  pm_install() {
    # $@ = package names for the detected family, already translated by caller
    [[ $# -eq 0 ]] && return 0
    if command -v apt-get >/dev/null 2>&1; then
      apt-get install -y -qq --no-install-recommends "$@" >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y -q "$@" >/dev/null
    elif command -v microdnf >/dev/null 2>&1; then
      microdnf install -y "$@" >/dev/null
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache "$@" >/dev/null
    else
      return 1
    fi
  }

  pm_refresh() {
    if command -v apt-get >/dev/null 2>&1; then apt-get update -qq
    elif command -v dnf >/dev/null 2>&1; then dnf makecache -q >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then apk update >/dev/null 2>&1 || true
    fi
  }

  distro_id() { ( . /etc/os-release 2>/dev/null && echo "${ID:-unknown} ${VERSION_ID:-}" ) || echo unknown; }

  pm_refresh || true

  # Operational tools. sshd is not optional: the keeper exec lane is remote_ssh
  # back into this same container. gh is not optional either — the keeper_up
  # preflight runs `gh auth status` and refuses without a GitHub identity — and
  # it is absent from debian stable, so it is shipped in dist/ instead of
  # installed. jq and curl drive the MCP client in driver/mcp.sh.
  if command -v apt-get >/dev/null 2>&1; then
    pm_install openssh-server jq curl ca-certificates git || true
  elif command -v dnf >/dev/null 2>&1 || command -v microdnf >/dev/null 2>&1; then
    pm_install openssh-server openssh-clients jq curl ca-certificates git || true
  elif command -v apk >/dev/null 2>&1; then
    pm_install openssh jq curl ca-certificates git bash || true
  else
    echo "no supported package manager (apt/dnf/apk) on $(distro_id)" >&2
    exit 1
  fi

  # gh ships in dist/ when fetched; fall back to the package manager if not.
  if [[ -x "$BENCH/bin/gh" ]]; then
    install -m 0755 "$BENCH/bin/gh" /usr/local/bin/gh
  elif ! command -v gh >/dev/null 2>&1; then
    pm_install gh || true
  fi

  # Runtime libraries: only if the binary cannot already run. ldd on the 0.35.x
  # release names libssl/libcrypto 3, libgmp 10 and libzstd 1 on top of libc.
  if ! masc_runs; then
    if command -v apt-get >/dev/null 2>&1; then
      # ubuntu 24.04 renamed the openssl runtime for the time_t transition.
      pm_install libssl3t64 libgmp10 libzstd1 || pm_install libssl3 libgmp10 libzstd1 || true
    elif command -v dnf >/dev/null 2>&1 || command -v microdnf >/dev/null 2>&1; then
      pm_install openssl-libs gmp libzstd || true
    elif command -v apk >/dev/null 2>&1; then
      pm_install libssl3 libcrypto3 gmp zstd-libs gcompat || true
    fi
  fi

  if ! masc_runs; then
    echo "masc cannot run on $(distro_id); missing shared libraries:" >&2
    ldd "$BENCH/bin/masc" 2>&1 | grep -i 'not found' >&2 || \
      "$BENCH/bin/masc" --version >&2 || true
    exit 1
  fi

  if ! command -v sshd >/dev/null 2>&1 && [[ ! -x /usr/sbin/sshd ]]; then
    echo "sshd is absent on $(distro_id) after install; the keeper exec lane needs it" >&2
    exit 1
  fi

  # --- Claude Code subscription lane (runtime_id claude_code.<model>) ---
  # The keeper's model runtime is the unmodified Claude Code CLI (masc protocol
  # "claude-code"). Install it the way harbor's own claude-code agent does
  # (native installer, no node) and refuse to start the server unless the CLI
  # already sees the subscription token: masc probes `claude auth status --json`
  # before the first turn and a missing login would surface as a turn failure
  # minutes later instead of here.
  if [[ "${BENCH_RUNTIME_ID:-}" == claude_code.* ]]; then
    : "${CLAUDE_CODE_OAUTH_TOKEN:?claude_code lane requires CLAUDE_CODE_OAUTH_TOKEN (claude setup-token)}"
    if ! command -v claude >/dev/null 2>&1; then
      curl -fsSL https://downloads.claude.ai/claude-code-releases/bootstrap.sh | bash -s --
      ln -sf /root/.local/bin/claude /usr/local/bin/claude
    fi
    claude --version
    if ! claude auth status --json \
        | jq -e '.loggedIn == true and .authMethod == "oauth_token"' >/dev/null; then
      echo "claude auth status does not report the oauth_token login:" >&2
      claude auth status --json >&2 || true
      exit 1
    fi
  fi
}
