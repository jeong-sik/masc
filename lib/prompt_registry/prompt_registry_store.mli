(** Prompt_registry_store — process-wide prompt registry state +
    its read/write and override-mutation mutexes.

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
  override_tbl :
    (string, Prompt_override_persistence.entry) Hashtbl.t;
  meta_tbl : (string, Prompt_registry_types.prompt_meta) Hashtbl.t;
  prompts_dir : string option ref;
  markdown_dir : string option ref;
  mutex : Eio.Mutex.t;
  override_mutation_mutex : Eio.Mutex.t;
}

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

val with_override_mutation_lock : t -> (unit -> 'a) -> 'a
(** Serialize override mutations and persistence transactions.  The dedicated
    Eio mutex may be held across filesystem I/O; readers continue to use
    [with_lock] and observe the old immutable snapshot until commit. *)
