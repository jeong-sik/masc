(** Prompt_registry_store — process-wide prompt registry state +
    its mutex.

    Owns the four Hashtbls and two refs that {!Prompt_registry}
    rebinds at the top level so the rest of the codebase can
    keep using the bare names ([Prompt_registry.registry] /
    [Prompt_registry.override_tbl] / etc) while the storage
    layout itself lives in this module.

    The record is exposed concretely because every field is
    rebound by name in [prompt_registry.ml]; hiding the layout
    behind an abstract type would force a getter helper for each
    field without making the abstraction any richer.

    Internal helper [default_state] (the cached singleton) is
    hidden — callers consume it through the {!default} accessor. *)

type t = {
  registry : (string, Prompt_registry_types.prompt_entry) Hashtbl.t;
  version_index : (string, string list) Hashtbl.t;
  override_tbl : (string, string) Hashtbl.t;
  meta_tbl : (string, Prompt_registry_types.prompt_meta) Hashtbl.t;
  prompts_dir : string option ref;
  markdown_dir : string option ref;
  mutex : Eio.Mutex.t;
}

val create : unit -> t
(** Build a fresh store with empty Hashtbls (capacities matched
    to historical workload — 64 / 64 / 16 / 32), [None] dir refs,
    and a fresh [Eio.Mutex.t]. Tests use this to avoid cross-case
    pollution. *)

val default : unit -> t
(** Return the process-wide singleton store. Identity-stable
    across calls; prefer {!create} in tests when isolation is
    required. *)

val with_lock : t -> (unit -> 'a) -> 'a
(** Run [f ()] under the store's mutex via
    [Eio_guard.with_mutex]. The lock is released on every exit
    path including exceptions and ambient cancel; callers must
    not block on disk / network I/O inside [f] (the prompt
    registry mutex is hot-path). *)
