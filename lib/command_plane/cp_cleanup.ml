(** CP Data Cleanup — Dead/stale control plane data detection and removal.

    Handles: dead units, orphaned units, terminal operations,
    orphaned detachments, and dropped intents.

    Depends only on Cp_io (no Room dependency — safe from circular deps). *)

include Cp_io

(** Build a hash set from a string list for O(1) membership checks *)
let string_set_of_list xs =
  let tbl = Hashtbl.create (List.length xs) in
  List.iter (fun x -> Hashtbl.replace tbl x ()) xs;
  tbl

let mem_set tbl key = Hashtbl.mem tbl key

type cleanup_result = {
  dead_units_removed : int;
  orphaned_units_removed : int;
  operations_archived : int;
  detachments_removed : int;
  intents_removed : int;
}

let empty_result = {
  dead_units_removed = 0;
  orphaned_units_removed = 0;
  operations_archived = 0;
  detachments_removed = 0;
  intents_removed = 0;
}

let cleanup_result_to_json (r : cleanup_result) =
  `Assoc
    [
      ("dead_units_removed", `Int r.dead_units_removed);
      ("orphaned_units_removed", `Int r.orphaned_units_removed);
      ("operations_archived", `Int r.operations_archived);
      ("detachments_removed", `Int r.detachments_removed);
      ("intents_removed", `Int r.intents_removed);
    ]

(** Compute ISO cutoff string for N days ago *)
let cutoff_iso ~days =
  let now = Time_compat.now () in
  let cutoff_time = now -. Masc_time_constants.days_to_seconds days in
  let tm = Unix.gmtime cutoff_time in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

(** Find dead units: empty roster, no leader, updated_at older than threshold *)
let find_dead_units ~days units =
  let cutoff = cutoff_iso ~days in
  List.filter
    (fun (unit : unit_record) ->
      unit.roster = []
      && unit.leader_id = None
      && unit.updated_at < cutoff)
    units

(** Find orphaned units: parent_unit_id references a non-existent unit *)
let find_orphaned_units units =
  let id_set =
    string_set_of_list (List.map (fun (u : unit_record) -> u.unit_id) units)
  in
  List.filter
    (fun (unit : unit_record) ->
      match unit.parent_unit_id with
      | None -> false
      | Some parent_id -> not (mem_set id_set parent_id))
    units

(** Check if an operation status is terminal *)
let is_terminal_status = function
  | Completed | Cancelled | Failed -> true
  | Planned | Active | Paused -> false

(** Find terminal operations older than threshold *)
let find_terminal_operations ~days operations =
  let cutoff = cutoff_iso ~days in
  List.filter
    (fun (op : operation_record) ->
      is_terminal_status op.status && op.updated_at < cutoff)
    operations

(** Find orphaned detachments: operation_id references no existing operation *)
let find_orphaned_detachments ~operation_ids detachments =
  let op_set = string_set_of_list operation_ids in
  List.filter
    (fun (det : detachment_record) ->
      not (mem_set op_set det.operation_id))
    detachments

(** Find dropped intents older than threshold *)
let find_dropped_intents ~days intents =
  let cutoff = cutoff_iso ~days in
  List.filter
    (fun (intent : intent_record) ->
      intent.state = Dropped_intent && intent.updated_at < cutoff)
    intents

(** Archive terminal operations to .masc/cp/archive/ *)
let archive_operations config (ops : operation_record list) =
  if ops = [] then ()
  else begin
    let archive_dir =
      Filename.concat (control_plane_dir config) "archive"
    in
    Room_utils.mkdir_p archive_dir;
    let archive_path =
      Filename.concat archive_dir "operations.json"
    in
    let existing =
      if Sys.file_exists archive_path then
        match Room_utils.read_json_opt config archive_path with
        | Some (`Assoc fields) -> (
            match List.assoc_opt "operations" fields with
            | Some (`List rows) -> List.filter_map operation_of_json rows
            | _ -> [])
        | Some (`List rows) -> List.filter_map operation_of_json rows
        | _ -> []
      else []
    in
    let merged = existing @ ops in
    Room_utils.write_json config archive_path
      (`Assoc
        [
          ("version", `String "cp-v2");
          ("archived_at", `String (Types.now_iso ()));
          ("operations", `List (List.map operation_to_json merged));
        ])
  end

(** Remove dead units: empty roster + no leader + stale *)
let cleanup_dead_units config ~days units =
  let dead = find_dead_units ~days units in
  if dead = [] then (units, 0)
  else begin
    let dead_set =
      string_set_of_list (List.map (fun (u : unit_record) -> u.unit_id) dead)
    in
    let kept =
      List.filter (fun (u : unit_record) -> not (mem_set dead_set u.unit_id)) units
    in
    write_units config kept;
    (kept, List.length dead)
  end

(** Remove orphaned units: parent references non-existent unit *)
let cleanup_orphaned_units config units =
  let orphaned = find_orphaned_units units in
  if orphaned = [] then (units, 0)
  else begin
    let orphan_set =
      string_set_of_list (List.map (fun (u : unit_record) -> u.unit_id) orphaned)
    in
    let kept =
      List.filter (fun (u : unit_record) -> not (mem_set orphan_set u.unit_id)) units
    in
    write_units config kept;
    (kept, List.length orphaned)
  end

(** Archive terminal operations and remove from active list *)
let archive_terminal_operations config ~days operations =
  let terminal = find_terminal_operations ~days operations in
  if terminal = [] then (operations, 0)
  else begin
    archive_operations config terminal;
    let terminal_set =
      string_set_of_list (List.map (fun (op : operation_record) -> op.operation_id) terminal)
    in
    let kept =
      List.filter (fun (op : operation_record) -> not (mem_set terminal_set op.operation_id)) operations
    in
    write_operations config kept;
    (kept, List.length terminal)
  end

(** Remove detachments whose operation_id no longer exists *)
let cleanup_orphaned_detachments config ~operation_ids detachments =
  let orphaned = find_orphaned_detachments ~operation_ids detachments in
  if orphaned = [] then (detachments, 0)
  else begin
    let orphan_set =
      string_set_of_list (List.map (fun (det : detachment_record) -> det.detachment_id) orphaned)
    in
    let kept =
      List.filter (fun (det : detachment_record) -> not (mem_set orphan_set det.detachment_id)) detachments
    in
    write_detachments config kept;
    (kept, List.length orphaned)
  end

(** Remove dropped intents older than threshold *)
let cleanup_dropped_intents config ~days intents =
  let dropped = find_dropped_intents ~days intents in
  if dropped = [] then (intents, 0)
  else begin
    let drop_set =
      string_set_of_list (List.map (fun (i : intent_record) -> i.intent_id) dropped)
    in
    let kept =
      List.filter (fun (i : intent_record) -> not (mem_set drop_set i.intent_id)) intents
    in
    write_intents config kept;
    (kept, List.length dropped)
  end

(** Run all CP cleanup steps. Returns a summary result. *)
let cleanup_cp config =
  let days = Env_config_runtime.Cp.cleanup_days in
  let units = read_units config in
  let operations = read_operations config in
  let detachments = read_detachments config in
  let intents = read_intents config in

  (* 1. Dead units *)
  let units, dead_count = cleanup_dead_units config ~days units in

  (* 2. Orphaned units (run after dead cleanup to catch cascading orphans) *)
  let _units, orphaned_count = cleanup_orphaned_units config units in

  (* 3. Terminal operations *)
  let operations, archived_count =
    archive_terminal_operations config ~days operations
  in

  (* 4. Orphaned detachments (based on remaining operation IDs) *)
  let operation_ids =
    List.map (fun (op : operation_record) -> op.operation_id) operations
  in
  let _detachments, det_count =
    cleanup_orphaned_detachments config ~operation_ids detachments
  in

  (* 5. Dropped intents *)
  let _intents, intent_count =
    cleanup_dropped_intents config ~days intents
  in

  {
    dead_units_removed = dead_count;
    orphaned_units_removed = orphaned_count;
    operations_archived = archived_count;
    detachments_removed = det_count;
    intents_removed = intent_count;
  }

let cleanup_cp_summary config =
  let result = cleanup_cp config in
  let total =
    result.dead_units_removed + result.orphaned_units_removed
    + result.operations_archived + result.detachments_removed
    + result.intents_removed
  in
  if total = 0 then
    "✅ No stale CP data"
  else
    Printf.sprintf
      "🧹 CP cleanup: %d dead unit(s), %d orphan unit(s), %d operation(s) archived, %d orphan detachment(s), %d dropped intent(s)"
      result.dead_units_removed result.orphaned_units_removed
      result.operations_archived result.detachments_removed
      result.intents_removed
