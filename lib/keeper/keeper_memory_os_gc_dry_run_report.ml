(** Read-only operator report for Memory OS fact-store GC dry-runs. *)

type keeper_error =
  | Missing_fact_store of { facts_path : string }
  | Corrupt_fact_store of { message : string }
  | Fact_store_access_error of { message : string }
  | Fact_store_locked of
      { caller : string
      ; lock_path : string
      ; attempts : int
      }

type keeper_result =
  | Keeper_ok of
      { keeper_id : string
      ; total_input : int
      ; ttl_expired : int
      ; ttl_expired_ephemeral : int
      ; ttl_expired_non_ephemeral : int
      ; ttl_expired_by_category : (string * int) list
      ; dedup_removed : int
      ; written : int
      }
  | Keeper_error of
      { keeper_id : string
      ; error : keeper_error
      }

type t =
  { keepers_dir : string
  ; keeper_ids_known : bool
  ; keeper_id_discovery_read_errors : string list
  ; results : keeper_result list
  ; total_input : int
  ; ttl_expired : int
  ; ttl_expired_ephemeral : int
  ; ttl_expired_non_ephemeral : int
  ; ttl_expired_by_category : (string * int) list
  ; dedup_removed : int
  ; written : int
  ; error_count : int
  }

let unique_sorted xs =
  xs
  |> List.filter_map (fun s ->
    let s = String.trim s in
    if String.equal s "" then None else Some s)
  |> List.sort_uniq String.compare
;;

let fact_store_missing_error ~keepers_dir ~keeper_id =
  let path = Keeper_memory_os_io.facts_path_for_keepers_dir ~keepers_dir ~keeper_id in
  Keeper_error { keeper_id; error = Missing_fact_store { facts_path = path } }
;;

let access_error_message = function
  | Sys_error message -> Some message
  | Unix.Unix_error (error, fn, arg) ->
    Some (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message error))
  | _ -> None
;;

let keeper_error_message = function
  | Missing_fact_store { facts_path } -> Printf.sprintf "fact store not found: %s" facts_path
  | Corrupt_fact_store { message } | Fact_store_access_error { message } -> message
  | Fact_store_locked { caller; lock_path; attempts } ->
    Printf.sprintf
      "fact store lock timeout: caller=%s lock_path=%s attempts=%d"
      caller
      lock_path
      attempts
;;

let keeper_error_code = function
  | Missing_fact_store _ -> "fact_store_missing"
  | Corrupt_fact_store _ -> "fact_store_corrupt"
  | Fact_store_access_error _ -> "fact_store_access_error"
  | Fact_store_locked _ -> "fact_store_locked"
;;

module String_map = Map.Make (String)

let merge_category_counts left right =
  let add counts (category, count) =
    let current =
      match String_map.find_opt category counts with
      | Some current -> current
      | None -> 0
    in
    String_map.add category (current + count) counts
  in
  List.fold_left add String_map.empty (left @ right) |> String_map.bindings
;;

let default_run_gc_for_keepers_dir ~keepers_dir ~dry_run ~keeper_id ~now () =
  Keeper_memory_os_gc.run_gc_for_keepers_dir
    ~keepers_dir
    ~dry_run
    ~keeper_id
    ~now
    ()
;;

let run_one ~keepers_dir ~run_gc_for_keepers_dir ~explicit ~keeper_id ~now =
  let facts_path =
    Keeper_memory_os_io.facts_path_for_keepers_dir ~keepers_dir ~keeper_id
  in
  if explicit && not (Sys.file_exists facts_path)
  then fact_store_missing_error ~keepers_dir ~keeper_id
  else (
    try
      let (report : Keeper_memory_os_gc.gc_report) =
        run_gc_for_keepers_dir
          ~keepers_dir
          ~dry_run:true
          ~keeper_id
          ~now
          ()
      in
      Keeper_ok
        { keeper_id
        ; total_input = report.total_input
        ; ttl_expired = report.ttl_expired
        ; ttl_expired_ephemeral = report.ttl_expired_ephemeral
        ; ttl_expired_non_ephemeral = report.ttl_expired_non_ephemeral
        ; ttl_expired_by_category = report.ttl_expired_by_category
        ; dedup_removed = report.dedup_removed
        ; written = report.written
        }
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | File_lock_eio.Flock_timeout { caller; path; attempts } ->
      Keeper_error
        { keeper_id; error = Fact_store_locked { caller; lock_path = path; attempts } }
    | Keeper_memory_os_gc.Fact_store_corrupt message ->
      Keeper_error { keeper_id; error = Corrupt_fact_store { message } }
    | exn ->
      (match access_error_message exn with
       | Some message -> Keeper_error { keeper_id; error = Fact_store_access_error { message } }
       | None -> raise exn))
;;

let run_for_keepers_dir_with_runner
      ~keepers_dir
      ~run_gc_for_keepers_dir
      ?keeper_ids
      ~now
      ()
  =
  let explicit, keeper_ids =
    match keeper_ids with
    | Some ids -> true, unique_sorted ids
    | None ->
      false, []
  in
  let keeper_ids_known, keeper_id_discovery_read_errors, keeper_ids =
    if explicit
    then true, [], keeper_ids
    else (
      match
        Keeper_memory_os_io.list_fact_store_keeper_ids_for_keepers_dir_result
          ~keepers_dir
      with
      | Ok keeper_ids -> true, [], keeper_ids
      | Error error -> false, [ error ], [])
  in
  let results =
    List.map
      (fun keeper_id ->
         run_one ~keepers_dir ~run_gc_for_keepers_dir ~explicit ~keeper_id ~now)
      keeper_ids
  in
  let
    total_input,
    ttl_expired,
    ttl_expired_ephemeral,
    ttl_expired_non_ephemeral,
    ttl_expired_by_category,
    dedup_removed,
    written,
    error_count
    =
    List.fold_left
      (fun
        ( total_input
        , ttl_expired
        , ttl_expired_ephemeral
        , ttl_expired_non_ephemeral
        , ttl_expired_by_category
        , dedup_removed
        , written
        , error_count )
        -> function
         | Keeper_ok row ->
           ( total_input + row.total_input
           , ttl_expired + row.ttl_expired
           , ttl_expired_ephemeral + row.ttl_expired_ephemeral
           , ttl_expired_non_ephemeral + row.ttl_expired_non_ephemeral
           , merge_category_counts ttl_expired_by_category row.ttl_expired_by_category
           , dedup_removed + row.dedup_removed
           , written + row.written
           , error_count )
         | Keeper_error _ ->
           ( total_input
           , ttl_expired
           , ttl_expired_ephemeral
           , ttl_expired_non_ephemeral
           , ttl_expired_by_category
           , dedup_removed
           , written
           , error_count + 1 ))
      (0, 0, 0, 0, [], 0, 0, 0)
      results
  in
  { keepers_dir
  ; keeper_ids_known
  ; keeper_id_discovery_read_errors
  ; results
  ; total_input
  ; ttl_expired
  ; ttl_expired_ephemeral
  ; ttl_expired_non_ephemeral
  ; ttl_expired_by_category
  ; dedup_removed
  ; written
  ; error_count = error_count + List.length keeper_id_discovery_read_errors
  }
;;

let run_for_keepers_dir ~keepers_dir ?keeper_ids ~now () =
  run_for_keepers_dir_with_runner
    ~keepers_dir
    ~run_gc_for_keepers_dir:default_run_gc_for_keepers_dir
    ?keeper_ids
    ~now
    ()
;;

module For_testing = struct
  let run_for_keepers_dir ~keepers_dir ~run_gc_for_keepers_dir ?keeper_ids ~now () =
    run_for_keepers_dir_with_runner
      ~keepers_dir
      ~run_gc_for_keepers_dir
      ?keeper_ids
      ~now
      ()
  ;;
end

let category_counts_to_json rows =
  `Assoc (List.map (fun (category, count) -> category, `Int count) rows)
;;

let result_to_json = function
  | Keeper_ok row ->
    Tool_args.ok_assoc
      [ "keeper_id", `String row.keeper_id
      ; "dry_run", `Bool true
      ; "total_input", `Int row.total_input
      ; "ttl_expired", `Int row.ttl_expired
      ; "ttl_expired_ephemeral", `Int row.ttl_expired_ephemeral
      ; "ttl_expired_non_ephemeral", `Int row.ttl_expired_non_ephemeral
      ; "ttl_expired_by_category", category_counts_to_json row.ttl_expired_by_category
      ; "migration_candidate_expired", `Int row.ttl_expired_non_ephemeral
      ; "dedup_removed", `Int row.dedup_removed
      ; "written", `Int row.written
      ]
  | Keeper_error row ->
    Tool_args.error_assoc
      [ "keeper_id", `String row.keeper_id
      ; "dry_run", `Bool true
      ; "error_code", `String (keeper_error_code row.error)
      ; "message", `String (keeper_error_message row.error)
      ]
;;

let to_json report =
  `Assoc
    [ "keepers_dir", `String report.keepers_dir
    ; "dry_run", `Bool true
    ; "keeper_ids_known", `Bool report.keeper_ids_known
    ; ( "keeper_id_discovery_read_error_count"
      , `Int (List.length report.keeper_id_discovery_read_errors) )
    ; ( "keeper_id_discovery_read_errors"
      , `List
          (List.map
             (fun error ->
               `Assoc
                 [ "source", `String "list_fact_store_keeper_ids_for_keepers_dir"
                 ; "path", `String report.keepers_dir
                 ; "error", `String error
                 ])
             report.keeper_id_discovery_read_errors) )
    ; "keeper_count", `Int (List.length report.results)
    ; "error_count", `Int report.error_count
    ; "total_input", `Int report.total_input
    ; "ttl_expired", `Int report.ttl_expired
    ; "ttl_expired_ephemeral", `Int report.ttl_expired_ephemeral
    ; "ttl_expired_non_ephemeral", `Int report.ttl_expired_non_ephemeral
    ; "ttl_expired_by_category", category_counts_to_json report.ttl_expired_by_category
    ; "migration_candidate_expired", `Int report.ttl_expired_non_ephemeral
    ; "dedup_removed", `Int report.dedup_removed
    ; "written", `Int report.written
    ; "keepers", `List (List.map result_to_json report.results)
    ]
;;

let render_result = function
  | Keeper_ok row ->
    Printf.sprintf
      "%s\tok\ttotal=%d\tttl_expired=%d\tephemeral_expired=%d\tmigration_candidates=%d\tdedup_removed=%d\twould_write=%d\n"
      row.keeper_id
      row.total_input
      row.ttl_expired
      row.ttl_expired_ephemeral
      row.ttl_expired_non_ephemeral
      row.dedup_removed
      row.written
  | Keeper_error row ->
    Printf.sprintf
      "%s\t%s\t%s\n"
      row.keeper_id
      (keeper_error_code row.error)
      (keeper_error_message row.error)
;;

let render_text report =
  let body =
    match report.results with
    | [] when report.keeper_ids_known -> "no keeper fact stores found\n"
    | [] ->
      "keeper fact store discovery failed:\n"
      ^ (report.keeper_id_discovery_read_errors
         |> List.map (fun error -> "- " ^ error ^ "\n")
         |> String.concat "")
    | rows -> rows |> List.map render_result |> String.concat ""
  in
  Printf.sprintf
    "Memory OS GC dry-run\n\
     keepers_dir: %s\n\
     keepers: %d, errors: %d\n\
     totals: total=%d ttl_expired=%d ephemeral_expired=%d migration_candidates=%d dedup_removed=%d would_write=%d\n\
     %s"
    report.keepers_dir
    (List.length report.results)
    report.error_count
    report.total_input
    report.ttl_expired
    report.ttl_expired_ephemeral
    report.ttl_expired_non_ephemeral
    report.dedup_removed
    report.written
    body
;;
