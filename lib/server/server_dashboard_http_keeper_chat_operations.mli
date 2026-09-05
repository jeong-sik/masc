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

(** What a missing journal means for an operation the store may hold. *)
type missing_journal =
  | Nothing_journaled_yet  (** Queued or Running: an empty page is the truth. *)
  | Journal_pruned
      (** Terminal: the journal aged out of retention while the row stayed.
          Served as 410 [journal_pruned], never as an empty page. *)
  | Unknown_operation  (** No row: 404. *)

val classify_missing_journal : Keeper_owner.Chat_operation.state option -> missing_journal

val chat_events_page :
  operation_id:string ->
  since_seq:Keeper_chat_event_log.replay_position ->
  limit:int ->
  redact_json:(Yojson.Safe.t -> Yojson.Safe.t) ->
  Keeper_chat_event_log.journaled_event list ->
  Yojson.Safe.t
(** Body of the v2 events response: [{schema; operation_id; events; has_more;
    next_since_seq}]. [events] are the journal lines past [since_seq]
    ({!Keeper_chat_event_log.seq_is_after}), in journal order (which is seq
    order: one publisher fiber writes them), at most [limit], each encoded as
    journaled ({!Keeper_chat_event_log.journaled_event_to_json}) and passed
    through [redact_json] -- the same second layer the SSE projection applies.
    [limit] is positive; the HTTP layer admits [1..Keeper_chat_event_log.page_max_limit], and
    the function is not meaningful outside that. [next_since_seq] is the
    position to feed back, in its response spelling
    ({!Keeper_chat_event_log.replay_position_to_yojson}): the seq of the last
    event returned, or [since_seq] itself when the page is empty — [null]
    when that was the whole journal. On the request side [since_seq] is
    absent for the whole journal and a non-negative integer otherwise
    ({!Keeper_chat_event_log.replay_position_of_wire}); a negative integer
    is 400 [invalid_input]. Exposed so the wire contract is tested without an
    HTTP listener. *)

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
