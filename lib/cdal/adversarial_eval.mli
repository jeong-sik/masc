(** Adversarial_eval — Fresh-context adversarial evaluator.

    Layer 3 reviewer that operates with restricted context:
    only diff, changed files, type signatures, and interface contracts.

    Designed to catch structural defects that domain-aware reviewers miss.
    Output is advisory only — not a gate.

    Red line: this evaluator never sees README, design docs,
    room/task history, or governance history. *)

(** Allowed input types — anything not in this type is banned. *)
type allowed_input =
  | Diff of string
  | Changed_file of
      { path : string
      ; content : string
      }
  | Type_signature of
      { module_name : string
      ; signature : string
      }
  | Interface_contract of
      { path : string
      ; content : string
      }

(** Banned input classification for red-line enforcement. *)
type banned_input_kind =
  | Readme
  | Design_doc
  | Coord_history
  | Task_history
  | Governance_history

(** Advisory finding — not a gate, just a signal. *)
type advisory_finding =
  { finding_id : string
  ; severity : string (** "info" | "warn" | "error" *)
  ; category : string
  ; summary : string
  ; location : string option (** file:line if applicable *)
  }

type eval_context =
  { inputs : allowed_input list
  ; session_id : string
  ; evaluator_version : string
  }

type eval_result =
  { findings : advisory_finding list
  ; input_count : int
  ; is_advisory : bool (** Always true — not a gate *)
  }

val create_context : session_id:string -> inputs:allowed_input list -> eval_context

(** Check if a file path is banned. None = allowed. *)
val classify_path : string -> banned_input_kind option

(** Check that no banned content is present. *)
val validate_inputs
  :  allowed_input list
  -> (allowed_input list, string * banned_input_kind) result

(** Run adversarial evaluation. Structural checks only. *)
val evaluate : eval_context -> eval_result

val finding_to_yojson : advisory_finding -> Yojson.Safe.t
val result_to_yojson : eval_result -> Yojson.Safe.t
