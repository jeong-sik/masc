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

(** Why a source file could not be read. The first four are the caller's to
    fix -- the path, not the store, is wrong; only [Source_io_failed] is the
    filesystem not answering. *)
type source_read_failure =
  | Source_path_rejected of string
      (** Empty, or outside the keeper's read boundary; the boundary's own reason. *)
  | Source_missing
  | Source_not_a_regular_file
  | Source_too_large of
      { actual_bytes : int
      ; max_bytes : int
      }
  | Source_io_failed of string

val source_read_failure_to_string : source_read_failure -> string

type write_error =
  | Source_read_failed of source_read_failure
  | Store_write_failed of string

val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

val list_keeper_ids_for_keepers_dir : keepers_dir:string -> string list
(** Every keeper id this store holds a file for, sorted. Read by the deploy
    preflight: this module's decoder refuses a row carrying an unknown field,
    so a deploy that changes the shape has to be told before it switches
    over, and nothing else reads the whole store. *)

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
  -> (string, source_read_failure) result

(** Upsert the single current claim for [source_path]. The exact source bytes
    are read inside this call; callers cannot supply their own digest. A
    successful replacement clears the pending invalidation for that path.

    The write is independent of prompt rendering capacity; current truth is
    never rejected because of a presentation threshold. *)
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
    survive subsequent turns until [upsert_file_fact] recreates that path.
    Revalidation takes only the source-store lock: its invalidation rendering
    is strictly shorter than the fact it replaces, so it cannot overcommit the
    aggregate byte reservation. *)
val revalidate :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> keepers_dir:string
  -> now:float
  -> unit
  -> (projection, string) result

val render_fact : fact -> string
val render_invalidation : invalidation -> string
val render_payload : fact list -> invalidation list -> string
val to_json : t -> Yojson.Safe.t
