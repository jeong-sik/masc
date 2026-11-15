(* HIGH-RISK-UNREVIEWED: see the interface. *)

module R = Login_routes
module Conversation = Server_keeper_conversation

type busy_account =
  | Runtime_account
  | Conversation_account
  | Deleted_conversation_account

type conversations_of =
  | Of_keeper
  | Of_person

type t =
  | Invalid_request of string
  | Message_too_long of { max_bytes : int }
  | Message_blank
  | Runtime_not_supported
  | Account_runtime_invalid of string
  | Turn_refused of string
  | Native_tools_refused of string
  | Deletion_refused
  | Unknown_keeper
  | Unknown_conversation of conversations_of
  | Unknown_account of string
  | Keeper_has_no_runtime
  | Account_call_running of busy_account
  | Conversation_on_other_subscription
  | Runtime_reassigned of string
  | Not_signed_in
  | No_quota
  | Silent of { after_s : float }
  | Not_started
  | Configuration_refused
  | No_answer of { in_conversation : bool }
  | Answer_unrecorded
  | Conversation_row_not_understood
  | Conversation_row_half_written
  | Conversation_record_unavailable
  | Conversation_not_deleted
  | Server_unavailable of string
  | Internal of string

let of_record_error : Conversation.error -> t = function
  | Conversation.Row_not_understood _ -> Conversation_row_not_understood
  | Conversation.Row_half_written _ -> Conversation_row_half_written
  | Conversation.Not_read _ | Conversation.Not_written _ -> Conversation_record_unavailable
  | Conversation.Id_not_drawn _ ->
    (* The id is drawn by {!Auth.generate_token}, whose hex is an id. *)
    Internal "The record of this conversation could not be given an id."
;;

let of_failure (failure : Conversation.failure) ~silent_after_s ~in_conversation =
  match failure with
  | Conversation.Not_signed_in -> Not_signed_in
  | Conversation.No_quota -> No_quota
  | Conversation.Silent -> Silent { after_s = silent_after_s }
  | Conversation.Not_started -> Not_started
  | Conversation.Configuration_refused -> Configuration_refused
  | Conversation.No_answer -> No_answer { in_conversation }
;;

(* The code of a failed turn is the kind its record keeps, so a screen reads
   the answer of a turn and a failed turn of a conversation alike. *)
let failure_code = Conversation.failure_to_string
let no_answer = "The client ended the turn without an answer."
let try_again = " Try again when it ends."

(* The status, the code and the sentence of each case. *)
let parts = function
  | Invalid_request sentence -> R.Bad_request_400, "invalid_request", sentence
  | Message_too_long { max_bytes } ->
    ( R.Bad_request_400
    , "message_too_long"
    , Printf.sprintf "The message is longer than %d bytes." max_bytes )
  | Message_blank -> R.Bad_request_400, "message_blank", "The message is blank."
  | Runtime_not_supported ->
    ( R.Bad_request_400
    , "runtime_not_supported"
    , "A Keeper turn runs here only on a Claude Code or a Codex Runtime." )
  | Account_runtime_invalid sentence -> R.Bad_request_400, "account_runtime_invalid", sentence
  | Turn_refused sentence -> R.Forbidden_403, "turn_refused", sentence
  | Native_tools_refused sentence -> R.Forbidden_403, "native_tools_refused", sentence
  | Deletion_refused ->
    ( R.Forbidden_403
    , "deletion_refused"
    , "Your account is not active, so it deletes no conversation." )
  | Unknown_keeper -> R.Not_found_404, "unknown_keeper", "No Keeper of yours has this name."
  | Unknown_conversation Of_keeper ->
    R.Not_found_404, "unknown_conversation", "No conversation of this Keeper has this id."
  | Unknown_conversation Of_person ->
    R.Not_found_404, "unknown_conversation", "No conversation of yours has this id."
  | Unknown_account sentence -> R.Not_found_404, "unknown_account", sentence
  | Keeper_has_no_runtime ->
    ( R.Conflict_409
    , "keeper_has_no_runtime"
    , "The Keeper has no Runtime. Give it one of yours first." )
  | Account_call_running Runtime_account ->
    ( R.Conflict_409
    , "account_call_running"
    , "A call of the account of this Keeper's Runtime is running." ^ try_again )
  | Account_call_running Conversation_account ->
    ( R.Conflict_409
    , "account_call_running"
    , "A call of the account of this Keeper's current conversation is running." ^ try_again )
  | Account_call_running Deleted_conversation_account ->
    ( R.Conflict_409
    , "account_call_running"
    , "A call of the account this conversation began on is running." ^ try_again )
  | Conversation_on_other_subscription ->
    ( R.Conflict_409
    , "conversation_on_other_subscription"
    , "The conversation of this Keeper began on another subscription of yours. Start a new \
       conversation." )
  | Runtime_reassigned sentence -> R.Conflict_409, "runtime_reassigned", sentence
  | Not_signed_in ->
    ( R.Conflict_409
    , failure_code Conversation.Not_signed_in
    , "The account of this Runtime is not signed in to a subscription." )
  | No_quota ->
    ( R.Too_many_requests_429
    , failure_code Conversation.No_quota
    , "The subscription of this Runtime has no quota left." )
  | Silent { after_s } ->
    ( R.Gateway_timeout_504
    , failure_code Conversation.Silent
    , Printf.sprintf "The client sent nothing for %.0f seconds." after_s )
  | Not_started ->
    R.Service_unavailable_503, failure_code Conversation.Not_started, "The client did not start."
  | Configuration_refused ->
    ( R.Internal_error_500
    , failure_code Conversation.Configuration_refused
    , "The client refused the configuration of the Runtime." )
  | No_answer { in_conversation = false } ->
    R.Bad_gateway_502, failure_code Conversation.No_answer, no_answer
  | No_answer { in_conversation = true } ->
    (* A turn of a conversation can fail on a session the vendor no longer
       has, and nothing tells that from another turn without an answer: the
       sentence names the way on, a new conversation, without naming a
       cause. *)
    ( R.Bad_gateway_502
    , failure_code Conversation.No_answer
    , no_answer ^ " When the turns of this conversation keep failing, start a new conversation." )
  | Answer_unrecorded ->
    ( R.Service_unavailable_503
    , "answer_unrecorded"
    , "The Keeper answered, and the answer could not be recorded." )
  | Conversation_row_not_understood ->
    ( R.Internal_error_500
    , "conversation_row_not_understood"
    , "The record of this conversation has a row the server does not understand." )
  | Conversation_row_half_written ->
    ( R.Service_unavailable_503
    , "conversation_row_half_written"
    , "A stopped server left the last row of the conversation record half written. A new \
       conversation of the Keeper cuts the row, and so does its next turn on a Claude Code \
       Runtime." )
  | Conversation_record_unavailable ->
    ( R.Service_unavailable_503
    , "conversation_record_unavailable"
    , "The record of this conversation could not be read or written." )
  | Conversation_not_deleted ->
    ( R.Service_unavailable_503
    , "conversation_not_deleted"
    , "The files of this conversation could not all be removed. It is listed as a deletion \
       that failed, and no turn goes on in it. Ask again to delete it." )
  | Server_unavailable sentence -> R.Service_unavailable_503, "server_unavailable", sentence
  | Internal sentence -> R.Internal_error_500, "internal_error", sentence
;;

let answer error =
  let status, code, sentence = parts error in
  R.json status [ "error", `String sentence; "code", `String code ]
;;
