(** Activity_graph_reducer — graph reducer (node_acc, edge_acc, reduce_event). *)

open Activity_graph_types

type node_acc = {
  node_id : string;
  node_kind : string;
  mutable label : string;
  mutable status : node_status;
  mutable weight : int;
  mutable semantic_weight : float;
  mutable last_event_at : string;
  mutable meta : Yojson.Safe.t;
}

type edge_acc = {
  edge_id : string;
  source : string;
  target : string;
  edge_kind : string;
  mutable weight : int;
  mutable active : bool;
  mutable last_event_at : string;
  mutable meta : Yojson.Safe.t;
}

let entity_node_id (value : entity_ref) = value.kind ^ ":" ^ value.id

let payload_string field json =
  match Yojson.Safe.Util.member field json with
  | `String value when String.trim value <> "" -> Some value
  | _ -> None

let is_generic_status = function
  | Unset | Active | Observed -> true
  | Offline | Spawned | Retired | Compacting | Handoff | Autonomy | Guardrail
  | Todo | Claimed | In_progress | Done | Cancelled
  | Posted | Discussed | Open | Resolved | Approved | Denied
  | Running | Paused | Stopped | Finalized | Coord -> false

(* Semantic weight multiplier by event kind.
   Completion events score high; routine lifecycle events score low. *)
let semantic_multiplier = function
  | "task.done" | "decision.resolved" | "operation.finalized" -> 5.0
  | "task.created" | "task.claimed" | "decision.opened" -> 3.0
  | "agent.handoff" | "agent.spawned" -> 3.0
  | "board.posted" | "board.voted" -> 2.0
  | "task.started" | "task.released" | "task.cancelled" -> 1.5
  | "message.broadcast" | "message.mentioned" -> 1.0
  | "team.turn" | "team.turn_failed" -> 1.0
  | "board.commented" | "decision.voted" -> 1.0
  | "operation.started" | "operation.resumed" -> 1.0
  | "policy.approved" | "policy.denied" -> 2.0
  | "agent.joined" | "agent.left" -> 0.5
  | "agent.retired" | "agent.compacted" -> 0.5
  | "keeper.compaction" | "keeper.guardrail" -> 0.5
  | "keeper.autonomy_started" | "keeper.autonomy_completed" -> 1.5
  | "operation.paused" | "operation.stopped" -> 0.5
  | "keeper.turn_completed" -> 0.4
  | "tool.called" -> 0.3
  | _ -> 1.0

let ensure_node (nodes : (string, node_acc) Hashtbl.t) ~(id : string)
    ~(kind : string) ~(label : string)
    ~(status : node_status) ~(ts_iso : string) ~(meta : Yojson.Safe.t)
    ~(sw_delta : float) =
  match Hashtbl.find_opt nodes id with
  | Some node ->
      node.weight <- node.weight + 1;
      node.semantic_weight <- node.semantic_weight +. sw_delta;
      node.last_event_at <- ts_iso;
      if node.label = id || node.label = "" then node.label <- label;
      if status <> Unset
         && (not (is_generic_status status) || is_generic_status node.status)
      then
        node.status <- status;
      if meta <> default_meta then node.meta <- meta
  | None ->
      Hashtbl.add nodes id
        {
          node_id = id;
          node_kind = kind;
          label;
          status;
          weight = 1;
          semantic_weight = sw_delta;
          last_event_at = ts_iso;
          meta;
        }

let ensure_entity_node (nodes : (string, node_acc) Hashtbl.t) value
    ~fallback_status ~ts_iso ~meta ~sw_delta =
  let node_id = entity_node_id value in
  let label =
    match payload_string "label" meta with
    | Some label -> label
    | None -> value.id
  in
  ensure_node nodes ~id:node_id ~kind:value.kind ~label ~status:fallback_status
    ~ts_iso ~meta ~sw_delta;
  node_id

let ensure_edge (edges : (string, edge_acc) Hashtbl.t) ~source ~target ~kind
    ~active ~ts_iso ~meta =
  let edge_id = source ^ "|" ^ kind ^ "|" ^ target in
  match Hashtbl.find_opt edges edge_id with
  | Some edge ->
      edge.weight <- edge.weight + 1;
      edge.active <- active;
      edge.last_event_at <- ts_iso;
      if meta <> default_meta then edge.meta <- meta
  | None ->
      Hashtbl.add edges edge_id
        {
          edge_id;
          source;
          target;
          edge_kind = kind;
          weight = 1;
          active;
          last_event_at = ts_iso;
          meta;
        }

let reduce_event ~nodes ~edges (value : event) =
  let sw = semantic_multiplier value.kind in
  let room_node_id = "room:" ^ value.room_id in
  ensure_node nodes ~id:room_node_id ~kind:"room" ~label:value.room_id
    ~status:Coord ~ts_iso:value.ts_iso ~meta:default_meta ~sw_delta:sw;
  let actor_id =
    match value.actor with
    | Some actor ->
        let id =
          ensure_entity_node nodes actor ~fallback_status:Active
            ~ts_iso:value.ts_iso ~meta:value.payload ~sw_delta:sw
        in
        ensure_edge edges ~source:id ~target:room_node_id ~kind:"belongs_to"
          ~active:true ~ts_iso:value.ts_iso ~meta:default_meta;
        Some id
    | None -> None
  in
  let subject_id =
    match value.subject with
    | Some subject ->
        let id =
          ensure_entity_node nodes subject ~fallback_status:Observed
            ~ts_iso:value.ts_iso ~meta:value.payload ~sw_delta:sw
        in
        ensure_edge edges ~source:id ~target:room_node_id ~kind:"belongs_to"
          ~active:true ~ts_iso:value.ts_iso ~meta:default_meta;
        Some id
    | None -> None
  in
  let set_subject_status status =
    match subject_id with
    | Some id -> (
        match Hashtbl.find_opt nodes id with
        | Some node -> node.status <- status
        | None -> ())
    | None -> ()
  in
  let set_actor_status status =
    match actor_id with
    | Some id -> (
        match Hashtbl.find_opt nodes id with
        | Some node -> node.status <- status
        | None -> ())
    | None -> ()
  in
  (match value.kind with
  | "agent.joined" -> set_subject_status Active
  | "agent.left" -> set_subject_status Offline
  | "agent.spawned" -> set_subject_status Spawned
  | "agent.retired" -> set_subject_status Retired
  | "agent.compacted" -> set_subject_status Compacting
  | "agent.handoff" ->
      set_actor_status Handoff;
      set_subject_status Active;
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"hands_off_to" ~active:true
            ~ts_iso:value.ts_iso ~meta:value.payload
      | (None, _) | (_, None) -> ())
  | "task.created" ->
      set_subject_status Todo;
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"creates" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | (None, _) | (_, None) -> ())
  | "task.claimed" ->
      set_subject_status Claimed;
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"works_on" ~active:true
            ~ts_iso:value.ts_iso ~meta:value.payload
      | (None, _) | (_, None) -> ())
  | "task.started" ->
      set_subject_status In_progress;
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"works_on" ~active:true
            ~ts_iso:value.ts_iso ~meta:value.payload
      | (None, _) | (_, None) -> ())
  | "task.released" ->
      set_subject_status Todo;
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"works_on" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | (None, _) | (_, None) -> ())
  | "task.done" ->
      set_subject_status Done;
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"works_on" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | (None, _) | (_, None) -> ())
  | "task.cancelled" ->
      set_subject_status Cancelled;
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"works_on" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | (None, _) | (_, None) -> ())
  | "message.broadcast" ->
      (match actor_id with
      | Some source ->
          ensure_edge edges ~source ~target:room_node_id ~kind:"broadcasts"
            ~active:false ~ts_iso:value.ts_iso ~meta:value.payload
      | None -> ())
  | "message.mentioned" ->
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"mentions" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | (None, _) | (_, None) -> ())
  | "board.posted" ->
      set_subject_status Posted;
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"posts" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | (None, _) | (_, None) -> ())
  | "board.commented" ->
      set_subject_status Discussed;
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"comments_on" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | (None, _) | (_, None) -> ())
  | "board.voted" ->
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"votes_on" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | (None, _) | (_, None) -> ())
  | "decision.opened" ->
      set_subject_status Open;
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"opens" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | (None, _) | (_, None) -> ())
  | "decision.voted" ->
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"votes_on" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | (None, _) | (_, None) -> ())
  | "decision.resolved" -> set_subject_status Resolved
  | "policy.approved" ->
      set_subject_status Approved;
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"governs" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | (None, _) | (_, None) -> ())
  | "policy.denied" ->
      set_subject_status Denied;
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"governs" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | (None, _) | (_, None) -> ())
  | "operation.started" ->
      set_subject_status Running;
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"operates_on" ~active:true
            ~ts_iso:value.ts_iso ~meta:value.payload
      | (None, _) | (_, None) -> ())
  | "operation.paused" -> set_subject_status Paused
  | "operation.resumed" -> set_subject_status Running
  | "operation.stopped" -> set_subject_status Stopped
  | "operation.finalized" -> set_subject_status Finalized
  | "team.turn" ->
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"participates_in"
            ~active:true ~ts_iso:value.ts_iso ~meta:value.payload
      | (None, _) | (_, None) -> ())
  | "team.turn_failed" ->
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"participates_in"
            ~active:false ~ts_iso:value.ts_iso ~meta:value.payload
      | (None, _) | (_, None) -> ())
  | "keeper.autonomy_started" -> set_actor_status Autonomy
  | "keeper.autonomy_completed" -> set_actor_status Active
  | "keeper.guardrail" -> set_actor_status Guardrail
  | "keeper.compaction" -> set_actor_status Compacting
  | "tool.called" ->
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"calls_tool" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | (None, _) | (_, None) -> ())
  | _kind -> Log.Misc.debug "reduce_event: unhandled kind=%s" _kind)
