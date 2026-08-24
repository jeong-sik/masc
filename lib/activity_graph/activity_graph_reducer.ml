(** Activity_graph_reducer — graph reducer (node_acc, edge_acc, reduce_event). *)

open Activity_graph_types

type node_acc = {
  node_id : string;
  node_kind : string;
  label : string;
  status : node_status;
  weight : int;
  last_event_at : string;
  meta : Yojson.Safe.t;
}

type edge_acc = {
  edge_id : string;
  source : string;
  target : string;
  edge_kind : string;
  weight : int;
  active : bool;
  last_event_at : string;
  meta : Yojson.Safe.t;
}

let entity_node_id (value : entity_ref) = value.kind ^ ":" ^ value.id

let payload_string field json =
  match Json_util.assoc_member_opt field json with
  | Some (`String value) when String.trim value <> "" -> Some value
  | _ -> None

let is_generic_status = function
  | Unset | Active | Observed -> true
  | Compacting
  | Todo | Claimed | In_progress | Done | Cancelled
  | Posted | Discussed | Workspace -> false

let ensure_node (nodes : (string, node_acc) Hashtbl.t) ~(id : string)
    ~(kind : string) ~(label : string)
    ~(status : node_status) ~(ts_iso : string) ~(meta : Yojson.Safe.t) =
  match Hashtbl.find_opt nodes id with
  | Some node ->
      (* The table owns the node, so an update is a rebind rather than an
         in-place write. Every field below reads [node] from before this
         event, which is what the in-place form observed too. *)
      Hashtbl.replace nodes id
        {
          node with
          weight = node.weight + 1;
          last_event_at = ts_iso;
          label =
            (if node.label = id || node.label = "" then label else node.label);
          status =
            (if
               status <> Unset
               && (not (is_generic_status status)
                  || is_generic_status node.status)
             then status
             else node.status);
          meta = (if meta <> default_meta then meta else node.meta);
        }
  | None ->
      Hashtbl.add nodes id
        {
          node_id = id;
          node_kind = kind;
          label;
          status;
          weight = 1;
          last_event_at = ts_iso;
          meta;
        }

let ensure_entity_node (nodes : (string, node_acc) Hashtbl.t) value
    ~fallback_status ~ts_iso ~meta =
  let node_id = entity_node_id value in
  let label =
    match payload_string "label" meta with
    | Some label -> label
    | None -> value.id
  in
  ensure_node nodes ~id:node_id ~kind:value.kind ~label ~status:fallback_status
    ~ts_iso ~meta;
  node_id

let ensure_edge (edges : (string, edge_acc) Hashtbl.t) ~source ~target ~kind
    ~active ~ts_iso ~meta =
  let edge_id = source ^ "|" ^ kind ^ "|" ^ target in
  match Hashtbl.find_opt edges edge_id with
  | Some edge ->
      Hashtbl.replace edges edge_id
        {
          edge with
          weight = edge.weight + 1;
          active;
          last_event_at = ts_iso;
          meta = (if meta <> default_meta then meta else edge.meta);
        }
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

(* The graph anchor a broadcast points at. It used to be minted from
   [event.workspace_id], which every writer set to the literal "default", so
   the field distinguished nothing and the belongs_to edge it produced said
   only that every node belongs to the one place. The field is gone; the
   anchor stays because "broadcast" needs a target (#29396 A14). *)
let broadcast_anchor_node_id = "workspace:default"

let reduce_event ~nodes ~edges (value : event) =
  let actor_id =
    match value.actor with
    | Some actor ->
        let id =
          ensure_entity_node nodes actor ~fallback_status:Active
            ~ts_iso:value.ts_iso ~meta:value.payload
        in
        Some id
    | None -> None
  in
  let subject_id =
    match value.subject with
    | Some subject ->
        let id =
          ensure_entity_node nodes subject ~fallback_status:Observed
            ~ts_iso:value.ts_iso ~meta:value.payload
        in
        Some id
    | None -> None
  in
  let set_subject_status status =
    match subject_id with
    | Some id -> (
        match Hashtbl.find_opt nodes id with
        | Some node -> Hashtbl.replace nodes id { node with status }
        | None -> ())
    | None -> ()
  in
  let set_actor_status status =
    match actor_id with
    | Some id -> (
        match Hashtbl.find_opt nodes id with
        | Some node -> Hashtbl.replace nodes id { node with status }
        | None -> ())
    | None -> ()
  in
  (match tool_execution_event_kind_of_string value.kind with
  | Some (External_tool_called | Keeper_in_turn_tool_executed) ->
    (match actor_id, subject_id with
     | Some source, Some target ->
       ensure_edge edges ~source ~target ~kind:"calls_tool" ~active:false
         ~ts_iso:value.ts_iso ~meta:value.payload
     | None, _ | _, None -> ())
  | None ->
  (match value.kind with
  | "agent.session_bound" -> set_subject_status Active
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
  | "task.approved" ->
      (* RFC-0323 G-3: approve-produced Done completes the task like
         task.done. The event actor is the VERIFIER; the assignee rides the
         payload (emitted since G-3), and its works_on edge is the one to
         close. Events from before G-3 lack the field — fall back to the
         actor so the subject status still flips for historical replays. *)
      set_subject_status Done;
      let completer_id =
        match payload_string "assignee" value.payload with
        | Some name ->
            Some
              (ensure_entity_node nodes
                 { kind = "agent"; id = name }
                 ~fallback_status:Active ~ts_iso:value.ts_iso
                 ~meta:value.payload)
        | None -> actor_id
      in
      (match (completer_id, subject_id) with
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
          ensure_node nodes ~id:broadcast_anchor_node_id ~kind:"workspace"
            ~label:"default" ~status:Workspace ~ts_iso:value.ts_iso
            ~meta:default_meta;
          ensure_edge edges ~source ~target:broadcast_anchor_node_id
            ~kind:"broadcasts"
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
  | "keeper.compaction" -> set_actor_status Compacting
  | _kind -> Log.Misc.debug "reduce_event: unhandled kind=%s" _kind))
