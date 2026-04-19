(** Activity_graph_types — type definitions and JSON serde for activity graph. *)

(** Node status: type-safe variant replacing stringly-typed status.
    Flat variant — node [kind] field already carries the category.
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

let node_status_to_string = function
  | Active -> "active" | Offline -> "offline" | Spawned -> "spawned"
  | Retired -> "retired" | Compacting -> "compacting" | Handoff -> "handoff"
  | Autonomy -> "autonomy" | Guardrail -> "guardrail"
  | Todo -> "todo" | Claimed -> "claimed" | In_progress -> "in_progress"
  | Done -> "done" | Cancelled -> "cancelled"
  | Posted -> "posted" | Discussed -> "discussed"
  | Open -> "open" | Resolved -> "resolved"
  | Approved -> "approved" | Denied -> "denied"
  | Running -> "running" | Paused -> "paused"
  | Stopped -> "stopped" | Finalized -> "finalized"
  | Observed -> "observed" | Coord -> "room" | Unset -> ""

let node_status_of_string = function
  | "active" -> Active | "offline" -> Offline | "spawned" -> Spawned
  | "retired" -> Retired | "compacting" -> Compacting | "handoff" -> Handoff
  | "autonomy" -> Autonomy | "guardrail" -> Guardrail
  | "todo" -> Todo | "claimed" -> Claimed | "in_progress" -> In_progress
  | "done" -> Done | "cancelled" -> Cancelled
  | "posted" -> Posted | "discussed" -> Discussed
  | "open" -> Open | "resolved" -> Resolved
  | "approved" -> Approved | "denied" -> Denied
  | "running" -> Running | "paused" -> Paused
  | "stopped" -> Stopped | "finalized" -> Finalized
  | "observed" -> Observed | "room" -> Coord
  | "" -> Unset
  | _ -> Observed  (* fail-open: unknown status treated as generic *)

(** Span status: separate from node_status (different lifecycle).
    @since 7182 *)
type span_status =
  | Span_open | Span_completed | Span_released | Span_cancelled
  | Span_left | Span_retired | Span_finalized | Span_stopped | Span_ended

let span_status_to_string = function
  | Span_open -> "open" | Span_completed -> "completed"
  | Span_released -> "released" | Span_cancelled -> "cancelled"
  | Span_left -> "left" | Span_retired -> "retired"
  | Span_finalized -> "finalized" | Span_stopped -> "stopped"
  | Span_ended -> "ended"

(** Issue #8682: strict parser. The previous catch-all silently
    collapsed any unknown wire string (typo, future variant) into
    [Span_ended] — a terminal-but-unspecified state — masking drift
    from any future producer. Same pattern as #8636/#8670 SSOT
    parsers: option-typed reverse route on the parse boundary. *)
let span_status_of_string_opt = function
  | "open" -> Some Span_open
  | "completed" -> Some Span_completed
  | "released" -> Some Span_released
  | "cancelled" -> Some Span_cancelled
  | "left" -> Some Span_left
  | "retired" -> Some Span_retired
  | "finalized" -> Some Span_finalized
  | "stopped" -> Some Span_stopped
  | "ended" -> Some Span_ended
  | _ -> None

(** Back-compat wrapper: callers that have no other recovery still
    fall back to [Span_ended] but a warning is logged so the typo /
    drift becomes operator-visible. *)
let span_status_of_string s =
  match span_status_of_string_opt s with
  | Some v -> v
  | None ->
      Log.Misc.warn
        "span_status_of_string: unknown wire string %S → Span_ended fallback (#8682)" s;
      Span_ended

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
      ("status", `String (node_status_to_string value.status));
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
    ("status", `String (span_status_to_string s.span_status));
  ]

let now_ts_ms () = int_of_float (Time_compat.now () *. 1000.0)
