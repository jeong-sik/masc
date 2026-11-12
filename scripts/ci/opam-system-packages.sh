#!/usr/bin/env bash
# Sourced by the two CI steps that call `opam install`:
# scripts/opam-pin-external-deps.sh --install and
# .github/actions/install-ocaml-deps/install.sh.
#
# A switch restored from the cache was built on a runner that had its system
# packages. A fresh runner has none of conf-protoc's, so opam marks
# conf-protoc for a rebuild and fetches libprotobuf-dev and
# protobuf-compiler from the apt mirror on every run; the run fails whenever
# the mirror does not answer (issue #51372). A job that only type-checks
# uses neither package: it sets MASC_SYSTEM_PACKAGES_ON_RESTORED_SWITCH=skip,
# and its steps first ask opam to build what the lock changed without
# looking for system packages (--no-depexts). When that install fails, the
# step installs them as it does everywhere else.
#
# opam records in the switch the packages it was told not to look for, so
# this is only for a run that restores the cache and never saves it:
# setup-ocaml-toolchain sets MASC_OPAM_SWITCH_RESTORE_ONLY=true then.
opam_may_skip_system_packages() {
  [ "${MASC_SYSTEM_PACKAGES_ON_RESTORED_SWITCH:-install}" = "skip" ] \
    && [ "${MASC_OPAM_SWITCH_RESTORE_ONLY:-}" = "true" ]
}
