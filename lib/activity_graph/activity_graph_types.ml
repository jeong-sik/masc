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

(** Strict parser. Returns [None] on unknown wire so callers can react
    explicitly (drop / fallback / route). See #8777 / #8605. *)
let node_status_of_string_opt = function
  | "active" -> Some Active | "offline" -> Some Offline | "spawned" -> Some Spawned
  | "retired" -> Some Retired | "compacting" -> Some Compacting | "handoff" -> Some Handoff
  | "autonomy" -> Some Autonomy | "guardrail" -> Some Guardrail
  | "todo" -> Some Todo | "claimed" -> Some Claimed | "in_progress" -> Some In_progress
  | "done" -> Some Done | "cancelled" -> Some Cancelled
  | "posted" -> Some Posted | "discussed" -> Some Discussed
  | "open" -> Some Open | "resolved" -> Some Resolved
  | "approved" -> Some Approved | "denied" -> Some Denied
  | "running" -> Some Running | "paused" -> Some Paused
  | "stopped" -> Some Stopped | "finalized" -> Some Finalized
  | "observed" -> Some Observed | "room" -> Some Coord
  | "" -> Some Unset
  | _ -> None

(** Back-compat wrapper: unknown wire still falls back to [Observed] but a
    [Log.Misc.warn] is emitted so producer/consumer drift surfaces in
    operator logs instead of silently misclassifying the node. The previous
    `_ -> Observed` arm was explicitly documented as "fail-open"; that
    posture is preserved here, just observable. See #8777. *)
let node_status_of_string s =
  match node_status_of_string_opt s with
  | Some v -> v
  | None ->
      Log.Misc.warn
        "activity_graph: unknown node_status wire %S -> Observed (drift; see #8777)" s;
      Observed

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

(** Strict parser. Returns [None] on unknown wire so callers can react
    explicitly (drop / fallback / route). Mirror of [node_status_of_string_opt]
    introduced in #8779. See #8605. *)
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

(** Back-compat wrapper: unknown wire still falls back to [Span_ended]
    (the legacy permissive default), but a [Log.Misc.warn] is emitted so
    producer/consumer drift surfaces in operator logs instead of silently
    misclassifying the span as terminal. Same template as
    [node_status_of_string] (#8779). See #8605. *)
let span_status_of_string s =
  match span_status_of_string_opt s with
  | Some v -> v
  | None ->
      Log.Misc.warn
        "activity_graph: unknown span_status wire %S -> Span_ended (drift; see #8605)" s;
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

let non_empty_string_opt = function
  | Some value ->
    let trimmed = String.trim value in
    if trimmed = "" then None else Some trimmed
  | None -> None

let json_string_non_empty_opt name json =
  Safe_ops.json_string_opt name json |> non_empty_string_opt

let json_positive_int_opt name json =
  match Safe_ops.json_int_opt name json with
  | Some value when value >= 1 -> Some value
  | _ -> None

let json_int_as_string_opt name json =
  match Safe_ops.json_int_opt name json with
  | Some value when value >= 1 -> Some (string_of_int value)
  | Some _ | None -> None

let assoc_replace name value fields =
  (name, value) :: List.filter (fun (key, _) -> key <> name) fields

let assoc_replace_string_opt name value fields =
  match non_empty_string_opt value with
  | Some value -> assoc_replace name (`String value) fields
  | None -> fields

let assoc_replace_int_opt name value fields =
  match value with
  | Some value when value >= 1 -> assoc_replace name (`Int value) fields
  | _ -> fields

let first_some left right =
  match left with
  | Some _ -> left
  | None -> right

let tag_context_pair raw =
  match String.index_opt raw ':' with
  | None -> None
  | Some 0 -> None
  | Some index ->
    let key = String.sub raw 0 index |> String.trim |> String.lowercase_ascii in
    let value =
      String.sub raw (index + 1) (String.length raw - index - 1)
      |> String.trim
    in
    if value = "" then None else Some (key, value)

let tag_file_value value =
  match String.rindex_opt value ':' with
  | Some index when index > 0 && index < String.length value - 1 ->
    let suffix =
      String.sub value (index + 1) (String.length value - index - 1)
    in
    (match int_of_string_opt suffix with
     | Some line when line >= 1 ->
       let file_path = String.sub value 0 index |> String.trim in
       if file_path = "" then (None, Some line)
       else (Some file_path, Some line)
     | _ -> (Some value, None))
  | _ -> (Some value, None)

let derive_context_from_payload payload fields =
  let file_path =
    json_string_non_empty_opt "file_path" payload
    |> fun value -> first_some value (json_string_non_empty_opt "path" payload)
    |> fun value -> first_some value (json_string_non_empty_opt "file" payload)
  in
  let line =
    json_positive_int_opt "line" payload
    |> fun value -> first_some value (json_positive_int_opt "line_start" payload)
    |> fun value -> first_some value (json_positive_int_opt "lineno" payload)
  in
  fields
  |> assoc_replace_string_opt "file_path" file_path
  |> assoc_replace_int_opt "line" line
  |> assoc_replace_string_opt "goal_id" (json_string_non_empty_opt "goal_id" payload)
  |> assoc_replace_string_opt "task_id" (json_string_non_empty_opt "task_id" payload)
  |> assoc_replace_string_opt "board_post_id"
       (json_string_non_empty_opt "board_post_id" payload
        |> fun value -> first_some value (json_string_non_empty_opt "post_id" payload))
  |> assoc_replace_string_opt "comment_id"
       (json_string_non_empty_opt "comment_id" payload
        |> fun value -> first_some value (json_string_non_empty_opt "reply_id" payload)
        |> fun value -> first_some value (json_int_as_string_opt "comment_number" payload))
  |> assoc_replace_string_opt "pr_id"
       (json_string_non_empty_opt "pr_id" payload
        |> fun value -> first_some value (json_string_non_empty_opt "pull_request" payload)
        |> fun value -> first_some value (json_int_as_string_opt "pr_number" payload))
  |> assoc_replace_string_opt "git_ref"
       (json_string_non_empty_opt "git_ref" payload
        |> fun value -> first_some value (json_string_non_empty_opt "commit" payload)
        |> fun value -> first_some value (json_string_non_empty_opt "branch" payload))
  |> assoc_replace_string_opt "log_id" (json_string_non_empty_opt "log_id" payload)

let derive_context_from_tag fields raw =
  match tag_context_pair raw with
  | None -> fields
  | Some ("file", value) ->
    let file_path, line = tag_file_value value in
    fields
    |> assoc_replace_string_opt "file_path" file_path
    |> assoc_replace_int_opt "line" line
  | Some ("line", value) ->
    (match int_of_string_opt value with
     | Some line when line >= 1 -> assoc_replace "line" (`Int line) fields
     | _ -> fields)
  | Some ("goal", value) -> assoc_replace "goal_id" (`String value) fields
  | Some ("task", value) -> assoc_replace "task_id" (`String value) fields
  | Some ("board", value) | Some ("post", value) ->
    assoc_replace "board_post_id" (`String value) fields
  | Some ("comment", value) | Some ("reply", value) ->
    assoc_replace "comment_id" (`String value) fields
  | Some ("pr", value) | Some ("pull_request", value) | Some ("review", value) ->
    assoc_replace "pr_id" (`String value) fields
  | Some ("git", value) | Some ("commit", value) | Some ("branch", value) ->
    assoc_replace "git_ref" (`String value) fields
  | Some ("log", value) | Some ("telemetry", value) ->
    assoc_replace "log_id" (`String value) fields
  | Some _ -> fields

let event_context_to_yojson (value : event) =
  let fields =
    derive_context_from_payload value.payload []
    |> fun fields -> List.fold_left derive_context_from_tag fields value.tags
  in
  `Assoc (List.rev fields)

let event_to_yojson (value : event) =
  let context = event_context_to_yojson value in
  let fields =
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
  in
  match context with
  | `Assoc [] -> `Assoc fields
  | _ -> `Assoc (fields @ [ ("context", context) ])

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
