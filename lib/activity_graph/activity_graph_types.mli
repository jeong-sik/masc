(** Activity_graph_types — type definitions and JSON serde for activity graph. *)

(** {1 Node status}

    Type-safe variant replacing stringly-typed status. The [node kind]
    field already carries the category, so this is a flat variant
    spanning agent / task / board / decision / policy / operation.

    @since 7182 *)
type node_status =
  (* Agent lifecycle *)
  | Active | Offline | Spawned | Retired | Compacting | Handoff
  | Autonomy | Guardrail
  (* Task lifecycle *)
  | Todo | Claimed | In_progress | Done | Cancelled
  (* Board *)
  | Posted | Discussed
  (* Decision *)
  | Open | Resolved
  (* Policy *)
  | Approved | Denied
  (* Operation lifecycle *)
  | Running | Paused | Stopped | Finalized
  (* Generic / fallback *)
  | Observed | Coord | Unset

val node_status_to_string : node_status -> string

(** Strict parser. Returns [None] on unknown wire so callers react
    explicitly (drop / fallback / route). See #8777 / #8605. *)
val node_status_of_string_opt : string -> node_status option

(** Back-compat wrapper: unknown wire falls back to [Observed] but a
    [Log.Misc.warn] is emitted so producer/consumer drift surfaces in
    operator logs. See #8777. *)
val node_status_of_string : string -> node_status

(** {1 Span status}

    Separate lifecycle from {!node_status}.

    @since 7182 *)
type span_status =
  | Span_open | Span_completed | Span_released | Span_cancelled
  | Span_left | Span_retired | Span_finalized | Span_stopped | Span_ended

val span_status_to_string : span_status -> string

(** Lenient parser: unknown wire collapses to [Span_ended]. *)
val span_status_of_string : string -> span_status

(** {1 Graph entities} *)

type entity_ref = {
  kind : string;
  id : string;
}

type event = {
  seq : int;
  ts_ms : int;
  ts_iso : string;
  room_id : string;
  kind : string;
  actor : entity_ref option;
  subject : entity_ref option;
  payload : Yojson.Safe.t;
  tags : string list;
}

type graph_node = {
  id : string;
  kind : string;
  label : string;
  status : node_status;
  weight : int;
  semantic_weight : float;
  last_event_at : string;
  meta : Yojson.Safe.t;
}

type graph_edge = {
  id : string;
  source : string;
  target : string;
  kind : string;
  weight : int;
  active : bool;
  last_event_at : string;
  meta : Yojson.Safe.t;
}

type agent_span = {
  agent : string;
  start_ms : int;
  end_ms : int;
  span_kind : string;
  label : string;
  span_status : span_status;
}

(** {1 Constructors and defaults} *)

val entity : kind:string -> string -> entity_ref

(** [`Assoc []] — a JSON object with no members. *)
val default_meta : Yojson.Safe.t

(** {1 JSON serde}

    [_to_yojson] always succeeds; [_of_yojson] returns [None] on any
    missing required field. *)

val entity_to_yojson : entity_ref -> Yojson.Safe.t

val entity_of_yojson : Yojson.Safe.t -> entity_ref option

val event_to_yojson : event -> Yojson.Safe.t

val event_of_yojson : Yojson.Safe.t -> event option

val graph_node_to_yojson : graph_node -> Yojson.Safe.t

val graph_edge_to_yojson : graph_edge -> Yojson.Safe.t

val agent_span_to_yojson : agent_span -> Yojson.Safe.t

(** {1 Utilities} *)

(** Current wall-clock time in milliseconds (via [Time_compat.now]). *)
val now_ts_ms : unit -> int
