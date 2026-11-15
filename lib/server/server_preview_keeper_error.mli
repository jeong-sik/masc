(* HIGH-RISK-UNREVIEWED: the error answers of the routes of a person's Keeper
   turn and conversation. A sentence that names a path of the server tells a
   person how the server is laid out (issue #50018). Read it against issue
   #51747. *)

(** Why a route of a person's Keeper did not do what was asked: the turn
    ({!Server_preview_keeper_turn.run}), and the start, the read and the
    deletion of a conversation ({!Server_preview_keeper_conversation}).

    The answer is a JSON [{"error": <sentence>, "code": <code>}]. The status
    and the code follow from the constructor alone, so a screen or a client
    tells the cases apart by [code] and not by the sentence. Two cases share
    a code when the person does the same next thing about them.

    A constructor that holds a [string] holds the sentence that the code which
    found the problem wrote: the parser of the request, the Keeper name
    grammar, the access check, the zone, the login of the account. It names
    no path of the server. The other constructors have their sentence here. *)

(** The account whose call runs. *)
type busy_account =
  | Runtime_account  (** The account of the Runtime the Keeper has: a turn runs on it. *)
  | Conversation_account
      (** The account the current conversation of the Keeper began on: a new
          conversation starts inside its call. *)
  | Deleted_conversation_account
      (** The account the conversation the person deletes began on: the
          deletion runs inside its call. *)

(** Where a conversation was looked for. *)
type conversations_of =
  | Of_keeper  (** Among those of the Keeper a read names. *)
  | Of_person  (** Among all those of the person: a deletion names no Keeper. *)

type t =
  | Invalid_request of string
      (** 400 [invalid_request]: the body or the query is not of the shape the
          route reads, or the Keeper name is no Keeper name. *)
  | Message_too_long of { max_bytes : int }  (** 400 [message_too_long] *)
  | Message_blank  (** 400 [message_blank] *)
  | Runtime_not_supported
      (** 400 [runtime_not_supported]: the Runtime of the Keeper is neither a
          Claude Code nor a Codex Runtime. *)
  | Account_runtime_invalid of string
      (** 400 [account_runtime_invalid]: the runtime of the account does not
          load from the configuration of the server. *)
  | Turn_refused of string
      (** 403 [turn_refused]: the authorization log refused the turn. *)
  | Native_tools_refused of string
      (** 403 [native_tools_refused]: the client would start with tools that
          reach the homes of other people (plan D3c). *)
  | Deletion_refused
      (** 403 [deletion_refused]: the authorization log refused to start the
          deletion, because the person is no longer active. *)
  | Unknown_keeper  (** 404 [unknown_keeper]: no Keeper of the person has the name. *)
  | Unknown_conversation of conversations_of
      (** 404 [unknown_conversation]: no conversation that is shown has the
          id. A conversation the person began to delete is not shown. *)
  | Unknown_account of string
      (** 404 [unknown_account]: the account of the Runtime has no login of the
          person. *)
  | Keeper_has_no_runtime  (** 409 [keeper_has_no_runtime] *)
  | Account_call_running of busy_account
      (** 409 [account_call_running]: a call of the account runs. The sentence
          asks the person to try again when it ends. *)
  | Conversation_on_other_subscription
      (** 409 [conversation_on_other_subscription]: the conversation of the
          Keeper began on another account of the person. A new conversation is
          the way on. *)
  | Runtime_reassigned of string
      (** 409 [runtime_reassigned]: the owner gave the Keeper another Runtime
          after the route read it. *)
  | Not_signed_in  (** 409 [not_signed_in]: the account is not signed in to a subscription. *)
  | No_quota  (** 429 [no_quota] *)
  | Silent of { after_s : float }  (** 504 [silent]: the client sent nothing for [after_s]. *)
  | Not_started  (** 503 [not_started]: the client did not start. *)
  | Configuration_refused  (** 500 [configuration_refused] *)
  | No_answer of { in_conversation : bool }
      (** 502 [no_answer]: the client ended the turn without an answer. In a
          conversation the sentence names a new conversation as the way on. *)
  | Answer_unrecorded
      (** 503 [answer_unrecorded]: the Keeper answered, and the record did not
          take the answer. *)
  | Conversation_row_not_understood  (** 500 [conversation_row_not_understood] *)
  | Conversation_row_half_written
      (** 503 [conversation_row_half_written]: a stopped server left the last
          row of the record half written. A new conversation of the Keeper
          cuts the row, and so does its next turn on a Claude Code Runtime. *)
  | Conversation_record_unavailable
      (** 503 [conversation_record_unavailable]: the record could not be read
          or written, and nothing the person does changes that. *)
  | Conversation_not_deleted
      (** 503 [conversation_not_deleted]: the directory of the conversation
          is still there, and the authorization log has the deletion as
          failed. A list shows it so, and a deletion of it again tries
          again. *)
  | Server_unavailable of string
      (** 503 [server_unavailable]: the server cannot decide now. Its
          authorization state cannot be trusted, or a directory or the login
          record of the account cannot be reached. *)
  | Internal of string
      (** 500 [internal_error]: a state the route does not expect. The detail
          is in the log of the server. *)

(** The case of a record of conversations that was not read or written. The
    caller logs the detail of the error, which can name a path. *)
val of_record_error : Server_keeper_conversation.error -> t

(** The case of a turn that failed. Its code is the kind the record of the
    conversation keeps ({!Server_keeper_conversation.failure_to_string}).
    [silent_after_s] is how long the client may be silent, and
    [in_conversation] is whether the turn went on in a conversation. *)
val of_failure
  :  Server_keeper_conversation.failure
  -> silent_after_s:float
  -> in_conversation:bool
  -> t

(** The JSON answer of the case. *)
val answer : t -> Login_routes.answer
