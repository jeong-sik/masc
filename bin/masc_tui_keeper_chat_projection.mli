(** One image staged with [:attach] and sent with the next message. [data] is
    raw base64 with no data-URL prefix and no newlines. *)
type attachment = {
  attachment_id : string;
  name : string;
  mime_type : string;
  size : int;
  data : string;
}

type request = {
  request_id : string;
  keeper_name : string;
  message : string;
  attachments : attachment list;
}

type acceptance_state =
  | Queued
  | Running
  | Succeeded
  | Failed
  | Cancelled

type acceptance = {
  state : acceptance_state;
  queued_count : int;
}

type turn_outcome = Masc.Keeper_turn_outcome.t =
  | Visible_reply
  | Continuation_checkpoint
  | Terminal_effect_settled
  | Awaiting_gate_approval
  | No_visible_reply

type completed_turn = {
  acceptance : acceptance;
  reply : string;
  turn_outcome : turn_outcome;
  turn_ref : string;
}

type response =
  | Turn_completed of completed_turn
  | Replayed_succeeded of acceptance

type operation_reconciliation =
  | Operation_pending of acceptance_state
  | Operation_succeeded of { outcome_ref : string }
  | Operation_failed of {
      failure_kind : string;
      detail : string;
      outcome_ref : string option;
    }
  | Operation_cancelled

type tool_occurrence =
  { stream_scope : int
  ; block_index : int
  ; provider_message_id : string option
  }

type stream_error =
  | Malformed_event of string
  | Request_id_mismatch of {
      expected : string;
      received : string;
    }
  | Duplicate_acceptance
  | Duplicate_reply_details
  | Duplicate_terminal
  | Event_before_acceptance of string
  | Event_identity_mismatch of {
      field : string;
      expected : string;
      received : string;
    }
  | Unknown_event_type of string
  | Unknown_custom_event of string
  | Tool_event_without_start of
      { event_type : string
      ; occurrence : tool_occurrence
      }
  | Tool_result_without_start of tool_occurrence
  | Quarantined_tool_result of
      { occurrence : tool_occurrence
      ; execution_id : string
      }
  | Conflicting_tool_result of {
      occurrence : tool_occurrence;
      recorded_execution_id : string;
      received_execution_id : string;
    }
  | Reused_tool_execution_id of {
      execution_id : string;
      recorded_occurrence : tool_occurrence;
      received_occurrence : tool_occurrence;
    }
  | Duplicate_run_start
  | Missing_run_start of string
  | Missing_acceptance
  | Stream_interrupted of { accepted : bool }
  | Missing_reply_details
  | Missing_text_end
  | Run_failed of {
      accepted : bool;
      message : string;
      code : string option;
    }
  | Replayed_failed
  | Replayed_cancelled

type protocol_error = {
  stream_error : stream_error;
  acceptance_observed : bool;
}

type error =
  | Transport_error of string
  | Http_error of {
      status : int;
      body : string;
    }
  | Protocol_error of protocol_error

type error_certainty =
  | Verified_rejected
  | Verified_failed
  | Outcome_unverified

(** How one line of the server-sent event stream reads. Exposed so the
    incremental decoder that drives the live view frames the stream exactly
    as the strict whole-body decode below does; the two differ in what they
    extract from an event, not in what counts as one. *)
type sse_line =
  | Sse_ignored
  | Sse_id of int
      (** An [id:] line whose value is an int: the journal seq of the frame
          whose [data:] follows (every frame the server projected from the
          bus carries one since #33103). An [id:] with any other value is
          [Sse_ignored]. *)
  | Sse_frame_end  (** The empty line that ends a frame. *)
  | Sse_data of string
  | Sse_noncanonical_data

val classify_sse_line : string -> sse_line

(** Canonical server CUSTOM event name inventories shared with the byte-stream
    live decoder. [current_custom_names] excludes the pre-run acceptance and
    terminal reply-details events; [known_custom_names] includes them. *)
val current_custom_names : string list
val known_custom_names : string list

(** Decode the acceptance payload for both the strict whole-stream reader
    and the incremental live reader. [expected_request_id] additionally binds
    the strict response to the request that opened it. *)
val decode_acceptance
  :  ?expected_request_id:string
  -> Yojson.Safe.t
  -> (acceptance, stream_error) result

(** Validate payload rules shared by strict and live CUSTOM-event decoders. *)
val validate_custom_value
  :  name:string
  -> Yojson.Safe.t
  -> (unit, stream_error) result

val create_request :
  ?attachments:attachment list ->
  keeper_name:string ->
  message:string ->
  unit ->
  request
val request_to_yojson : request -> Yojson.Safe.t
val request_body : request -> string
val same_request_identity : request -> request -> bool
val compact_request_id : string -> string
val terminal_safe_text : ?preserve_newlines:bool -> string -> string
val decode_response : request:request -> string -> (response, stream_error) result
val decode_response_with_provenance :
  request:request -> string -> (response, protocol_error) result
val decode_operation_reconciliation :
  request:request -> Yojson.Safe.t -> (operation_reconciliation, stream_error) result
val stream_error_to_string : stream_error -> string
val error_to_string : error -> string
val protocol_error : ?acceptance_observed:bool -> stream_error -> error
val error_acceptance_observed : error -> bool
val error_certainty : ?was_unverified:bool -> error -> error_certainty

(** Whether the failure means this process could not authenticate, rather than
    anything about the operation it asked about. Reconciliation reads use this:
    on a 401 the operation is untouched and still on the server, so the caller
    must keep the request unverified and say the token is missing, not report a
    rejection. {!error_certainty} reads the same statuses on the dispatch POST
    as a verified rejection, which is the opposite conclusion for the opposite
    question. *)
val reader_unauthenticated : error -> bool

(** The operator-facing detail for a reconciliation that failed. A refused read
    is reported as a credential problem and its remedy, and [credential_sent]
    decides which one: without a bearer the operator has none to present, with
    one the server rejected what it was given. Every other failure keeps the
    server's own words. *)
val reconciliation_failure_detail : credential_sent:bool -> error -> string
