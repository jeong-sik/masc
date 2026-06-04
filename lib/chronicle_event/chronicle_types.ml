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
  ; goal_ids : string list
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

let epoch_id ~year ~label =
  Printf.sprintf "%s-%s" year label

let is_active (epoch : chronicle_epoch) =
  match epoch.status with Active -> true | Completed | Abandoned -> false

let is_completed (epoch : chronicle_epoch) =
  match epoch.status with Completed -> true | Active | Abandoned -> false

let lesson_counts (epoch : chronicle_epoch) =
  let pos = ref 0 and neg = ref 0 and mix = ref 0 in
  List.iter (fun (l : lesson_entry) ->
    match l.outcome with
    | Positive -> incr pos
    | Negative -> incr neg
    | Mixed -> incr mix)
    epoch.lessons;
  (!pos, !neg, !mix)
