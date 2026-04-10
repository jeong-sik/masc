(** Activity Graph — event sourcing and graph projection for MASC rooms.

    Events are appended to daily JSONL files under [activity-events/].
    A reducer builds a graph (nodes + edges) from the event stream.
    SSE clients can subscribe to live event pushes. *)

(** {1 Types} *)

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
  status : string;
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

type client = {
  client_id : int;
  push : string -> unit;
  room_filter : string option;
  kind_filters : string list;
  mutable last_seq : int;
  created_at : float;
}

(** {1 Entity constructors} *)

val entity : kind:string -> string -> entity_ref

(** {1 Serialization} *)

val entity_to_yojson : entity_ref -> Yojson.Safe.t
val entity_of_yojson : Yojson.Safe.t -> entity_ref option
val event_to_yojson : event -> Yojson.Safe.t
val event_of_yojson : Yojson.Safe.t -> event option
val graph_node_to_yojson : graph_node -> Yojson.Safe.t
val graph_edge_to_yojson : graph_edge -> Yojson.Safe.t

(** {1 SSE client registry} *)

val register :
  string ->
  push:(string -> unit) ->
  last_seq:int ->
  ?room_filter:string ->
  ?kind_filters:string list ->
  unit ->
  int

val unregister : string -> unit
val unregister_if_current : string -> int -> unit
val client_count : unit -> int

(** {1 Event stream} *)

val format_sse_event : event -> string

val emit :
  Room_utils.config ->
  ?actor:entity_ref ->
  ?subject:entity_ref ->
  ?tags:string list ->
  kind:string ->
  payload:Yojson.Safe.t ->
  unit ->
  event

val list_events :
  Room_utils.config ->
  ?kinds:string list ->
  after_seq:int ->
  limit:int ->
  unit ->
  event list

val latest_seq : Room_utils.config -> int

(** {1 JSON responses} *)

val json_response :
  Room_utils.config ->
  ?kinds:string list ->
  after_seq:int ->
  limit:int ->
  unit ->
  Yojson.Safe.t

val graph_json :
  Room_utils.config ->
  ?kinds:string list ->
  ?limit:int ->
  ?timeline_limit:int ->
  ?since_ms:int ->
  unit ->
  Yojson.Safe.t

(** {1 Agent spans (swimlane data)} *)

type agent_span = {
  agent : string;
  start_ms : int;
  end_ms : int;
  span_kind : string;
  label : string;
  span_status : string;
}

val agent_span_to_yojson : agent_span -> Yojson.Safe.t

val agent_spans_json :
  Room_utils.config ->
  ?limit:int ->
  ?since_ms:int ->
  unit ->
  Yojson.Safe.t
