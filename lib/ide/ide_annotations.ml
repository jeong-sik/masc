(** IDE annotation storage — CRUD backed by [annotations.jsonl] in the
    selected {!Ide_paths.codebase} directory.

    The log is append-only. Explicit compaction writes begin/end snapshot
    markers; readers replay rows appended during the compaction window. *)

open Ide_annotation_types
module String_set = Set.Make (String)

let codebase_dir ~base_dir codebase =
  Ide_paths.code_store_dir ~base_dir ~codebase
;;

let annotations_file_for ~base_dir codebase =
  Filename.concat (codebase_dir ~base_dir codebase) "annotations.jsonl"
;;

let store_file ~base_dir ~codebase () =
  annotations_file_for ~base_dir codebase
;;


let deletion_key = "__tombstone"
let compact_key = "__compact"
let compact_begin_tag = "begin"
let compact_end_tag = "end"
let compact_annotations_key = "annotations"

let compact_seq_mu = Stdlib.Mutex.create ()
let compact_seq = ref 0

(* RFC-0378 §5.2: a codebase store lives at [by-url/<slug>/], two
   levels below the store root. Delegate parent creation to the
   filesystem SSOT instead of carrying a local recursive mkdir copy. *)
let ensure_dir = Fs_compat.mkdir_p

let ensure_store ~base_dir ~codebase () =
  ensure_dir (codebase_dir ~base_dir codebase)
;;

let now_ms () =
  (* NDT-OK: annotation timestamps are operator-facing metadata and the CAS
     version token; they make no deterministic decisions. This must be wall
     clock, matching Ide_bridge.now_ms — the Mtime_clock (monotonic,
     boot-relative) that sat here stamped records with 1970-era values that
     were meaningless to operators and not comparable across restarts
     (#28148). *)
  Int64.of_float (Unix.gettimeofday () *. 1000.0)
;;

let next_compaction_id () =
  let seq =
    Stdlib.Mutex.protect compact_seq_mu (fun () ->
      incr compact_seq;
      !compact_seq)
  in
  (* NDT-OK: compaction IDs are append-log marker identities; readers match the
     paired begin/end id, while annotation ordering comes from log position. *)
  Printf.sprintf "%Ld-%d-%d" (now_ms ()) (Unix.getpid ()) seq
;;

let annotation_kind_of_string = Ide_annotation_types.annotation_kind_of_string

let deletion_json id keeper_id ts =
  `Assoc
    [ deletion_key, `Bool true
    ; "id", `String id
    ; "keeper_id", `String keeper_id
    ]
;;

let compact_begin_json id =
  `Assoc [ compact_key, `String compact_begin_tag; "id", `String id ]
;;

let compact_end_json id annotations =
  `Assoc
    [ compact_key, `String compact_end_tag
    ; "id", `String id
    ; compact_annotations_key, `List (List.map annotation_to_json annotations)
    ]
;;

let string_field fields key =
  match List.assoc_opt key fields with
  | Some (`String s) -> Some s
  | _ -> None
;;

let warn_malformed_record ~path ~line_no msg =
  Log.Ide.warn
    "skip malformed annotation row %s:%d: %s"
    path
    line_no
    msg
;;

let parse_compact_annotations ~path ~line_no = function
  | `List jsons ->
    let parsed, _ =
      List.fold_left
        (fun (acc, index) json ->
           match annotation_of_json json with
           | Ok annotation -> annotation :: acc, index + 1
           | Error msg ->
             warn_malformed_record
               ~path
               ~line_no
               (Printf.sprintf
                  "compact annotation %d malformed: %s"
                  index
                  msg);
             acc, index + 1)
        ([], 0)
        jsons
    in
    Some (List.rev parsed)
  | _ ->
    warn_malformed_record
      ~path
      ~line_no
      "compact end marker has non-array annotations payload";
    None
;;

type annotation_log_record =
  | Annotation of annotation
  | Deleted of string
  | Compact_begin of string
  | Compact_end of string * annotation list
  | Ignored

let record_of_json ~path ~line_no json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt compact_key fields with
     | Some (`String tag) when String.equal tag compact_begin_tag ->
       (match string_field fields "id" with
        | Some id -> Compact_begin id
        | None ->
          warn_malformed_record ~path ~line_no "compact begin marker missing string id";
          Ignored)
     | Some (`String tag) when String.equal tag compact_end_tag ->
       (match string_field fields "id", List.assoc_opt compact_annotations_key fields with
        | Some id, Some annotations_json ->
          (match parse_compact_annotations ~path ~line_no annotations_json with
           | Some annotations -> Compact_end (id, annotations)
           | None -> Ignored)
        | _ ->
          warn_malformed_record
            ~path
            ~line_no
            "compact end marker missing id or annotations";
          Ignored)
     | Some _ ->
       warn_malformed_record ~path ~line_no "compact marker has unknown tag";
       Ignored
     | None ->
       (match List.assoc_opt deletion_key fields with
        | Some (`Bool true) ->
          (match string_field fields "id" with
           | Some id -> Deleted id
           | None ->
             warn_malformed_record ~path ~line_no "deletion marker missing string id";
             Ignored)
        | _ ->
          (match annotation_of_json json with
           | Ok annotation -> Annotation annotation
           | Error msg ->
             warn_malformed_record ~path ~line_no msg;
             Ignored)))
  | _ ->
    (match annotation_of_json json with
     | Ok annotation -> Annotation annotation
     | Error msg ->
       warn_malformed_record ~path ~line_no msg;
       Ignored)
;;

let rec apply_log_record ?(capture = true) annotations deleted_ids active = function
  | Annotation annotation as record ->
    annotations := annotation :: !annotations;
    if capture
    then (
      match !active with
      | Some (id, buffered) -> active := Some (id, record :: buffered)
      | None -> ())
  | Deleted id as record ->
    deleted_ids := String_set.add id !deleted_ids;
    if capture
    then (
      match !active with
      | Some (active_id, buffered) -> active := Some (active_id, record :: buffered)
      | None -> ())
  | Compact_begin id ->
    (match !active with
     | Some _ -> ()
     | None -> active := Some (id, []))
  | Compact_end (id, snapshot) ->
    (match !active with
     | Some (active_id, buffered) when String.equal active_id id ->
       annotations := List.rev snapshot;
       deleted_ids := String_set.empty;
       active := None;
       List.iter
         (apply_log_record ~capture:false annotations deleted_ids active)
         (List.rev buffered)
     | _ -> ())
  | Ignored -> ()
;;

let load_all_for_codebase ?stop_before_compact_begin_id ~base_dir codebase =
  let path = annotations_file_for ~base_dir codebase in
  if not (Sys.file_exists path)
  then []
  else (
    (* task-1744/task-1738: the log is append-only. Deletion records suppress
       earlier annotation rows by id, and compaction is represented by
       begin/end markers rather than an atomic-rename rewrite. Rows
       appended between a compact begin and compact end are buffered and
       replayed after the compact snapshot, so creates/deletes do not
       block on a full-file rewrite and are not lost. *)
    let annotations = ref [] in
    let deleted_ids = ref String_set.empty in
    let active_compaction = ref None in
    let stopped = ref false in
    let () =
      Fs_compat.fold_jsonl_lines
        ~init:()
        ~f:(fun () ~line_no json ->
          if !stopped
          then ()
          else (
            let record = record_of_json ~path ~line_no json in
            let should_stop =
              match stop_before_compact_begin_id with
              | Some stop_id ->
                (match record with
                 | Compact_begin id -> String.equal stop_id id
                 | Annotation _
                 | Deleted _
                 | Compact_end _
                 | Ignored -> false)
              | None -> false
            in
            if should_stop
            then
              stopped := true
            else
              apply_log_record
                annotations
                deleted_ids
                active_compaction
                record))
        path
    in
    List.rev !annotations
    |> List.filter (fun (a : annotation) -> not (String_set.mem a.id !deleted_ids)))
;;

let create
      ~base_dir
      ~codebase
      ~keeper_id
      ~file_path
      ~line_start
      ~line_end
      ~kind
      ~content
      ?goal_id
      ?task_id
      ?(references = [])
      ()
  =
  ensure_store ~base_dir ~codebase ();
  if file_path = ""
  then Error "file_path is required"
  else if line_start < 1 || line_end < line_start
  then Error "invalid line range"
  else if content = ""
  then Error "content is required"
  else
    match
      references
      |> Agent_observation.annotation_references_to_json
      |> Agent_observation.annotation_references_of_json
    with
    | Error msg -> Error msg
    | Ok references ->
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
      ; references
      ; created_at_ms = ts
      ; updated_at_ms = ts
      }
    in
    Fs_compat.append_jsonl
      (annotations_file_for ~base_dir codebase)
      (annotation_to_json annotation);
    Ok annotation
;;

(* Reads never create the store: [load_all_for_codebase] answers [] for an
   absent file, and a GET that mkdirs seeds a directory for whatever slug
   the query named (live proof 2026-08-14: a bare-token scope probe left an
   empty store directory beside the canonical one). *)
let list ~base_dir ~codebase ~filter () =
  let all : annotation list = load_all_for_codebase ~base_dir codebase in
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

let compact ~base_dir ~codebase () =
  ensure_store ~base_dir ~codebase ();
  let path = annotations_file_for ~base_dir codebase in
  File_lock_eio.with_lock path (fun () ->
    let id = next_compaction_id () in
    Fs_compat.append_jsonl path (compact_begin_json id);
    let snapshot =
      load_all_for_codebase ~stop_before_compact_begin_id:id ~base_dir codebase
    in
    Fs_compat.append_jsonl path (compact_end_json id snapshot))
;;

let delete ~base_dir ~codebase ~id ~keeper_id ?expected_version () =
  (* No ensure_store: a delete that finds its target appends a deletion record to
     a file that already exists; a miss must not seed the directory. *)
  let all = load_all_for_codebase ~base_dir codebase in
  match List.find_opt (fun a -> a.id = id && a.keeper_id = keeper_id) all with
  | None -> Error "annotation not found or keeper mismatch"
  | Some found ->
    (* task-1738: optimistic-concurrency CAS. [updated_at_ms] is the
       opaque version token (already exposed in [annotation_to_json]);
       a caller that read the annotation earlier passes it back as
       [expected_version], and a mismatch means the annotation changed
       under it, so the delete is refused. Absent [expected_version]
       preserves the pre-CAS contract (delete by id alone). *)
    (match expected_version with
     | Some v when not (Int64.equal found.updated_at_ms v) ->
       Error
         (Printf.sprintf
            "version mismatch: expected %Ld, found %Ld"
            v
            found.updated_at_ms)
     | _ ->
       let ts = now_ms () in
       Fs_compat.append_jsonl
         (annotations_file_for ~base_dir codebase)
         (deletion_json id keeper_id ts);
       Ok ())
;;
