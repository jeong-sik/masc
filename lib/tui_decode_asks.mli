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

type ask_asker =
  | Ask_keeper of string  (** the Keeper's name *)
  | Ask_installation of { ai_declaration_id : string; ai_title : string }
      (** A Lane Add-on installation, named by its declaration id; the title is
          the package's. It has no turn: [ar_source_turn_ref] is [None]. *)

val ask_asker_label : ask_asker -> string
(** The Keeper's name or the installation's title. *)

type ask_row = {
  ar_asker : ask_asker;
  ar_id : string;
  ar_asked_at : float;
  ar_source_turn_ref : Ids.Turn_ref.t option;
      (** Original asking execution from the question row, never the answer
          reaction or the Keeper's current turn. [None] is explicit null. *)
  ar_context : string option;
      (** why the Keeper is asking, in its own words. A row that hides this
          reads as a decision with no stakes. *)
  ar_questions : ask_question list;
  ar_resolution : ask_resolution;
}

type ask_key = { ak_asker : ask_asker; ak_id : string }
(** Which question a row is on this surface. A Keeper's ask id is unique in
    the workspace, but an installation's is the request id its package chose,
    unique only within that installation, so the asker is part of the key. *)

val ask_key : ask_row -> ask_key

val equal_ask_key : ask_key -> ask_key -> bool
(** Two installations are the same asker when their declaration ids are equal;
    the title is the package's and does not name the installation. *)

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

val decode_installation_asks : Yojson.Safe.t -> (ask_row list, string) result
(** Exactly [{"asks": [...]}] from [GET /api/v1/lane-addons/asks]. Each row
    has exactly the installation's [declaration_id], the package [title],
    [ask_id], [asked_at], [context], [questions] and [resolution]; questions
    and resolutions decode as Keeper rows do. The server checks the workspace
    from the request's expected paths and refuses a mismatch with 409. *)

val with_installation_asks : asks_snapshot -> ask_row list -> asks_snapshot
(** The Keeper snapshot followed by the installations' rows, with the open
    count raised by the installation rows that are open. *)

type installation_answer_receipt =
  | Installation_answer_recorded
  | Installation_answer_already_answered of { iaa_answered_at : float }
      (** Another answer was recorded first; the submitted choices are not it. *)
  | Installation_answer_withdrawn of { iaw_withdrawn_at : float }
  | Installation_answer_refused of string
      (** Unknown question (404) or answers that do not fit it (400). *)

val decode_installation_answer_receipt :
  expected_declaration_id:string -> expected_ask_id:string -> status_code:int ->
  Yojson.Safe.t -> (installation_answer_receipt, string) result
(** [POST /api/v1/lane-addons/ask-answer]. A 200 must name the requested
    declaration and ask. Any status other than 200, 400, 404 and 409 is
    [Error]: recording is unconfirmed, not refused. 401 and 403 are read by
    the caller as refusals before decoding. *)

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
  ata_outcome : Tool_result.recorded_call_outcome;
}

type ask_tool_outcomes = {
  ato_succeeded : int; ato_deferred : int; ato_failed : int;
  ato_unsettled : int; ato_malformed : int;
}
type ask_tool_actions =
  | Ask_tools_unavailable
  | Ask_tools_observed of {
      at_count : int;
      at_outcomes : ask_tool_outcomes;
      at_first_recorded_at : float option;
      at_latest : ask_tool_action option;
      at_evidence_current : bool;
    }
(** All five nonnegative outcome buckets sum to the physical result count.
    A latest result must belong to a nonempty corresponding bucket. These
    recorded call outcomes do not establish useful work or Task completion. *)

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

type ask_reactions =
  | Ask_reactions_unavailable
  | Ask_reactions_observed of {
      ar_turn_started_at : float option;
      ar_turn_finished_at : float option;
      ar_queue_settled_at : float option;
      ar_queue_cancelled_at : float option;
      ar_evidence_complete : bool;
      ar_evidence_current : bool;
    }
(** Unavailable is distinct from an observed empty or quarantined ledger.
    Retained same-source observations have [ar_evidence_current=false]. *)

type ask_followup = {
  af_answered_at : float;
  af_stimulus_id : string;
  af_reactions : ask_reactions;
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

type ask_followup_identity = private {
  afi_answered_at : float;
  afi_stimulus_id : string;
}
type ask_followup_source =
  | Ask_followup_reactions of ask_reactions
  | Ask_followup_tools of ask_tool_actions
  | Ask_followup_task of ask_linked_task
type ask_followup_event =
  | Ask_followup_started of ask_followup_identity
  | Ask_followup_source of ask_followup_identity * ask_followup_source
  | Ask_followup_completed of ask_followup_identity

val decode_ask_followup_event :
  expected_base_path:string -> expected_masc_root:string ->
  keeper_name:string -> ask_id:string -> Yojson.Safe.t ->
  (ask_followup_event, string) result
(** Every frame retains full workspace, original answer and Keeper/Ask identity.
    A source frame contains only the named source, never placeholders for peers. *)

type ask_followup_stream
val empty_ask_followup_stream : ask_followup_stream
val accept_ask_followup_event :
  ask_followup_stream -> ask_followup_event -> (ask_followup_stream, string) result
val finish_ask_followup_stream : ask_followup_stream -> (unit, string) result
(** Require a single start, each typed source exactly once, then completion with
    the unchanged answer identity. EOF alone, duplicate or missing sources,
    changed identity and events after completion cannot establish a full read. *)

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

type answer_receipt =
  | Keeper_answer_receipt of ask_answer_receipt
  | Installation_answer_receipt of installation_answer_receipt
(** The receipt of the route the asker's answer goes to. A Keeper's answer
    wakes the Keeper; an installation's answer starts its host request cycle. *)

val decode_ask_answer_receipt :
  expected_ask_id:string ->
  status_code:int ->
  Yojson.Safe.t ->
  (ask_answer_receipt, string) result
(** Bind recording evidence to the exact requested ask, preserving an HTTP
    500 partial receipt. Missing, contradictory or mismatched evidence is
    [Error], meaning recording is unconfirmed, not proven absent. *)
