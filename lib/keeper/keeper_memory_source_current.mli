(** Current memory claims whose truth is bound to one keeper-visible file.

    This store is separate from the existing LLM-selected Memory OS snapshot:
    only explicit [keeper_memory_write] calls carrying [source_path] enter it.
    Before a claim is recalled, the source file is read again and its exact
    bytes are compared with the recorded SHA-256. Changed or unavailable
    sources become durable invalidations and their old claims are not returned.

    The persisted shape is current-only and closed. A missing file means fresh
    empty state; no retired shape or alternate store is read. *)

type file_source =
  { path : string
  ; sha256 : string
  }

type fact =
  { claim : string
  ; first_seen : float
  ; source : file_source
  }

type invalidation_reason =
  | Source_changed
  | Source_unavailable

type invalidation =
  { source_path : string
  ; invalidated_at : float
  ; reason : invalidation_reason
  }

type t =
  { revision : int
  ; updated_at : float
  ; trace_id : string
  ; facts : fact list
  ; invalidations : invalidation list
  }

type projection =
  { snapshot : t option
  ; facts : fact list
  ; invalidations : invalidation list
  }

type write_error =
  | Source_read_failed of string
  | Store_write_failed of string

val write_error_detail : write_error -> string

val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

val read_for_keepers_dir :
  keepers_dir:string -> keeper_id:string -> (t option, string) result

(** Maximum source bytes read on the write and recall paths. *)
val max_source_bytes : int

(** Read one keeper-visible regular file within the keeper sandbox. Refuses an
    absent, non-regular, or oversized source. *)
val read_source :
  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> source_path:string
  -> (string, string) result

(** Upsert the single current claim for [source_path]. The exact source bytes
    are read inside this call; callers cannot supply their own digest. A
    successful replacement clears the pending invalidation for that path. *)
val upsert_file_fact :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> keepers_dir:string
  -> now:float
  -> claim:string
  -> source_path:string
  -> unit
  -> (t, write_error) result

(** Re-read every current source under the same sandbox resolver used by the
    write path. Unchanged facts remain current. Changed or unreadable sources
    are atomically removed and replaced by pending invalidations. Invalidations
    survive subsequent turns until [upsert_file_fact] recreates that path. *)
val revalidate :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> keepers_dir:string
  -> now:float
  -> unit
  -> (projection, string) result

val invalidation_reason_to_string : invalidation_reason -> string
val render_fact : fact -> string
val render_invalidation : invalidation -> string
val to_json : t -> Yojson.Safe.t
