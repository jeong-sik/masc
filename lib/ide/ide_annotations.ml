(** IDE annotation storage — CRUD backed by [annotations.jsonl] in the
    selected {!Ide_paths.partition} directory.

    In-memory compaction rewrites the store when tombstones exceed
    [COMPACT_THRESHOLD]. *)

open Ide_annotation_types
module String_set = Set.Make (String)

let store_path ~base_dir = Ide_paths.store_path ~base_dir

let partition_dir ~base_dir partition =
  Ide_paths.partition_store_dir ~base_dir partition
;;

let annotations_file_for ~base_dir partition =
  Filename.concat (partition_dir ~base_dir partition) "annotations.jsonl"
;;

let annotations_file ~base_dir =
  annotations_file_for ~base_dir Ide_paths.Orphan
;;

(* RFC-0128 §4.2: [_orphan/] and [by-url/<slug>/] live one or two
   levels deeper than the flat store. Recursive mkdir avoids
   ENOENT when the parent chain has never been created. *)
let rec ensure_dir path =
  if path = "" || path = "/" || (Sys.file_exists path && Sys.is_directory path)
  then ()
  else (
    ensure_dir (Filename.dirname path);
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

let ensure_store ~base_dir ?(partition = Ide_paths.Orphan) () =
  ensure_dir (partition_dir ~base_dir partition)
;;

let compact_threshold = 0.2

let now_ms () =
  let ns = Mtime.to_uint64_ns (Mtime_clock.now ()) in
  Int64.div ns 1_000_000L
;;

let annotation_kind_of_string = Ide_annotation_types.annotation_kind_of_string

let tombstone_json id keeper_id ts =
  `Assoc
    [ "__tombstone", `Bool true
    ; "id", `String id
    ; "keeper_id", `String keeper_id
    ; "deleted_at_ms", `Intlit (Int64.to_string ts)
    ]
;;

let is_tombstone json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "__tombstone" fields with
     | Some (`Bool true) -> true
     | _ -> false)
  | _ -> false
;;

let annotation_id json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "id" fields with
     | Some (`String s) -> Some s
     | _ -> None)
  | _ -> None
;;

let load_all_partition ~base_dir partition =
  let path = annotations_file_for ~base_dir partition in
  if not (Sys.file_exists path)
  then []
  else (
    (* task-1744: a tombstone must suppress the earlier annotation line
       that shares its id. That decision cannot be made mid-fold, since
       the tombstone may appear after its target in the append-only log,
       so one pass collects both the live annotations and the set of
       tombstoned ids and the suppression is applied afterwards. This
       makes [list]/[compact] honour the "tombstoned entries are
       excluded" contract instead of only dropping the marker lines. The
       annotations file is small (live store on the order of KB), so a
       single O(n) read plus an O(n log n) filter is adequate; no
       tail-read optimisation is needed here. *)
    let annotations, tombstoned =
      Fs_compat.fold_jsonl_lines
        ~init:([], String_set.empty)
        ~f:(fun (acc, tombstoned) ~line_no:_ j ->
          if is_tombstone j
          then (
            match annotation_id j with
            | Some id -> acc, String_set.add id tombstoned
            | None -> acc, tombstoned)
          else (
            match annotation_of_json j with
            | Ok a -> a :: acc, tombstoned
            | Error _ -> acc, tombstoned))
        path
    in
    List.rev annotations
    |> List.filter (fun (a : annotation) -> not (String_set.mem a.id tombstoned)))
;;

let write_all_partition ~base_dir partition annotations =
  let path = annotations_file_for ~base_dir partition in
  let jsons = List.map annotation_to_json annotations in
  let lines = List.map Yojson.Safe.to_string jsons in
  let content = String.concat "" (List.map (fun line -> line ^ "\n") lines) in
  match Fs_compat.save_file_atomic path content with
  | Ok () -> ()
  | Error msg -> raise (Sys_error msg)
;;

let create
      ~base_dir
      ?(partition = Ide_paths.Orphan)
      ~keeper_id
      ~file_path
      ~line_start
      ~line_end
      ~kind
      ~content
      ?goal_id
      ?task_id
      ?board_post_id
      ?comment_id
      ?pr_id
      ?git_ref
      ?log_id
      ?session_id
      ?operation_id
      ?worker_run_id
      ()
  =
  ensure_store ~base_dir ~partition ();
  if file_path = ""
  then Error "file_path is required"
  else if line_start < 1 || line_end < line_start
  then Error "invalid line range"
  else if content = ""
  then Error "content is required"
  else (
    let ts = now_ms () in
    (* RFC-0128 PR-2: UUID minting is the non-determinism boundary.
       Previous code captured a copy of the global RNG state without
       advancing it, so consecutive uuid generations collided. Each
       call now self-initialises a fresh state. Downstream consumers
       treat the id as an opaque string identifier and never branch on
       its value, so the non-determinism is contained at this site. *)
    let annotation =
      (* NDT-OK: see comment block above — uuid minting boundary. *)
      { id = Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ())
      ; file_path
      ; line_start
      ; line_end
      ; keeper_id
      ; kind
      ; content
      ; goal_id
      ; task_id
      ; board_post_id
      ; comment_id
      ; pr_id
      ; git_ref
      ; log_id
      ; session_id
      ; operation_id
      ; worker_run_id
      ; created_at_ms = ts
      ; updated_at_ms = ts
      }
    in
    Fs_compat.append_jsonl
      (annotations_file_for ~base_dir partition)
      (annotation_to_json annotation);
    Ok annotation)
;;

let list ~base_dir ?(partition = Ide_paths.Orphan) ~filter () =
  ensure_store ~base_dir ~partition ();
  let all : annotation list = load_all_partition ~base_dir partition in
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
    | Some g ->
      List.filter
        (fun (a : annotation) ->
           match a.goal_id with
           | Some gid -> gid = g
           | None -> false)
        by_keeper
    | None -> by_keeper
  in
  let by_task =
    match filter.task_id with
    | Some t ->
      List.filter
        (fun (a : annotation) ->
           match a.task_id with
           | Some tid -> tid = t
           | None -> false)
        by_goal
    | None -> by_goal
  in
  List.sort (fun a b -> Int64.compare b.created_at_ms a.created_at_ms) by_task
;;

let compact ~base_dir ?(partition = Ide_paths.Orphan) () =
  let all = load_all_partition ~base_dir partition in
  write_all_partition ~base_dir partition all
;;

let delete ~base_dir ?(partition = Ide_paths.Orphan) ~id ~keeper_id () =
  ensure_store ~base_dir ~partition ();
  let all = load_all_partition ~base_dir partition in
  match List.find_opt (fun a -> a.id = id && a.keeper_id = keeper_id) all with
  | None -> Error "annotation not found or keeper mismatch"
  | Some _ ->
    let ts = now_ms () in
    Fs_compat.append_jsonl
      (annotations_file_for ~base_dir partition)
      (tombstone_json id keeper_id ts);
    let tombstone_count =
      Fs_compat.fold_jsonl_lines
        ~init:0
        ~f:(fun acc ~line_no:_ j -> if is_tombstone j then acc + 1 else acc)
        (annotations_file_for ~base_dir partition)
    in
    let total = List.length all + tombstone_count in
    if
      total > 0
      && float_of_int tombstone_count /. float_of_int total >= compact_threshold
    then compact ~base_dir ~partition ();
    Ok ()
;;
