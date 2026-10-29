open Result.Syntax

module Objects = Agent_core.Checkpoint_objects
module Checkpoint = Keeper_checkpoint_store
module Object_store = Keeper_checkpoint_object_store
module String_map = Map.Make (String)
module String_set = Set.Make (String)

type report =
  { sessions : int
  ; roots : int
  ; kept : int
  ; removed : int
  ; removed_bytes : int
  ; failures : string list
  }

type error =
  | Owner_stores_unreadable of Keeper_retained_checkpoint_sweep.error
  | Listing_failed of
      { path : string
      ; detail : string
      }
  | Root_unreadable of
      { path : string
      ; detail : string
      }
  | Root_unusable of
      { root : string
      ; detail : string
      }
  | Segment_unreachable of
      { root : string
      ; segment : string
      ; detail : string
      }

let error_to_string = function
  | Owner_stores_unreadable error ->
    "keeper operation stores could not be read, so the Gate preparation heads are unknown: "
    ^ Keeper_retained_checkpoint_sweep.error_to_string error
  | Listing_failed { path; detail } -> Printf.sprintf "%s could not be listed: %s" path detail
  | Root_unreadable { path; detail } -> Printf.sprintf "root head %s could not be read: %s" path detail
  | Root_unusable { root; detail } ->
    Printf.sprintf "root head %s is not one this binary reads: %s" root detail
  | Segment_unreachable { root; segment; detail } ->
    Printf.sprintf "segment %s behind root head %s could not be followed: %s" segment root detail
;;

(* A root head and where it was found, for the error that names it. *)
type root =
  { where : string
  ; bytes : string
  }

type root_head =
  | Current of Objects.head
  | Earlier_version
  | Unusable of string

let root_head bytes =
  match Objects.head_of_string bytes with
  | Ok head -> Current head
  | Error (Objects.Checkpoint_invalid error) ->
    (match Checkpoint.classify_core_error error with
     | Checkpoint.Superseded_version _ -> Earlier_version
     | ( Checkpoint.Not_found | Store_error _ | Parse_error _ | Newer_version _ | Io_error _
       | Read_failed _ | Agent_core_error _ | Objects_invalid _ ) as other ->
       Unusable (Checkpoint.checkpoint_load_error_to_string other))
  | Error
      (( Objects.Head_invalid _ | Object_missing _ | Object_unreadable _
       | Object_digest_mismatch _ | Bundle_invalid _ | Turn_mismatch _ | Message_invalid _
       | Segment_invalid _ | Header_object_invalid _ ) as error) ->
    Unusable (Objects.load_error_to_string error)
;;

let kind path =
  match Unix.lstat path with
  | { Unix.st_kind; st_size; _ } -> Ok (Some (st_kind, st_size))
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | exception Unix.Unix_error (code, _, _) -> Error (Unix.error_message code)
;;

(* The sorted entries of a directory; [None] when [path] is absent or is not a
   directory (a symlink to one included). *)
let directory_entries path =
  match kind path with
  | Error detail -> Error (Listing_failed { path; detail })
  | Ok None -> Ok None
  | Ok (Some (Unix.S_DIR, _)) ->
    (match Sys.readdir path with
     | names ->
       Array.sort String.compare names;
       Ok (Some (Array.to_list names))
     | exception Sys_error detail -> Error (Listing_failed { path; detail }))
  | Ok (Some ((Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK), _)) ->
    Ok None
;;

(* The entries of [path] that are directories themselves, not links to one.
   Other entries, such as the [<session>.checkpoint.lock] files beside the
   session directories, are no part of the sweep. *)
let subdirectories path =
  let* entries = directory_entries path in
  List.fold_left
    (fun acc name ->
       let* found = acc in
       let entry = Filename.concat path name in
       match kind entry with
       | Error detail -> Error (Listing_failed { path = entry; detail })
       | Ok (Some (Unix.S_DIR, _)) -> Ok (name :: found)
       | Ok None
       | Ok (Some ((Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK), _)) ->
         Ok found)
    (Ok [])
    (Option.value ~default:[] entries)
  |> Result.map List.rev
;;

(* The session root as the store resolves it: a configured root may be a link
   to the physical directory. *)
let resolved path =
  match Unix.realpath path with
  | resolved -> Ok (Some resolved)
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | exception Unix.Unix_error (code, _, _) -> Error (Listing_failed { path; detail = Unix.error_message code })
;;

let read_root ~ownership_root path =
  match Fs_compat.load_owned_regular_file ~ownership_root path with
  | Ok None -> Ok None
  | Ok (Some bytes) -> Ok (Some { where = path; bytes })
  | Error error ->
    Error (Root_unreadable { path; detail = Fs_compat.owned_regular_file_read_error_to_string error })
;;

let rec collect_roots read = function
  | [] -> Ok []
  | path :: paths ->
    let* found = read path in
    let* rest = collect_roots read paths in
    Ok (Option.to_list found @ rest)
;;

(* The copied heads under [journal_inputs_dir], by the session their header
   names. A head of an earlier version is not a root, so its session does
   not matter. *)
let journal_input_roots ~journal_inputs_dir ~journal_input_head =
  let* inputs = subdirectories journal_inputs_dir in
  let paths =
    List.map (fun id -> Filename.concat (Filename.concat journal_inputs_dir id) journal_input_head) inputs
  in
  let* roots = collect_roots (read_root ~ownership_root:journal_inputs_dir) paths in
  List.fold_left
    (fun acc root ->
       let* by_session = acc in
       match root_head root.bytes with
       | Earlier_version -> Ok by_session
       | Unusable detail -> Error (Root_unusable { root = root.where; detail })
       | Current head ->
         let session = head.header.session_id in
         let others = Option.value ~default:[] (String_map.find_opt session by_session) in
         Ok (String_map.add session (root :: others) by_session))
    (Ok String_map.empty)
    roots
;;

let gate_roots (records : Keeper_retained_checkpoint_sweep.owner_records) =
  List.concat_map Keeper_semantic_execution.gate_preparation_heads records.semantic_executions
  |> List.fold_left
       (fun by_session ((reference : Keeper_checkpoint_ref.t), bytes) ->
          let session = Keeper_id.Trace_id.to_string reference.trace_id in
          let where =
            Printf.sprintf "Gate preparation trace=%s turn=%d sha256=%s" session
              reference.turn_count reference.sha256
          in
          let others = Option.value ~default:[] (String_map.find_opt session by_session) in
          String_map.add session ({ where; bytes } :: others) by_session)
       String_map.empty
;;

let session_roots ~session_root ~session_dir ~session_id =
  let canonical = Checkpoint.agent_core_checkpoint_path ~session_dir ~session_id in
  let* archives =
    match Checkpoint.list_agent_core_history_files ~session_dir with
    | names -> Ok (List.map (Filename.concat session_dir) names)
    | exception Sys_error detail -> Error (Listing_failed { path = session_dir; detail })
  in
  let retained_dir = Filename.concat session_dir Checkpoint.retained_dirname in
  let* retained = directory_entries retained_dir in
  let retained =
    Option.value ~default:[] retained
    |> List.filter (String.ends_with ~suffix:".json")
    |> List.map (Filename.concat retained_dir)
  in
  collect_roots (read_root ~ownership_root:session_root) ((canonical :: archives) @ retained)
;;

(* What the roots reach in one session, and how many of them are current. *)
let reached ~session_dir roots =
  List.fold_left
    (fun acc root ->
       let* current, live = acc in
       match root_head root.bytes with
       | Earlier_version -> Ok (current, live)
       | Unusable detail -> Error (Root_unusable { root = root.where; detail })
       | Current head ->
         (match Object_store.walk_segments ~session_dir head with
          | Object_store.Segment_unreachable { digest; detail } ->
            Error (Segment_unreachable { root = root.where; segment = (digest :> string); detail })
          | Object_store.Segments_reached behind ->
            let add live (digest : Objects.digest) = String_set.add (digest :> string) live in
            let live = List.fold_left add live (Objects.head_objects head) in
            Ok (current + 1, List.fold_left add live behind)))
    (Ok (0, String_set.empty))
    roots
;;

type session_plan =
  { objects_dir : string
  ; live : String_set.t
  }

let plan_sessions ~session_root ~external_roots =
  let* sessions = subdirectories session_root in
  List.fold_left
    (fun acc session_id ->
       let* roots_seen, plans = acc in
       let session_dir = Filename.concat session_root session_id in
       let objects_dir = Filename.concat session_dir Object_store.dirname in
       let* objects = kind objects_dir |> Result.map_error (fun detail ->
         Listing_failed { path = objects_dir; detail }) in
       match objects with
       | None
       | Some ((Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK), _) ->
         Ok (roots_seen, plans)
       | Some (Unix.S_DIR, _) ->
         let* own = session_roots ~session_root ~session_dir ~session_id in
         let others = Option.value ~default:[] (String_map.find_opt session_id external_roots) in
         let* current, live = reached ~session_dir (own @ others) in
         Ok (roots_seen + current, { objects_dir; live } :: plans))
    (Ok (0, []))
    sessions
;;

let failed report detail = { report with failures = detail :: report.failures }

let remove_object ~live ~prefix_dir report name =
  match Objects.digest_of_hex name with
  | Error _ -> report
  | Ok _ when not (String.equal (String.sub name 0 2) (Filename.basename prefix_dir)) -> report
  | Ok _ when String_set.mem name live -> { report with kept = report.kept + 1 }
  | Ok _ ->
    let path = Filename.concat prefix_dir name in
    (match kind path with
     | Error detail -> failed report (path ^ ": " ^ detail)
     | Ok (Some (Unix.S_REG, size)) ->
       (match Sys.remove path with
        | () -> { report with removed = report.removed + 1; removed_bytes = report.removed_bytes + size }
        | exception Sys_error detail -> failed report detail)
     | Ok (Some ((Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK), _))
     | Ok None -> report)
;;

let remove_unreached report { objects_dir; live } =
  match directory_entries objects_dir with
  | Error error -> failed report (error_to_string error)
  | Ok None -> report
  | Ok (Some prefixes) ->
    List.fold_left
      (fun report prefix ->
         let prefix_dir = Filename.concat objects_dir prefix in
         match directory_entries prefix_dir with
         | Error error -> failed report (error_to_string error)
         | Ok None -> report
         | Ok (Some names) -> List.fold_left (remove_object ~live ~prefix_dir) report names)
      report
      prefixes
;;

let run ~runtime_root ~journal_inputs_dir ~journal_input_head =
  let* records =
    Keeper_retained_checkpoint_sweep.owner_records ~runtime_root
    |> Result.map_error (fun error -> Owner_stores_unreadable error)
  in
  let* journal = journal_input_roots ~journal_inputs_dir ~journal_input_head in
  let external_roots =
    String_map.union (fun _ gate journal -> Some (gate @ journal)) (gate_roots records) journal
  in
  let* session_root = resolved (Keeper_fs.session_store_path_for_runtime_root runtime_root) in
  let* roots, plans =
    match session_root with
    | None -> Ok (0, [])
    | Some session_root -> plan_sessions ~session_root ~external_roots
  in
  let empty =
    { sessions = List.length plans; roots; kept = 0; removed = 0; removed_bytes = 0; failures = [] }
  in
  let report = List.fold_left remove_unreached empty (List.rev plans) in
  Ok { report with failures = List.rev report.failures }
;;
