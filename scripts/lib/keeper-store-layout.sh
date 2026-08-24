#!/usr/bin/env bash
# Keeper runtime store layout, read from the OCaml owner.
#
# Common.keeper_runtime_store owns the dirname of every keeper runtime store.
# Shell consumers used to assemble the same paths from their own literals, so a
# rename in Common left them checking a directory that no longer exists — and a
# gate that finds nothing reports the same "clean" as one that finds nothing
# wrong (#27583).
#
# Nothing is cached: the manifest binary prints what the compiler owns.

KEEPER_STORE_LAYOUT_SCHEMA="masc.keeper_runtime_store_layout.v1"

# keeper_store_dirname <repo-root> <dirname>
#
# Echoes <dirname> after confirming the owner still declares it. A caller that
# names a store the owner dropped gets a non-zero exit instead of a path that
# silently lists nothing.
keeper_store_dirname () {
  local repo_root="${1:-}"
  local want="${2:-}"
  local exe="${KEEPER_STORE_LAYOUT_MANIFEST_EXE:-${repo_root}/_build/default/bin/keeper_store_layout_manifest.exe}"

  if [ ! -x "$exe" ]; then
    printf 'keeper store layout manifest not built: %s\n' "$exe" >&2
    printf 'Run: dune build bin/keeper_store_layout_manifest.exe\n' >&2
    return 1
  fi

  local manifest
  manifest="$("$exe")" || {
    printf 'keeper store layout manifest failed to run\n' >&2
    return 1
  }

  case "$manifest" in
    *"\"$KEEPER_STORE_LAYOUT_SCHEMA\""*) ;;
    *)
      printf 'unexpected keeper store layout schema\n' >&2
      return 1
      ;;
  esac

  case "$manifest" in
    *"\"dirname\": \"$want\""*)
      printf '%s' "$want"
      ;;
    *)
      printf '%s is not a keeper runtime store per the OCaml owner\n' "$want" >&2
      return 1
      ;;
  esac
}
