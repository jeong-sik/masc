(** IDE annotation storage — CRUD backed by [.masc-ide/annotations.jsonl].

    Uses {!Dated_jsonl} for concurrent-safe append-only writes.
    In-memory compaction rewrites the store when tombstones exceed
    [COMPACT_THRESHOLD]. *)

open Ide_annotation_types

let store_path ~base_dir = Filename.concat base_dir ".masc-ide"

let annotations_file ~base_dir =
  Filename.concat (store_path ~base_dir) "annotations.jsonl"

let ensure_store ~base_dir =
  let path = store_path ~base_dir in
  if not (Sys.file_exists path && Sys.is_directory path) then
    Unix.mkdir path 0o755

let compact_threshold = 0.2


let now_ms () =
  let ns = Mtime.to_uint64_ns (Mtime_clock.now ()) in
  Int64.div ns 1_000_000L

let annotation_kind_of_string = Ide_annotation_types.annotation_kind_of_string

let tombstone_json id keeper_id ts =
  `Assoc
    [
      ("__tombstone", `Bool true);
      ("id", `String id);
      ("keeper_id", `String keeper_id);
      ("deleted_at_ms", `Intlit (Int64.to_string ts));
    ]

let is_tombstone json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "__tombstone" fields with
      | Some (`Bool true) -> true
      | _ -> false)
  | _ -> false

let annotation_id json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "id" fields with
      | Some (`String s) -> Some s
      | _ -> None)
  | _ -> None

let load_all ~base_dir =
  let path = annotations_file ~base_dir in
  if not (Sys.file_exists path) then []
  else
    let lines = Fs_compat.load_jsonl path in
    let non_tombstones = List.filter (fun j -> not (is_tombstone j)) lines in
    List.filter_map
      (fun j ->
        match annotation_of_json j with
        | Ok a -> Some a
        | Error _ -> None)
      non_tombstones

let write_all ~base_dir annotations =
  let path = annotations_file ~base_dir in
  let jsons = List.map annotation_to_json annotations in
  let lines = List.map Yojson.Safe.to_string jsons in
  let tmp_path = path ^ ".tmp" in
  let oc = open_out_bin tmp_path in
  List.iter
    (fun line ->
      output_string oc line;
      output_char oc '\n')
    lines;
  close_out oc;
  Sys.rename tmp_path path

let create ~base_dir ~keeper_id ~file_path ~line_start ~line_end ~kind ~content
    ?goal_id ?task_id () =
  ensure_store ~base_dir;
  if file_path = "" then Error "file_path is required"
  else if line_start < 1 || line_end < line_start then
    Error "invalid line range"
  else if content = "" then Error "content is required"
  else
    let ts = now_ms () in
    let annotation =
      {
        id = Uuidm.to_string (Uuidm.v4_gen (Random.get_state ()) ());
        file_path;
        line_start;
        line_end;
        keeper_id;
        kind;
        content;
        goal_id;
        task_id;
        created_at_ms = ts;
        updated_at_ms = ts;
      }
    in
    let store = Dated_jsonl.create ~base_dir:(store_path ~base_dir) () in
    Dated_jsonl.append store (annotation_to_json annotation);
    Ok annotation

let list ~base_dir ~filter =
  ensure_store ~base_dir;
  let all : annotation list = load_all ~base_dir in
  let by_file =
    match filter.file_path with
    | Some fp -> List.filter (fun (a : annotation) -> a.file_path = fp) all
    | None -> all
  in
  let by_keeper =
    match filter.keeper_id with
    | Some k -> List.filter (fun (a : annotation) -> a.keeper_id = k) by_file
    | None -> by_file
  in
  let by_goal =
    match filter.goal_id with
    | Some g -> List.filter (fun (a : annotation) -> 
      match a.goal_id with Some gid -> gid = g | None -> false) by_keeper
    | None -> by_keeper
  in
  let by_task =
    match filter.task_id with
    | Some t -> List.filter (fun (a : annotation) ->
      match a.task_id with Some tid -> tid = t | None -> false) by_goal
    | None -> by_goal
  in
  List.sort (fun a b -> Int64.compare b.created_at_ms a.created_at_ms) by_task

let compact ~base_dir =
  let all = load_all ~base_dir in
  write_all ~base_dir all


let delete ~base_dir ~id ~keeper_id =
  ensure_store ~base_dir;
  let all = load_all ~base_dir in
  match List.find_opt (fun a -> a.id = id && a.keeper_id = keeper_id) all with
  | None -> Error "annotation not found or keeper mismatch"
  | Some _ ->
      let ts = now_ms () in
      let store = Dated_jsonl.create ~base_dir:(store_path ~base_dir) () in
      Dated_jsonl.append store (tombstone_json id keeper_id ts);
      let raw_lines = Fs_compat.load_jsonl (annotations_file ~base_dir) in
      let tombstones = List.filter is_tombstone raw_lines in
      let total = List.length all + List.length tombstones in
      if total > 0 && float_of_int (List.length tombstones) /. float_of_int total >= compact_threshold
      then compact ~base_dir;
      Ok ()
