(** Chronicle_index — index structure for navigating chronicle epochs.
    @since Project Chronicle Phase 1 *)

type epoch_summary =
  { id : string
  ; label : string
  ; start_date : string
  ; end_date : string
  ; status : Chronicle_types.epoch_status
  ; file_path : string
  }
[@@deriving yojson, show]

type index =
  { schema_version : int
  ; repo : string
  ; last_updated : string
  ; epochs : epoch_summary list
  ; last_commit_indexed : string
  }
[@@deriving yojson, show]

val current_schema_version : int

val empty : repo:string -> now:string -> index
(** Create an empty index with the current schema version. *)

val find_epoch : index -> string -> epoch_summary option
(** Look up an epoch by ID. *)

val active_epochs : index -> epoch_summary list
(** Return only epochs with [Active] status. *)

val add_or_replace_epoch : index -> epoch_summary -> index
(** Add or replace an epoch summary, returning a new index. *)
