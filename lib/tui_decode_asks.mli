(** {1 Questions a Keeper put to the operator}

    Decoded from [GET /api/v1/keepers/asks]. The rows carry choice ids
    alongside labels and the answer POST takes ids back, so a surface built on
    these types never matches on label text: rewording a choice cannot orphan
    an answer already recorded. *)

type ask_choice = {
  ac_id : string;  (** what an answer names; never the label *)
  ac_label : string;
  ac_description : string option;
}

type ask_mode =
  | Ask_single
  | Ask_multi

type ask_free_text =
  | Ask_free_text_allowed of { aft_hint : string option }
  | Ask_choices_only

type ask_question = {
  aq_id : string;
  aq_header : string;  (** two or three words; what a narrow row shows *)
  aq_prompt : string;
  aq_mode : ask_mode;
  aq_free_text : ask_free_text;
  aq_choices : ask_choice list;
}

type ask_resolution =
  | Ask_open
  | Ask_answered of {
      aa_answered_at : float;
      aa_question_ids : string list;
    }
  | Ask_withdrawn of {
      aw_reason : string;
      aw_withdrawn_at : float;
    }

type ask_row = {
  ar_keeper : string;
  ar_id : string;
  ar_asked_at : float;
  ar_context : string option;
      (** why the Keeper is asking, in its own words. A row that hides this
          reads as a decision with no stakes. *)
  ar_questions : ask_question list;
  ar_resolution : ask_resolution;
}

type asks_snapshot = {
  asn_keeper : string option;
  asn_open_count : int;  (** the server's count, not [List.length asn_rows] *)
  asn_rows : ask_row list;
}

val decode_asks_snapshot :
  expected_base_path:string ->
  expected_masc_root:string ->
  Yojson.Safe.t ->
  (asks_snapshot, string) result
(** A row whose mode or free-text shape is unknown fails the decode rather
    than defaulting: a surface that guessed would offer the operator a control
    the server will refuse. Both expected paths are canonical absolute paths.
    The response must carry exactly one matching [workspace] object with one
    [base_path] and one [masc_root]; missing, duplicate or foreign identity is
    an error even when the question list is empty. Exactly one [state_ready]
    field must be [true]; a booting or unverified response cannot clear questions. *)

type ask_answer_delivery =
  | Ask_wake_stored
      (** The durable wake is accepted or previously delivered. This does not
          prove that a Keeper acted on the answer. *)
  | Ask_wake_pending of string
      (** The answer is recorded; automatic delivery recovery remains due. *)

type ask_tool_action = {
  ata_execution_id : string;
  ata_physical_execution_id : string;
  ata_trace_id : string;
  ata_keeper_turn_id : int;
  ata_tool : string;
  ata_recorded_at : float;
}

type ask_tool_actions =
  | Ask_tools_unavailable
  | Ask_tools_observed of {
      at_count : int;
      at_first_recorded_at : float option;
      at_latest : ask_tool_action option;
      at_evidence_current : bool;
    }

type ask_task_location = Ask_task_backlog | Ask_task_archive
type ask_linked_task =
  | Ask_task_unlinked
  | Ask_task_missing of string
  | Ask_task_unavailable of string
  | Ask_task_observed of {
      akt_task_id : string;
      akt_location : ask_task_location;
      akt_status : Masc_domain.task_status;
      akt_observed_at : float;
      akt_evidence_current : bool;
    }
(** The original question's declared Task, independently of delivery and Tool
    observations. Retained observations are explicitly not a current lookup.
    Missing means unobserved in the lookup, not deletion or completion. *)

type ask_followup = {
  af_answered_at : float;
  af_stimulus_id : string;
  af_turn_started_at : float option;
  af_turn_finished_at : float option;
  af_queue_settled_at : float option;
  af_queue_cancelled_at : float option;
  af_evidence_complete : bool;
  af_tool_actions : ask_tool_actions;
  af_linked_task : ask_linked_task;
}

val decode_ask_followup :
  expected_base_path:string -> expected_masc_root:string ->
  keeper_name:string -> ask_id:string -> Yojson.Safe.t ->
  (ask_followup, string) result
(** Decode one exact answer-followup response, including matching workspace,
    readiness, Keeper and Ask identities. Missing/malformed evidence is an
    error; an absent reaction clock means unobserved, not a negative verdict. *)

type ask_answer_receipt =
  | Ask_answer_recorded of ask_answer_delivery
  | Ask_answer_already_recorded of {
      aar_delivery : ask_answer_delivery;
      aar_answered_at : float;
    }
      (** Another canonical answer already exists. Submitted choice labels
          cannot describe that winner. *)
  | Ask_answer_written_unconfirmed of string
      (** The append succeeded, but its first winner could not be read.
          Do not attribute the submitted choices to the canonical answer. *)
  | Ask_answer_refused of string

val decode_ask_answer_receipt :
  expected_ask_id:string ->
  status_code:int ->
  Yojson.Safe.t ->
  (ask_answer_receipt, string) result
(** Bind recording evidence to the exact requested ask, preserving an HTTP
    500 partial receipt. Missing, contradictory or mismatched evidence is
    [Error], meaning recording is unconfirmed, not proven absent. *)
