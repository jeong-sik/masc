(** One Keeper chat operation's event journal, read a page at a time from
    [GET /api/v1/keepers/<keeper>/chat/events?operation_id=<id>]
    (Server_dashboard_http_keeper_chat_operations, [Chat_events]).

    Only the events the reply text is rebuilt from are told apart. Every other
    event type the server journals decodes to [Other]. A type the server does
    not journal fails the page, so a new event type cannot pass by unread. *)

type cursor = {
  last_seq : int;  (** The page's [next_since_seq]: the last seq read. *)
  next_offset : int;  (** The page's [next_since_offset]: where the next row starts. *)
}
(** Where the next page starts. Both halves come from one page and go back
    together, as [since_seq] and [since_offset]; the server refuses a pair
    that did not. *)

type from =
  | From_start  (** Neither cursor: the journal's first row. *)
  | After of cursor

val equal_from : from -> from -> bool

type response_owner = {
  content_generation : int;
  stream_scope : int;
}
(** The response a streamed text belongs to
    ([Keeper_chat_events.response_identity]). *)

val compare_response_owner : response_owner -> response_owner -> int
val decode_response_owner :
  owner_field:string -> Yojson.Safe.t -> (response_owner, string) result

type text_owner =
  | Observed_response of response_owner
  | Unobserved_scope of int option
      (** No observed response: the bare [stream_scope] when the producer
          sent one. *)

val decode_text_owner_fields :
  owner_field:string ->
  scope_field:string ->
  (string * Yojson.Safe.t) list ->
  (text_owner, string) result
(** Decode text ownership metadata from a JSON object's field list, naming the
    observed-response object key ([owner_field], e.g. ["response"] or
    ["textResponse"]) and bare-scope integer key ([scope_field], e.g.
    ["stream_scope"] or ["textStreamScope"]). Rejects duplicate or conflicting
    fields and invalid/negative values. *)

type event =
  | Run_started
  | Runtime_attempt_started  (** [agent_core_runtime_attempt_started] *)
  | Text_delta of { text : string; owner : text_owner }
  | Run_finished
  | Event_error
  | Other  (** Every other event type the server journals. *)

type page = {
  events : event list;  (** In journal order. *)
  next : cursor option;  (** [Some] exactly when the server reports [has_more]. *)
}

val page_limit : int
(** The most events one page asks for: the server's
    [Keeper_chat_event_log.page_max_limit]. *)

val path : keeper:string -> operation_id:string -> from:from -> string

val decode_page : operation_id:string -> Yojson.Safe.t -> (page, string) result
(** Fails when [schema] is not ["masc.keeper_chat_events.v2"], the page names
    another operation, an event type is not one the server journals, a text
    event names its owner twice or both as [response] and [stream_scope], or
    [has_more] comes with a [null] [next_since_seq]. *)
