(** HTTP adapter for Keeper chat operation reads and queued-only mutations. *)

type get_route =
  | Operation_list of { keeper_name : string }
  | Operation_exact of
      { keeper_name : string
      ; raw_operation_id : string
      }
  | Chat_events of { keeper_name : string }
      (** [GET /api/v1/keepers/:name/chat/events?operation_id=&since_seq=&since_offset=&limit=]
          (RFC-0412 §3.2, v2): one operation's journal as written, paged over
          seq and byte offset, reasoning included. *)

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
  | No_journal_for_settled_operation
      (** Terminal row, no file. The server cannot tell the retention sweep
          from a fail-open append that never created the file or an
          operation older than journaling, so the message claims no cause.
          Served as 410 with the [journal_pruned] code — the client's contract
          for "nothing to reload" — never as an empty page. *)
  | Unknown_operation  (** No row: 404. *)

val classify_missing_journal : Keeper_owner.Chat_operation.state option -> missing_journal

val chat_events_page :
  operation_id:string ->
  since_seq:Keeper_chat_event_log.replay_position ->
  redact_json:(Yojson.Safe.t -> Yojson.Safe.t) ->
  Keeper_chat_event_log.page ->
  Yojson.Safe.t
(** Body of the v2 events response: [{schema; operation_id; events; has_more;
    next_since_seq; next_since_offset}] for a page
    {!Keeper_chat_event_log.page_of_rows} served. [events] are the page's
    journal lines in journal order (which is seq order: one publisher fiber
    writes them), each encoded as journaled
    ({!Keeper_chat_event_log.journaled_event_to_json}) and passed through
    [redact_json] -- the same second layer the SSE projection applies.
    [next_since_seq] is the position to feed back, in its response spelling
    ({!Keeper_chat_event_log.replay_position_to_yojson}): the seq of the last
    event returned, or [since_seq] itself when the page is empty — [null]
    when that was the whole journal. [next_since_offset] is the page's
    [next_offset]: the byte offset just past the last event returned, or the
    request's own offset when the page is empty. A client feeds both back
    together.

    On the request side [since_seq] is absent for the whole journal and a
    non-negative integer otherwise
    ({!Keeper_chat_event_log.replay_position_of_wire}); [since_offset] is
    absent to read from the first row and a non-negative integer otherwise
    ({!Keeper_chat_event_log.page_start_of_wire}); [limit] is admitted in
    [1..Keeper_chat_event_log.page_max_limit]. A negative or non-integer
    field is 400 [invalid_input]. An offset past the complete rows is 400
    [since_offset_past_rows], one that does not start a row is 400
    [since_offset_inside_row], and a first row at the offset whose seq is not
    past [since_seq] is 400 [cursor_mismatch]. Only the rows the page needs are
    decoded; a corrupt one among them is 503 [journal_corrupt]. Exposed so the
    wire contract is tested without an HTTP listener. *)

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
  val no_journal_for_settled_operation_message : operation_id:string -> string
  (** The 410 message for {!No_journal_for_settled_operation}: names the
      operation and its ended state, claims no cause. *)

  val parse_mutation_body
    :  mutation
    -> string
    -> (Yojson.Safe.t option, string) result
end
