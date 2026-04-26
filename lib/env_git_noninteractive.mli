(** Non-interactive git subprocess environment (RFC-0007 PR-1 / #9639 Cluster B).

    SSOT for the env-var pairs that must be set whenever MASC spawns [git]
    or [gh] in a non-tty subprocess (Docker sandbox or direct [Process_eio]
    call). Missing these constants silently hangs the subprocess on a
    credential prompt — the container has no tty to display it, so the
    timeout trips only after the outer wall-clock cap fires.

    Design reference: [GIT_NO_PROMPT_ENV] record in claude-code at
    [src/utils/worktree.ts:199-202] and [src/utils/plugins/marketplaceManager.ts:510-512].
    Principle P3 of RFC-0007: "Non-interactive defaults are a constant,
    not an opinion." *)

(** Canonical non-interactive env pairs. Must be merged into every
    subprocess environment that may invoke git/gh without a tty. *)
val env : (string * string) list

(** Flattened [K=V] strings suitable for prepending to a [Unix.environment]
    array. *)
val env_pairs : string list

(** Flattened ["-e"; "K=V"; ...] pairs for direct [docker run] argv. *)
val docker_args : string list

(** Backwards-compatible alias for {!docker_args}. *)
val docker_env_args : string list

(** Prepend {!env_pairs} to [env], stripping any pre-existing entries
    with matching keys so the canonical value wins. Preserves the order of
    non-matching entries. *)
val inject_into_environment : string array -> string array
