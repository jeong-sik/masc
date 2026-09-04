(** HTTP adapter for Keeper chat operation reads and queued-only mutations. *)

type get_route =
  | Operation_list of { keeper_name : string }
  | Operation_exact of
      { keeper_name : string
      ; raw_operation_id : string
      }
  | Chat_events of { keeper_name : string }
      (** [GET /api/v1/keepers/:name/chat/events?operation_id=&since_seq=&limit=]
          (RFC-0412 §3.2, v2): one operation's journal as written, paged over
          seq, reasoning included. *)

type mutation =
  | Edit
  | Move_to_end
  | Cancel

type mutation_route =
  { keeper_name : string
  ; raw_operation_id : string
  ; mutation : mutation
  }

val get_permission : get_route -> Masc_domain.permission
(** Operation reads are [CanReadState]. [Chat_events] is [CanAdmin]: the
    journal carries reasoning in full, the same data [/raw-trace] and
    [/trajectory?include_thinking] already gate that way. *)

val mutation_permission : Masc_domain.permission

val chat_events_default_limit : int
val chat_events_max_limit : int

val chat_events_page :
  operation_id:string ->
  since_seq:int ->
  limit:int ->
  Keeper_chat_event_log.journaled_event list ->
  Yojson.Safe.t
(** Body of the v2 events response: [{schema; operation_id; events; has_more;
    next_since_seq}]. [events] are the journal lines with [seq > since_seq],
    at most [limit], encoded exactly as journaled
    ({!Keeper_chat_event_log.journaled_event_to_json}). [next_since_seq] is the
    seq of the last event returned, or [since_seq] itself when the page is
    empty, so a caller can always feed it straight back. Exposed so the wire
    contract is tested without an HTTP listener. *)

val get_route : string -> get_route option
val mutation_route : string -> mutation_route option

val handle_get
  :  Mcp_server.server_state
  -> Httpun.Request.t
  -> Httpun.Reqd.t
  -> get_route
  -> unit

val handle_mutation
  :  Mcp_server.server_state
  -> Httpun.Request.t
  -> Httpun.Reqd.t
  -> mutation_route
  -> string
  -> unit

module For_testing : sig
  val parse_mutation_body
    :  mutation
    -> string
    -> (Yojson.Safe.t option, string) result
end
