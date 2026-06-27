(** Read-only operator report for Memory OS fact-store GC dry-runs. *)

type keeper_result =
  | Keeper_ok of
      { keeper_id : string
      ; total_input : int
      ; ttl_expired : int
      ; dedup_removed : int
      ; written : int
      }
  | Keeper_error of
      { keeper_id : string
      ; message : string
      }

type t =
  { keepers_dir : string
  ; results : keeper_result list
  ; total_input : int
  ; ttl_expired : int
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
  Keeper_error
    { keeper_id
    ; message = Printf.sprintf "fact store not found: %s" path
    }
;;

let run_one ~keepers_dir ~explicit ~keeper_id ~now =
  let facts_path =
    Keeper_memory_os_io.facts_path_for_keepers_dir ~keepers_dir ~keeper_id
  in
  if explicit && not (Sys.file_exists facts_path)
  then fact_store_missing_error ~keepers_dir ~keeper_id
  else (
    try
      let report =
        Keeper_memory_os_gc.run_gc_for_keepers_dir
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
        ; dedup_removed = report.dedup_removed
        ; written = report.written
        }
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Keeper_error { keeper_id; message = Printexc.to_string exn })
;;

let run_for_keepers_dir ~keepers_dir ?keeper_ids ~now () =
  let explicit, keeper_ids =
    match keeper_ids with
    | Some ids -> true, unique_sorted ids
    | None ->
      ( false
      , Keeper_memory_os_io.list_fact_store_keeper_ids_for_keepers_dir ~keepers_dir )
  in
  let results =
    List.map (fun keeper_id -> run_one ~keepers_dir ~explicit ~keeper_id ~now) keeper_ids
  in
  let total_input, ttl_expired, dedup_removed, written, error_count =
    List.fold_left
      (fun (total_input, ttl_expired, dedup_removed, written, error_count) -> function
         | Keeper_ok row ->
           ( total_input + row.total_input
           , ttl_expired + row.ttl_expired
           , dedup_removed + row.dedup_removed
           , written + row.written
           , error_count )
         | Keeper_error _ ->
           total_input, ttl_expired, dedup_removed, written, error_count + 1)
      (0, 0, 0, 0, 0)
      results
  in
  { keepers_dir
  ; results
  ; total_input
  ; ttl_expired
  ; dedup_removed
  ; written
  ; error_count
  }
;;

let result_to_json = function
  | Keeper_ok row ->
    `Assoc
      [ "keeper_id", `String row.keeper_id
      ; "status", `String "ok"
      ; "dry_run", `Bool true
      ; "total_input", `Int row.total_input
      ; "ttl_expired", `Int row.ttl_expired
      ; "dedup_removed", `Int row.dedup_removed
      ; "written", `Int row.written
      ]
  | Keeper_error row ->
    `Assoc
      [ "keeper_id", `String row.keeper_id
      ; "status", `String "error"
      ; "dry_run", `Bool true
      ; "error", `String row.message
      ]
;;

let to_json report =
  `Assoc
    [ "keepers_dir", `String report.keepers_dir
    ; "dry_run", `Bool true
    ; "keeper_count", `Int (List.length report.results)
    ; "error_count", `Int report.error_count
    ; "total_input", `Int report.total_input
    ; "ttl_expired", `Int report.ttl_expired
    ; "dedup_removed", `Int report.dedup_removed
    ; "written", `Int report.written
    ; "keepers", `List (List.map result_to_json report.results)
    ]
;;

let render_result = function
  | Keeper_ok row ->
    Printf.sprintf
      "%s\tok\ttotal=%d\tttl_expired=%d\tdedup_removed=%d\twould_write=%d\n"
      row.keeper_id
      row.total_input
      row.ttl_expired
      row.dedup_removed
      row.written
  | Keeper_error row -> Printf.sprintf "%s\terror\t%s\n" row.keeper_id row.message
;;

let render_text report =
  let body =
    match report.results with
    | [] -> "no keeper fact stores found\n"
    | rows -> rows |> List.map render_result |> String.concat ""
  in
  Printf.sprintf
    "Memory OS GC dry-run\n\
     keepers_dir: %s\n\
     keepers: %d, errors: %d\n\
     totals: total=%d ttl_expired=%d dedup_removed=%d would_write=%d\n\
     %s"
    report.keepers_dir
    (List.length report.results)
    report.error_count
    report.total_input
    report.ttl_expired
    report.dedup_removed
    report.written
    body
;;
