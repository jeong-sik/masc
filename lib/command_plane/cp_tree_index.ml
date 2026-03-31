(** Cp_tree_index — O(1) lookup structures for tree-based CP views.

    Built once per snapshot_state, replaces O(n) association list lookups
    with Hashtbl.  The bottom-up aggregation computes subtree operation
    counts in a single post-order traversal, eliminating the O(n^2 x ops)
    descendant_ids + List.filter pattern. *)

include Cp_types

(* Inline from cp_unit to avoid circular dependency.
   cp_tree_index sits before cp_unit in the module chain. *)
let _active_op_status = function
  | Active | Planned -> true
  | Paused | Completed | Cancelled | Failed -> false

let _live_agent_name_matches expected live_name =
  String.equal expected live_name
  || String.starts_with ~prefix:(expected ^ "-") live_name

type tree_index = {
  child_tbl : (string, unit_record list) Hashtbl.t;
  unit_tbl : (string, unit_record) Hashtbl.t;
  status_tbl : (string, string) Hashtbl.t;
  live_set : (string, unit) Hashtbl.t;
  direct_active_ops : (string, int) Hashtbl.t;
  subtree_active_ops : (string, int) Hashtbl.t;
  live_roster_count : (string, int) Hashtbl.t;
}

let build_tree_index ~(units : unit_record list)
    ~(operations : operation_record list)
    ~(agents : Types.agent list) =
  let n = List.length units in
  let child_tbl = Hashtbl.create n in
  let unit_tbl = Hashtbl.create n in
  let status_tbl = Hashtbl.create (List.length agents) in
  let live_set = Hashtbl.create (List.length agents) in
  let direct_active_ops = Hashtbl.create n in
  let subtree_active_ops = Hashtbl.create n in
  let live_roster_count = Hashtbl.create n in
  (* 1. unit_tbl: O(n) *)
  List.iter
    (fun (unit : unit_record) -> Hashtbl.replace unit_tbl unit.unit_id unit)
    units;
  (* 2. child_tbl: O(n) — group children by parent_id *)
  List.iter
    (fun (unit : unit_record) ->
      match unit.parent_unit_id with
      | None -> ()
      | Some parent_id ->
          let existing =
            Hashtbl.find_opt child_tbl parent_id
            |> Option.value ~default:[]
          in
          Hashtbl.replace child_tbl parent_id (unit :: existing))
    units;
  (* 3. status_tbl + live_set: O(agents) *)
  List.iter
    (fun (agent : Types.agent) ->
      Hashtbl.replace status_tbl agent.name
        (Types.string_of_agent_status agent.status);
      match agent.status with
      | Active | Busy | Listening ->
          Hashtbl.replace live_set agent.name ()
      | Inactive -> ())
    agents;
  (* 4. direct_active_ops: O(ops) — count active ops per unit_id *)
  List.iter
    (fun (op : operation_record) ->
      if _active_op_status op.status then
        let prev =
          Hashtbl.find_opt direct_active_ops op.assigned_unit_id
          |> Option.value ~default:0
        in
        Hashtbl.replace direct_active_ops op.assigned_unit_id (prev + 1))
    operations;
  (* 5. live_roster_count: O(n * avg_roster) with O(1) live_set lookups *)
  List.iter
    (fun (unit : unit_record) ->
      let count =
        List.fold_left
          (fun acc roster_name ->
            if Hashtbl.mem live_set roster_name then acc + 1
            else
              (* prefix fallback: "alice" matches "alice-1" *)
              let found =
                Hashtbl.fold
                  (fun live_name () found ->
                    found || _live_agent_name_matches roster_name live_name)
                  live_set false
              in
              if found then acc + 1 else acc)
          0 unit.roster
      in
      Hashtbl.replace live_roster_count unit.unit_id count)
    units;
  {
    child_tbl;
    unit_tbl;
    status_tbl;
    live_set;
    direct_active_ops;
    subtree_active_ops;
    live_roster_count;
  }

(** Post-order traversal: subtree_active_ops[id] = direct[id] + sum(children).
    Must be called after build_tree_index. *)
let bottom_up_aggregate idx =
  let rec visit unit_id =
    let direct =
      Hashtbl.find_opt idx.direct_active_ops unit_id
      |> Option.value ~default:0
    in
    let children =
      Hashtbl.find_opt idx.child_tbl unit_id |> Option.value ~default:[]
    in
    let children_sum =
      List.fold_left
        (fun acc (child : unit_record) -> acc + visit child.unit_id)
        0 children
    in
    let total = direct + children_sum in
    Hashtbl.replace idx.subtree_active_ops unit_id total;
    total
  in
  (* Find roots: units with no parent or whose parent is not in unit_tbl *)
  Hashtbl.iter
    (fun unit_id (unit : unit_record) ->
      match unit.parent_unit_id with
      | None -> ignore (visit unit_id)
      | Some pid ->
          if not (Hashtbl.mem idx.unit_tbl pid) then ignore (visit unit_id))
    idx.unit_tbl

(** O(1) exact lookup, O(agents) prefix fallback. *)
let agent_status_for_tbl idx agent_name =
  match Hashtbl.find_opt idx.status_tbl agent_name with
  | Some status -> status
  | None ->
      Hashtbl.fold
        (fun live_name status found ->
          match found with
          | Some _ -> found
          | None ->
              if _live_agent_name_matches agent_name live_name then
                Some status
              else None)
        idx.status_tbl None
      |> Option.value ~default:"offline"
