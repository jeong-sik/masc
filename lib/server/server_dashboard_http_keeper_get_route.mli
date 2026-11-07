(** The GET sub-routes under [/api/v1/keepers/].

    A path becomes a route in one place, [of_path]. The dispatcher matches on
    the result, so a handler cannot exist without a route, and the suffix that
    selects a route is spelled once. *)

(** A route that names one keeper: [/api/v1/keepers/<name><suffix>]. *)
type keeper_route =
  | Metrics
  | Github_identity
  | Board_attention_quarantines
  | Chat_history_page
  | Chat_history
  | Checkpoints
  | File_changes
  | Paused_work
  | Runtime_trace
  | Config
  | Tool_stats
  | Tool_result
  | Tool_calls
  | Waiting_inventory
  | Feedback
  | Working_context
  | Memory_facts
  | Memory_journal
  | Operator_note
  | Next_request
  | Last_prompt
  | Provider_input_continuity
  | Provider_input_part
  | Provider_input
  | Raw_traces
  | Raw_trace
  | Turn_records
  | Turn_transcript
  | Trajectory
  | Transitions
  | Lifecycle
  | Eval
  | State_diagram
  | Composite

type t =
  | Fleet_composite  (** [/api/v1/keepers/composite]: all keepers, no name. *)
  | Keeper of keeper_route * string
      (** The route and the keeper name between the prefix and the suffix,
          trimmed. The name is not checked here and can hold [/]. *)

val all : keeper_route list
(** Every route once. *)

val suffix : keeper_route -> string
(** The path tail that selects the route, such as ["/metrics"]. *)

val of_path : string -> t option
(** [of_path path] takes the path as [Http_server_eio.Request.path] gives it:
    the request target before any [?], not percent-decoded. The name of
    [/api/v1/keepers/a%2Fb/metrics] is [a%2Fb].

    [None] when the path is outside [/api/v1/keepers/] or names no route. A
    keeper route needs at least one character before its suffix. No suffix
    ends another, so at most one route fits a path. *)
