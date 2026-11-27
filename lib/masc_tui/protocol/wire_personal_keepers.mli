(** Strict fail-closed wire codecs, validators, and honest outcome formatters
    for Multi-Account Personal Keepers ([/api/v1/auth/keepers*]).

    Contracts match server ground truth in:
    - [lib/auth_preview_keeper.ml]
    - [lib/server/server_preview_keeper_conversation.ml]
    - [lib/server/server_preview_keeper_turn.ml]
    - [lib/server/server_preview_keeper_error.ml]
    - [lib/keeper_registry/keeper_id.ml]
    - [lib/core/safe_identifier.ml]
    - [lib/auth/authz_id.ml] *)

open Masc_tui_core

val keepers_path : string
val assign_path : string
val turn_path : string
val conversation_path : string
val conversation_read_path : keeper_id:string -> ?conversation_id:string -> unit -> string
val conversation_delete_path : conversation_id:string -> string

val max_keeper_id_length : int
val max_authz_id_length : int
val max_message_bytes : int
val turn_timeout_sec : float
val delete_timeout_sec : float

(** {1 Client-side Validators Matching Server Contracts} *)

val validate_keeper_id : string -> (string, string) result
val validate_authz_id : field:string -> string -> (string, string) result

type turn_message_error =
  | Message_blank
  | Message_too_long of { bytes : int; max_bytes : int }

val validate_turn_message : string -> (string, turn_message_error) result

(** {1 Strict Wire Types} *)

type personal_keeper = {
  keeper_id : string;
  runtime_id : string option;
}

type make_record =
  | Record_made
  | Record_existing

val equal_make_record : make_record -> make_record -> bool
val make_record_to_string : make_record -> string

type made_keeper = {
  keeper_id : string;
  record : make_record;
}

type assign_record =
  | Record_assigned
  | Record_assign_existing

val equal_assign_record : assign_record -> assign_record -> bool
val assign_record_to_string : assign_record -> string

type assigned_keeper = {
  keeper_id : string;
  runtime_id : string;
  record : assign_record;
}

type conversation_deletion =
  | Deletion_kept
  | Deletion_failed

val equal_conversation_deletion :
  conversation_deletion -> conversation_deletion -> bool

type conversation_summary = {
  conversation_id : string;
  provider_account_id : string;
  started_at_ms : int;
  deletion : conversation_deletion;
}

type turn_failure =
  | Failure_not_signed_in
  | Failure_key_refused
  | Failure_no_quota
  | Failure_silent
  | Failure_not_started
  | Failure_configuration_refused
  | Failure_no_answer
  | Failure_unrecognised of string

val equal_turn_failure : turn_failure -> turn_failure -> bool
val turn_failure_to_string : turn_failure -> string
val turn_failure_say : turn_failure -> Say.t

type turn_outcome =
  | Turn_answered of {
      text : string;
      model : string;
      answered_at_ms : int;
    }
  | Turn_failed of {
      failure : turn_failure;
      failed_at_ms : int;
      model_may_have_read : bool;
    }
  | Turn_unrecorded of { model_may_have_read : bool }

type conversation_turn = {
  message : string;
  asked_at_ms : int;
  outcome : turn_outcome;
}

type conversation_snapshot = {
  keeper_id : string;
  current_conversation_id : string option;
  conversations : conversation_summary list;
  conversation_id : string option;
  turns : conversation_turn list;
}

type started_conversation = {
  keeper_id : string;
  conversation_id : string;
}

type turn_recording =
  | Turn_recorded of {
      conversation_id : string;
      continued : bool;
    }
  | Turn_ephemeral

type turn_answer = {
  keeper_id : string;
  runtime_id : string;
  model : string;
  text : string;
  recording : turn_recording;
}

type vendor_copy_state =
  | Vendor_copy_removed
  | Vendor_copy_none
  | Vendor_copy_may_remain

val equal_vendor_copy_state : vendor_copy_state -> vendor_copy_state -> bool
val vendor_copy_state_to_string : vendor_copy_state -> string
val vendor_copy_outcome_say : vendor_copy_state -> Say.t

type deleted_conversation = {
  conversation_id : string;
  vendor_copy : vendor_copy_state;
}

(** {1 Exact Request Encoders} *)

val encode_make_keeper : keeper_id:string -> Yojson.Safe.t
(** Exact 1-key JSON object [{"keeper_id": "<name>"}]. *)

val encode_assign_keeper :
  keeper_id:string -> runtime_id:string -> Yojson.Safe.t
(** Exact 2-key JSON object with strict key order: [keeper_id] first,
    [runtime_id] second. *)

val encode_start_conversation : keeper_id:string -> Yojson.Safe.t
(** Exact 1-key JSON object [{"keeper_id": "<name>"}]. *)

val encode_turn : keeper_id:string -> message:string -> Yojson.Safe.t
(** Exact 2-key JSON object [{"keeper_id": "<name>", "message": "<text>"}]. *)

(** {1 Fail-Closed Response Decoders} *)

val decode_keepers_list : Yojson.Safe.t -> (personal_keeper list, string) result

val decode_made_keeper :
  expected_keeper_id:string -> Yojson.Safe.t -> (made_keeper, string) result

val decode_assigned_keeper :
  expected_keeper_id:string ->
  expected_runtime_id:string ->
  Yojson.Safe.t ->
  (assigned_keeper, string) result

val decode_conversation :
  expected_keeper_id:string ->
  ?requested_conversation_id:string ->
  Yojson.Safe.t ->
  (conversation_snapshot, string) result

val decode_started_conversation :
  expected_keeper_id:string ->
  Yojson.Safe.t ->
  (started_conversation, string) result

val decode_turn_answer :
  expected_keeper_id:string -> Yojson.Safe.t -> (turn_answer, string) result

val decode_deleted_conversation :
  expected_conversation_id:string ->
  Yojson.Safe.t ->
  (deleted_conversation, string) result
