type request = {
  request_id : string;
  keeper_name : string;
  message : string;
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
  | External_effect_completed
  | External_effect_pending
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
  | Sse_data of string
  | Sse_noncanonical_data

val classify_sse_line : string -> sse_line

val create_request : keeper_name:string -> message:string -> request
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
    is reported as the missing credential and its remedy; every other failure
    keeps the server's own words. *)
val reconciliation_failure_detail : error -> string

