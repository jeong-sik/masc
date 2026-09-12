#!/usr/bin/env bash
# Dependency install for the MASC bench agent, split out of bootstrap.sh so
# image/probe_bases.sh can exercise it against a task base image on its own,
# without a rendered config, a token or a server. Sourced, not executed:
# bootstrap.sh calls bench_install_deps after it has set BENCH.
#
# Expects: BENCH (install root, with bin/masc already in place).

# Why the masc binary would not start, from whatever the loader printed.
# Three unrelated causes land in the same place and each needs a different fix:
# a binary for another architecture, a glibc older than the binary's floor, and
# an actually missing shared library. Reporting all three as "missing shared
# libraries" sent a reader after apt packages while the real cause was an
# aarch64 binary in an amd64 container (2026-09-12).
#
# Separated from the reporting so it can be exercised without a container, a
# package manager or a binary — test/test_bench_deps_diagnosis.py feeds it the
# loader messages verbatim.
bench_masc_failure_reason() {
  case "$1" in
    *"cannot execute"*|*"Exec format error"*) echo arch ;;
    *GLIBC_*"not found"*) echo glibc ;;
    *) echo libraries ;;
  esac
}

bench_install_deps() {
  # --- dependencies -----------------------------------------------------------
  # Terminal-Bench task images are not one distro. The 4.0 set alone ships
  # ubuntu 24.04 and 22.04, debian-based python:*-slim, fedora, micromamba, coq,
  # node, bun and cuda bases, and a hardcoded `libssl3t64` names a package that
  # exists only on ubuntu 24.04.
  #
  # That is not what cost the 2026-09-11 matrix 36 of its 72 trials per arm.
  # Measured on 2026-09-12: 12 of the 24 mini-suite images are debian 12 with
  # glibc 2.36, and the released binary asks for GLIBC_2.38, so it cannot start
  # there at all — 12 tasks x 3 attempts is exactly the 36 that were lost, and
  # the 12 that survived are precisely the images at 2.39 or newer. Installing
  # packages cannot recover those; only a release built at a lower floor can
  # (masc#35321).
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
    pm_install openssh-server jq curl ca-certificates git ripgrep || true
  elif command -v dnf >/dev/null 2>&1 || command -v microdnf >/dev/null 2>&1; then
    pm_install openssh-server openssh-clients jq curl ca-certificates git ripgrep || true
  elif command -v apk >/dev/null 2>&1; then
    pm_install openssh jq curl ca-certificates git ripgrep bash || true
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
    # Three unrelated causes reach this point and each needs a different fix,
    # so name the one that actually happened. Reporting all three as "missing
    # shared libraries" sent a reader after apt packages when the binary was
    # built for another architecture entirely.
    why="$("$BENCH/bin/masc" --version 2>&1 || true)"
    case "$(bench_masc_failure_reason "$why")" in
      arch)
        echo "masc will not run on $(distro_id): wrong architecture." >&2
        echo "  container is $(uname -m); the binary in dist/ is for another one." >&2
        echo "  re-fetch with MASC_LINUX_ARCH matching the task images" >&2
        echo "  (Terminal-Bench images are amd64, so MASC_LINUX_ARCH=x64)." >&2
        ;;
      glibc)
        echo "masc will not run on $(distro_id): its glibc is too old." >&2
        echo "  container has $(ldd --version 2>&1 | head -1)" >&2
        printf '  binary asks for: %s\n' \
          "$(printf '%s' "$why" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)" >&2
        echo "  a release built at a lower floor is the fix, not a package." >&2
        ;;
      *)
        echo "masc cannot run on $(distro_id); missing shared libraries:" >&2
        ldd "$BENCH/bin/masc" 2>&1 | grep -i 'not found' >&2 || \
          printf '%s\n' "$why" >&2
        ;;
    esac
    exit 1
  fi

  if ! command -v sshd >/dev/null 2>&1 && [[ ! -x /usr/sbin/sshd ]]; then
    echo "sshd is absent on $(distro_id) after install; the keeper exec lane needs it" >&2
    exit 1
  fi

  # Everything perform_preflight probes, checked here by name instead of
  # surfacing one at a time as a keeper_up policy_rejection minutes later.
  missing=""
  # Everything the operational install is for, not only what preflight probes:
  # ca-certificates and a working sshd are equally load-bearing, and their
  # absence used to surface as a TLS error from an unrelated curl.
  for tool in git rg gh df jq curl ssh; do
    command -v "${tool}" >/dev/null 2>&1 || missing="${missing} ${tool}"
  done
  if [[ -n "${missing}" ]]; then
    echo "keeper_up preflight needs these on PATH, absent on $(distro_id):${missing}" >&2
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
