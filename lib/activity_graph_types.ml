(** Activity_graph_types — type definitions and JSON serde for activity graph. *)

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

type agent_span = {
  agent : string;
  start_ms : int;
  end_ms : int;
  span_kind : string;
  label : string;
  span_status : string;
}

let entity ~kind id = { kind; id }

let default_meta = `Assoc []

let entity_to_yojson (value : entity_ref) =
  `Assoc [ ("kind", `String value.kind); ("id", `String value.id) ]

let entity_of_yojson (json : Yojson.Safe.t) : entity_ref option =
  match Safe_ops.json_string_opt "kind" json,
        Safe_ops.json_string_opt "id" json with
  | Some kind, Some id -> Some { kind; id }
  | _ -> None

let event_to_yojson (value : event) =
  `Assoc
    [
      ("seq", `Int value.seq);
      ("ts_ms", `Int value.ts_ms);
      ("ts_iso", `String value.ts_iso);
      ("room_id", `String value.room_id);
      ("kind", `String value.kind);
      ( "actor",
        match value.actor with
        | Some actor -> entity_to_yojson actor
        | None -> `Null );
      ( "subject",
        match value.subject with
        | Some subject -> entity_to_yojson subject
        | None -> `Null );
      ("payload", value.payload);
      ("tags", `List (List.map (fun tag -> `String tag) value.tags));
    ]

let event_of_yojson (json : Yojson.Safe.t) : event option =
  match Safe_ops.json_int_opt "seq" json,
        Safe_ops.json_int_opt "ts_ms" json,
        Safe_ops.json_string_opt "ts_iso" json,
        Safe_ops.json_string_opt "room_id" json,
        Safe_ops.json_string_opt "kind" json with
  | Some seq, Some ts_ms, Some ts_iso, Some room_id, Some kind ->
    let actor = Option.bind (Safe_ops.json_member_opt "actor" json) entity_of_yojson in
    let subject = Option.bind (Safe_ops.json_member_opt "subject" json) entity_of_yojson in
    let payload = Safe_ops.json_member_opt "payload" json |> Option.value ~default:(`Assoc []) in
    let tags = Safe_ops.json_string_list "tags" json in
    Some { seq; ts_ms; ts_iso; room_id; kind; actor; subject; payload; tags }
  | _ -> None

let graph_node_to_yojson (value : graph_node) =
  `Assoc
    [
      ("id", `String value.id);
      ("kind", `String value.kind);
      ("label", `String value.label);
      ("status", `String value.status);
      ("weight", `Int value.weight);
      ("semantic_weight", `Float value.semantic_weight);
      ("last_event_at", `String value.last_event_at);
      ("meta", value.meta);
    ]

let graph_edge_to_yojson (value : graph_edge) =
  `Assoc
    [
      ("id", `String value.id);
      ("source", `String value.source);
      ("target", `String value.target);
      ("kind", `String value.kind);
      ("weight", `Int value.weight);
      ("active", `Bool value.active);
      ("last_event_at", `String value.last_event_at);
      ("meta", value.meta);
    ]

let agent_span_to_yojson (s : agent_span) =
  `Assoc [
    ("agent", `String s.agent);
    ("start_ms", `Int s.start_ms);
    ("end_ms", `Int s.end_ms);
    ("kind", `String s.span_kind);
    ("label", `String s.label);
    ("status", `String s.span_status);
  ]

let now_ts_ms () = int_of_float (Time_compat.now () *. 1000.0)
