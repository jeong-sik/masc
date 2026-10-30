(** Telegram Bot API transport for RFC-0384. No token, URL, remote body or
    remote description is included in errors. All identities remain integers;
    chat/user identities use int64 (Telegram may exceed 32 bits).
    This layer does not acknowledge updates or own a polling cursor. *)
type error =
  | Invalid_request of string
  | Invalid_response of string
  | Transport_failed
  | Http_status of int
  | Api_error of {
      status : int;
      code : int;
      retry_after : int option;
      migrate_to_chat_id : int64 option;
    }

val pp_error : Format.formatter -> error -> unit

type t
val create : token:string -> (t, error) result
(** The opaque credential is percent-encoded as one URL path segment. *)

type user = { id : int64; is_bot : bool; first_name : string; username : string option }
type message = {
  chat_id : int64;
  message_id : int;
  message_thread_id : int option;
  direct_messages_topic_id : int64 option;
  sender_chat_id : int64 option;
  from_user : user option;
  text : string option;
  caption : string option;
}
type update_kind = Message of message | Edited_message of message | Unsupported
type update = { update_id : int64; kind : update_kind }

(** Inject a completed HTTP response at the same boundary as the real client.
    The URL contains the credential and must never be logged. Errors intentionally
    have no transport string: exceptions/URLs can contain bot credentials. *)
type post = url:string -> body:string -> ((int * string), unit) result

val get_updates :
  ?post:post -> ?clock:[> float Eio.Time.clock_ty] Eio.Resource.t ->
  ?timeout_sec:float -> t -> ?offset:int64 -> poll_timeout_sec:int -> unit ->
  (update list, error) result
(** Requests message and edited_message updates. Omitted offset leaves Telegram's
    unconfirmed queue intact. Negative offsets are refused because they discard
    older updates. A caller must persist acceptance before raising the offset.
    A malformed page is refused as a whole; no entries are silently skipped.
    [poll_timeout_sec] is Telegram's long-poll duration; the default HTTP deadline
    adds the shared outbound request allowance to that duration. Like the shared
    HTTP client, that deadline is enforced only when [clock] is supplied; a
    clock-less call is unbounded. Injected [post] owns its transport lifetime. *)

val send_message :
  ?post:post -> ?clock:[> float Eio.Time.clock_ty] Eio.Resource.t ->
  ?timeout_sec:float -> t -> chat_id:int64 -> ?message_thread_id:int -> ?direct_messages_topic_id:int64 ->
  ?reply_to_message_id:int -> ?html:bool -> text:string -> unit -> (message, error) result
(** Sends text unchanged; [html=true] selects Telegram HTML parsing.
    Caller owns safe formatting and chunking after entity parsing. Topic and reply
    coordinates use the native message_thread_id and reply_parameters fields. *)

val edit_message_text :
  ?post:post -> ?clock:[> float Eio.Time.clock_ty] Eio.Resource.t ->
  ?timeout_sec:float -> t -> chat_id:int64 -> message_id:int ->
  text:string -> unit -> (message, error) result

val parse_updates_response : status:int -> body:string -> (update list, error) result
val parse_message_response : status:int -> body:string -> (message, error) result
(** Shared strict duplicate-key response boundary. Unknown Telegram fields are
    allowed, but required/known fields are never coerced or defaulted. *)

val get_me :
  ?post:post -> ?clock:[> float Eio.Time.clock_ty] Eio.Resource.t ->
  ?timeout_sec:float -> t -> unit -> (user, error) result
(** Resolve the authenticated bot identity. Polling cursor ownership must use
    this actual identity, not a token string/hash or configured chat ID. *)
