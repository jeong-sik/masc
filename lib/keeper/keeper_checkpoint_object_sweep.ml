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
  | Unread_lines_unreadable of Keeper_unread_turn_bundles.error

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
  | Unread_lines_unreadable error ->
    "the bundles unread turn-log lines point at are unknown: "
    ^ Keeper_unread_turn_bundles.error_to_string error
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
  | { Unix.st_kind; st_size; st_mtime; _ } -> Ok (Some (st_kind, st_size, st_mtime))
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | exception Unix.Unix_error (code, _, _) -> Error (Unix.error_message code)
;;

(* The sorted entries of a directory; [None] when [path] is absent or is not a
   directory (a symlink to one included). *)
let directory_entries path =
  match kind path with
  | Error detail -> Error (Listing_failed { path; detail })
  | Ok None -> Ok None
  | Ok (Some (Unix.S_DIR, _, _)) ->
    (match Sys.readdir path with
     | names ->
       Array.sort String.compare names;
       Ok (Some (Array.to_list names))
     | exception Sys_error detail -> Error (Listing_failed { path; detail }))
  | Ok (Some ((Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK), _, _)) ->
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
       | Ok (Some (Unix.S_DIR, _, _)) -> Ok (name :: found)
       | Ok None
       | Ok (Some ((Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK), _, _)) ->
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

(* A session's own roots are files, read one at a time so a session's old
   checkpoints are not all held at once; the others arrive as bytes. *)
type root_source =
  | Root_file of string
  | Root_bytes of root

(* The files that may hold a session's own root heads. An
   [accepted-checkpoints] entry that is there but is not a directory stops the
   pass: what it holds cannot be told. *)
let session_root_files ~session_dir ~session_id =
  let canonical = Checkpoint.agent_core_checkpoint_path ~session_dir ~session_id in
  let* archives =
    match Checkpoint.list_agent_core_history_files ~session_dir with
    | names -> Ok (List.map (Filename.concat session_dir) names)
    | exception Sys_error detail -> Error (Listing_failed { path = session_dir; detail })
  in
  let retained_dir = Filename.concat session_dir Checkpoint.retained_dirname in
  let* retained =
    match kind retained_dir with
    | Error detail -> Error (Listing_failed { path = retained_dir; detail })
    | Ok None -> Ok []
    | Ok (Some (Unix.S_DIR, _, _)) ->
      let* entries = directory_entries retained_dir in
      Ok (Option.value ~default:[] entries)
    | Ok (Some ((Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK), _, _)) ->
      Error (Listing_failed { path = retained_dir; detail = "not a directory" })
  in
  let retained =
    retained
    |> List.filter (String.ends_with ~suffix:".json")
    |> List.map (fun name -> Root_file (Filename.concat retained_dir name))
  in
  Ok ((Root_file canonical :: List.map (fun path -> Root_file path) archives) @ retained)
;;

(* What the roots reach in one session, and how many of them are current. *)
let reached ~session_root ~session_dir sources =
  List.fold_left
    (fun acc source ->
       let* current, live = acc in
       let* root =
         match source with
         | Root_bytes root -> Ok (Some root)
         | Root_file path -> read_root ~ownership_root:session_root path
       in
       match root with
       | None -> Ok (current, live)
       | Some root ->
         (match root_head root.bytes with
          | Earlier_version -> Ok (current, live)
          | Unusable detail -> Error (Root_unusable { root = root.where; detail })
          | Current head ->
            (match Object_store.walk_segments ~session_dir head with
             | Object_store.Segment_unreachable { digest; detail } ->
               Error (Segment_unreachable { root = root.where; segment = (digest :> string); detail })
             | Object_store.Segments_reached behind ->
               let add live (digest : Objects.digest) = String_set.add (digest :> string) live in
               let live = List.fold_left add live (Objects.head_objects head) in
               Ok (current + 1, List.fold_left add live behind))))
    (Ok (0, String_set.empty))
    sources
;;

type path_stamp =
  (Unix.file_kind * int * int * int * float * float) option

let path_stamp path : (path_stamp, string) result =
  match Unix.lstat path with
  | st ->
    Ok (Some (st.Unix.st_kind, st.Unix.st_dev, st.Unix.st_ino, st.Unix.st_size, st.Unix.st_mtime, st.Unix.st_ctime))
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | exception Unix.Unix_error (code, fn, arg) ->
    Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))
;;

type session_plan =
  { session_id : string
  ; session_dir : string
  ; objects_dir : string
  ; canonical_stamp : path_stamp
  ; retained_stamp : path_stamp
  ; external_roots : root list
  ; live : String_set.t
  }

(* The bundles unread turn-log lines point at, by session. *)
let unread_by_session (unread : Keeper_unread_turn_bundles.root list) =
  List.fold_left
    (fun by_session ({ Keeper_unread_turn_bundles.session; bundle } : Keeper_unread_turn_bundles.root) ->
       String_map.update session
         (fun found ->
            Some (String_set.add (bundle :> string) (Option.value ~default:String_set.empty found)))
         by_session)
    String_map.empty
    unread
;;

let plan_sessions ~skip_active_sessions ~session_root ~external_roots ~unread =
  let* sessions = subdirectories session_root in
  List.fold_left
    (fun acc session_id ->
       let* roots_seen, plans = acc in
       if skip_active_sessions
          && Keeper_checkpoint_store_lineage.has_active_lineage_for_session ~session_id
       then Ok (roots_seen, plans)
       else (
         let session_dir = Filename.concat session_root session_id in
         let objects_dir = Filename.concat session_dir Object_store.dirname in
         let* objects = kind objects_dir |> Result.map_error (fun detail ->
           Listing_failed { path = objects_dir; detail }) in
         match objects with
         | None
         | Some ((Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK), _, _) ->
           Ok (roots_seen, plans)
         | Some (Unix.S_DIR, _, _) ->
           let canonical_path = Checkpoint.agent_core_checkpoint_path ~session_dir ~session_id in
           let retained_dir = Filename.concat session_dir Checkpoint.retained_dirname in
           let* canonical_stamp =
             path_stamp canonical_path
             |> Result.map_error (fun detail -> Root_unreadable { path = canonical_path; detail })
           in
           let* retained_stamp =
             path_stamp retained_dir
             |> Result.map_error (fun detail -> Listing_failed { path = retained_dir; detail })
           in
           let* own = session_root_files ~session_dir ~session_id in
           let external_roots_for_session =
             Option.value ~default:[] (String_map.find_opt session_id external_roots)
           in
           let others =
             List.map (fun root -> Root_bytes root) external_roots_for_session
           in
           let* current, live = reached ~session_root ~session_dir (own @ others) in
           let live =
             Option.fold ~none:live ~some:(String_set.union live) (String_map.find_opt session_id unread)
           in
           Ok
             ( roots_seen + current
             , { session_id
               ; session_dir
               ; objects_dir
               ; canonical_stamp
               ; retained_stamp
               ; external_roots = external_roots_for_session
               ; live
               }
               :: plans )))
    (Ok (0, []))
    sessions
;;

let failed report detail = { report with failures = detail :: report.failures }

let remove_object ~cutoff_mtime ~live ~prefix_dir report name =
  match Objects.digest_of_hex name with
  | Error _ -> report
  | Ok _ when not (String.equal (String.sub name 0 2) (Filename.basename prefix_dir)) -> report
  | Ok _ when String_set.mem name live -> { report with kept = report.kept + 1 }
  | Ok _ ->
    let path = Filename.concat prefix_dir name in
    (match kind path with
     | Error detail -> failed report (path ^ ": " ^ detail)
     | Ok (Some (Unix.S_REG, size, mtime)) ->
       let too_fresh =
         match cutoff_mtime with
         | None -> false
         | Some cutoff -> mtime > cutoff
       in
       if too_fresh
       then { report with kept = report.kept + 1 }
       else (
         match Sys.remove path with
         | () -> { report with removed = report.removed + 1; removed_bytes = report.removed_bytes + size }
         | exception Sys_error detail -> failed report detail)
     | Ok (Some ((Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK), _, _))
     | Ok None -> report)
;;

let sweep_objects_dir ~cutoff_mtime ~live ~objects_dir report =
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
         | Ok (Some names) ->
           List.fold_left (remove_object ~cutoff_mtime ~live ~prefix_dir) report names)
      report
      prefixes
;;

let remove_unreached
      ~skip_active_sessions
      ~cutoff_mtime
      ~post_plan_external_roots
      report
      plan
  =
  if not skip_active_sessions
  then sweep_objects_dir ~cutoff_mtime ~live:plan.live ~objects_dir:plan.objects_dir report
  else (
    (* Periodic runtime-safe sweep: acquire the per-session lock and re-verify
       that no in-flight save started, neither the canonical head nor
       [accepted-checkpoints/] mutated, and no new Gate preparation head
       appeared for this session since [plan_sessions]. If anything moved,
       defer this session safely to the next sweep without unlinking. *)
    let external_now =
      Option.value ~default:[] (String_map.find_opt plan.session_id post_plan_external_roots)
    in
    if
      Keeper_checkpoint_store_lineage.has_active_lineage_for_session ~session_id:plan.session_id
      || external_now <> plan.external_roots
    then report
    else (
      match
        Checkpoint.with_session_lock ~session_dir:plan.session_dir (fun _locked_dir ->
          let canonical_path =
            Checkpoint.agent_core_checkpoint_path
              ~session_dir:plan.session_dir
              ~session_id:plan.session_id
          in
          let retained_dir = Filename.concat plan.session_dir Checkpoint.retained_dirname in
          let canonical_ok =
            match path_stamp canonical_path with
            | Ok stamp -> stamp = plan.canonical_stamp
            | Error _ -> false
          in
          let retained_ok =
            match path_stamp retained_dir with
            | Ok stamp -> stamp = plan.retained_stamp
            | Error _ -> false
          in
          if
            Keeper_checkpoint_store_lineage.has_active_lineage_for_session
              ~session_id:plan.session_id
            || not canonical_ok
            || not retained_ok
          then report
          else sweep_objects_dir ~cutoff_mtime ~live:plan.live ~objects_dir:plan.objects_dir report)
      with
      | Ok updated -> updated
      | Error detail -> failed report (plan.session_dir ^ ": " ^ detail)))
;;

let run_with_options ~skip_active_sessions ~cutoff_mtime ~runtime_root ~memory_dir =
  let* records =
    Keeper_retained_checkpoint_sweep.owner_records ~runtime_root
    |> Result.map_error (fun error -> Owner_stores_unreadable error)
  in
  let external_roots = gate_roots records in
  let* unread =
    Keeper_unread_turn_bundles.read
      ~turns_dir:(Filename.concat runtime_root Common.keepers_runtime_dirname)
      ~memory_dir
    |> Result.map unread_by_session
    |> Result.map_error (fun error -> Unread_lines_unreadable error)
  in
  let* session_root = resolved (Keeper_fs.session_store_path_for_runtime_root runtime_root) in
  let* roots, plans =
    match session_root with
    | None -> Ok (0, [])
    | Some session_root ->
      plan_sessions ~skip_active_sessions ~session_root ~external_roots ~unread
  in
  let* post_plan_external_roots =
    if not skip_active_sessions
    then Ok external_roots
    else
      let+ latest_records =
        Keeper_retained_checkpoint_sweep.owner_records ~runtime_root
        |> Result.map_error (fun error -> Owner_stores_unreadable error)
      in
      gate_roots latest_records
  in
  let empty =
    { sessions = List.length plans; roots; kept = 0; removed = 0; removed_bytes = 0; failures = [] }
  in
  let report =
    List.fold_left
      (remove_unreached ~skip_active_sessions ~cutoff_mtime ~post_plan_external_roots)
      empty
      (List.rev plans)
  in
  Ok { report with failures = List.rev report.failures }
;;

let run ~runtime_root ~memory_dir =
  run_with_options
    ~skip_active_sessions:false
    ~cutoff_mtime:None
    ~runtime_root
    ~memory_dir
;;

let run_periodic ~min_age_seconds ~runtime_root ~memory_dir =
  let sweep_started_at = Time_compat.now () in
  let cutoff_mtime = Some (sweep_started_at -. Float.max 0.0 min_age_seconds) in
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    run_with_options
      ~skip_active_sessions:true
      ~cutoff_mtime
      ~runtime_root
      ~memory_dir)
;;
