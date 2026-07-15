(** Chronicle_types — data model for the Project Chronicle system.
    @since Project Chronicle Phase 1 *)

type causation_entry =
  { trigger : string
  ; conclusion : string
  ; rationale : string
  }
[@@deriving yojson, show]

type outcome_kind =
  | Positive
  | Negative
  | Mixed
[@@deriving yojson, show]

type lesson_entry =
  { pattern : string
  ; context : string
  ; outcome : outcome_kind
  }
[@@deriving yojson, show]

type epoch_status =
  | Active
  | Completed
  | Abandoned
[@@deriving yojson, show]

type key_file_role =
  { path : string
  ; role : string
  }
[@@deriving yojson, show]

type chronicle_epoch =
  { id : string
  ; label : string
  ; repo : string
  ; start_date : string
  ; end_date : string
  ; start_commit : string
  ; end_commit : string
  ; status : epoch_status
  ; causation : causation_entry list
  ; outcomes_achieved : string list
  ; outcomes_failed : string list
  ; lessons : lesson_entry list
  ; key_files : key_file_role list
  ; rfc_refs : string list
  ; historian_validated_at : string option
  }
[@@deriving yojson, show]

val epoch_id : year:string -> label:string -> string
(** Construct a deterministic epoch ID from year and short label. *)

val is_active : chronicle_epoch -> bool
val is_completed : chronicle_epoch -> bool

val lesson_counts : chronicle_epoch -> int * int * int
(** Returns (positive, negative, mixed) lesson counts. *)
