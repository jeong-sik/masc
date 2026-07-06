(** Read-only Memory OS sanity sweep. *)

module Types = Keeper_memory_os_types
module Io = Keeper_memory_os_io
module GC = Keeper_memory_os_gc
module String_map = Map.Make (String)

type keeper_error =
  | Missing_fact_store of { facts_path : string }
  | Corrupt_fact_store of { message : string }
  | Fact_store_access_error of { message : string }
  | Fact_store_locked of
      { caller : string
      ; lock_path : string
      ; attempts : int
      }

type fact_row =
  { index : int
  ; claim : string
  ; claim_identity : string
  ; category : string
  ; claim_kind : string option
  ; first_seen : float
  ; valid_until : float option
  ; effective_valid_until : float option
  ; last_verified_at : float option
  ; reference_time : float
  ; current : bool
  ; prompt_recallable : bool
  }

type duplicate_group =
  { claim_identity : string
  ; member_indices : int list
  }

type deterministic_gc_preview =
  { total_input : int
  ; ttl_expired : int
  ; ttl_expired_ephemeral : int
  ; ttl_expired_non_ephemeral : int
  ; ttl_expired_by_category : (string * int) list
  ; dedup_removed : int
  ; written : int
  }

type keeper_result =
  | Keeper_ok of
      { keeper_id : string
      ; facts_path : string
      ; total_facts : int
      ; current_facts : int
      ; expired_facts : int
      ; prompt_recallable_current_facts : int
      ; duplicate_groups : duplicate_group list
      ; facts : fact_row list
      ; gc_preview : deterministic_gc_preview
      }
  | Keeper_error of
      { keeper_id : string
      ; error : keeper_error
      }

type t =
  { keepers_dir : string
  ; results : keeper_result list
  ; total_facts : int
  ; current_facts : int
  ; expired_facts : int
  ; prompt_recallable_current_facts : int
  ; duplicate_group_count : int
  ; deterministic_ttl_expired : int
  ; deterministic_dedup_removed : int
  ; deterministic_written : int
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
  let facts_path = Io.facts_path_for_keepers_dir ~keepers_dir ~keeper_id in
  Keeper_error { keeper_id; error = Missing_fact_store { facts_path } }
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

let string_opt_to_json = function
  | None -> `Null
  | Some value -> `String value
;;

let float_opt_to_json = function
  | None -> `Null
  | Some value -> `Float value
;;

let category_counts_to_json rows =
  `Assoc (List.map (fun (category, count) -> category, `Int count) rows)
;;

let row_of_fact ~now ~index (fact : Types.fact) =
  let current = Types.fact_is_current ~now fact in
  { index
  ; claim = fact.claim
  ; claim_identity = Types.claim_identity fact
  ; category = Types.category_to_string fact.category
  ; claim_kind = Option.map Types.claim_kind_to_string fact.claim_kind
  ; first_seen = fact.first_seen
  ; valid_until = fact.valid_until
  ; effective_valid_until = Types.fact_effective_valid_until fact
  ; last_verified_at = fact.last_verified_at
  ; reference_time = Types.reference_time fact
  ; current
  ; prompt_recallable = current && Types.fact_prompt_recallable fact
  }
;;

let duplicate_groups rows =
  let by_identity =
    List.fold_left
      (fun acc row ->
         if row.current
         then (
           let indices =
             match String_map.find_opt row.claim_identity acc with
             | Some indices -> indices
             | None -> []
           in
           String_map.add row.claim_identity (row.index :: indices) acc)
         else acc)
      String_map.empty
      rows
  in
  by_identity
  |> String_map.bindings
  |> List.filter_map (fun (claim_identity, indices) ->
    match List.sort compare indices with
    | [] | [ _ ] -> None
    | member_indices -> Some { claim_identity; member_indices })
;;

let gc_preview_of_report (report : GC.gc_report) =
  { total_input = report.total_input
  ; ttl_expired = report.ttl_expired
  ; ttl_expired_ephemeral = report.ttl_expired_ephemeral
  ; ttl_expired_non_ephemeral = report.ttl_expired_non_ephemeral
  ; ttl_expired_by_category = report.ttl_expired_by_category
  ; dedup_removed = report.dedup_removed
  ; written = report.written
  }
;;

let run_gc_preview ~keepers_dir ~keeper_id ~now =
  GC.run_gc_for_keepers_dir ~keepers_dir ~dry_run:true ~keeper_id ~now ()
  |> gc_preview_of_report
;;

let run_one ~keepers_dir ~explicit ~keeper_id ~now =
  let facts_path = Io.facts_path_for_keepers_dir ~keepers_dir ~keeper_id in
  if explicit && not (Sys.file_exists facts_path)
  then fact_store_missing_error ~keepers_dir ~keeper_id
  else (
    try
      match Io.read_facts_all_strict_for_keepers_dir ~keepers_dir ~keeper_id with
      | Error message -> Keeper_error { keeper_id; error = Corrupt_fact_store { message } }
      | Ok facts ->
        let rows = List.mapi (fun index fact -> row_of_fact ~now ~index fact) facts in
        let current_facts = List.length (List.filter (fun row -> row.current) rows) in
        let expired_facts = List.length rows - current_facts in
        let prompt_recallable_current_facts =
          List.length (List.filter (fun row -> row.prompt_recallable) rows)
        in
        let duplicate_groups = duplicate_groups rows in
        let gc_preview = run_gc_preview ~keepers_dir ~keeper_id ~now in
        Keeper_ok
          { keeper_id
          ; facts_path
          ; total_facts = List.length rows
          ; current_facts
          ; expired_facts
          ; prompt_recallable_current_facts
          ; duplicate_groups
          ; facts = rows
          ; gc_preview
          }
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | File_lock_eio.Flock_timeout { caller; path; attempts } ->
      Keeper_error
        { keeper_id; error = Fact_store_locked { caller; lock_path = path; attempts } }
    | GC.Fact_store_corrupt message ->
      Keeper_error { keeper_id; error = Corrupt_fact_store { message } }
    | exn ->
      (match access_error_message exn with
       | Some message -> Keeper_error { keeper_id; error = Fact_store_access_error { message } }
       | None -> raise exn))
;;

let run_for_keepers_dir ~keepers_dir ?keeper_ids ~now () =
  let explicit, keeper_ids =
    match keeper_ids with
    | Some ids -> true, unique_sorted ids
    | None -> false, Io.list_fact_store_keeper_ids_for_keepers_dir ~keepers_dir
  in
  let results =
    List.map (fun keeper_id -> run_one ~keepers_dir ~explicit ~keeper_id ~now) keeper_ids
  in
  let
    ( total_facts
    , current_facts
    , expired_facts
    , prompt_recallable_current_facts
    , duplicate_group_count
    , deterministic_ttl_expired
    , deterministic_dedup_removed
    , deterministic_written
    , error_count )
    =
    List.fold_left
      (fun
        ( total_facts
        , current_facts
        , expired_facts
        , prompt_recallable_current_facts
        , duplicate_group_count
        , deterministic_ttl_expired
        , deterministic_dedup_removed
        , deterministic_written
        , error_count )
        -> function
         | Keeper_ok row ->
           ( total_facts + row.total_facts
           , current_facts + row.current_facts
           , expired_facts + row.expired_facts
           , prompt_recallable_current_facts + row.prompt_recallable_current_facts
           , duplicate_group_count + List.length row.duplicate_groups
           , deterministic_ttl_expired + row.gc_preview.ttl_expired
           , deterministic_dedup_removed + row.gc_preview.dedup_removed
           , deterministic_written + row.gc_preview.written
           , error_count )
         | Keeper_error _ ->
           ( total_facts
           , current_facts
           , expired_facts
           , prompt_recallable_current_facts
           , duplicate_group_count
           , deterministic_ttl_expired
           , deterministic_dedup_removed
           , deterministic_written
           , error_count + 1 ))
      (0, 0, 0, 0, 0, 0, 0, 0, 0)
      results
  in
  { keepers_dir
  ; results
  ; total_facts
  ; current_facts
  ; expired_facts
  ; prompt_recallable_current_facts
  ; duplicate_group_count
  ; deterministic_ttl_expired
  ; deterministic_dedup_removed
  ; deterministic_written
  ; error_count
  }
;;

module For_testing = struct
  let row_of_fact = row_of_fact
  let duplicate_groups = duplicate_groups
end

let fact_row_to_json row =
  `Assoc
    [ "index", `Int row.index
    ; "claim", `String row.claim
    ; "claim_identity", `String row.claim_identity
    ; "category", `String row.category
    ; "claim_kind", string_opt_to_json row.claim_kind
    ; "first_seen", `Float row.first_seen
    ; "valid_until", float_opt_to_json row.valid_until
    ; "effective_valid_until", float_opt_to_json row.effective_valid_until
    ; "last_verified_at", float_opt_to_json row.last_verified_at
    ; "reference_time", `Float row.reference_time
    ; "current", `Bool row.current
    ; "prompt_recallable", `Bool row.prompt_recallable
    ]
;;

let duplicate_group_to_json group =
  `Assoc
    [ "claim_identity", `String group.claim_identity
    ; "member_indices", `List (List.map (fun index -> `Int index) group.member_indices)
    ]
;;

let gc_preview_to_json preview =
  `Assoc
    [ "dry_run", `Bool true
    ; "total_input", `Int preview.total_input
    ; "ttl_expired", `Int preview.ttl_expired
    ; "ttl_expired_ephemeral", `Int preview.ttl_expired_ephemeral
    ; "ttl_expired_non_ephemeral", `Int preview.ttl_expired_non_ephemeral
    ; "ttl_expired_by_category", category_counts_to_json preview.ttl_expired_by_category
    ; "dedup_removed", `Int preview.dedup_removed
    ; "written", `Int preview.written
    ]
;;

let result_to_json = function
  | Keeper_ok row ->
    Tool_args.ok_assoc
      [ "keeper_id", `String row.keeper_id
      ; "facts_path", `String row.facts_path
      ; "total_facts", `Int row.total_facts
      ; "current_facts", `Int row.current_facts
      ; "expired_facts", `Int row.expired_facts
      ; "prompt_recallable_current_facts", `Int row.prompt_recallable_current_facts
      ; ( "duplicate_groups"
        , `List (List.map duplicate_group_to_json row.duplicate_groups) )
      ; "facts", `List (List.map fact_row_to_json row.facts)
      ; "gc_preview", gc_preview_to_json row.gc_preview
      ]
  | Keeper_error row ->
    Tool_args.error_assoc
      [ "keeper_id", `String row.keeper_id
      ; "error_code", `String (keeper_error_code row.error)
      ; "message", `String (keeper_error_message row.error)
      ]
;;

let to_json report =
  Tool_args.ok_assoc
    [ "schema", `String "masc.memory_os.sanity_sweep.v1"
    ; "mode", `String "read_only_dry_run"
    ; "decision_policy", `String "typed_state_only_no_prose_inference"
    ; "keepers_dir", `String report.keepers_dir
    ; "keeper_count", `Int (List.length report.results)
    ; "total_facts", `Int report.total_facts
    ; "current_facts", `Int report.current_facts
    ; "expired_facts", `Int report.expired_facts
    ; "prompt_recallable_current_facts", `Int report.prompt_recallable_current_facts
    ; "duplicate_group_count", `Int report.duplicate_group_count
    ; "deterministic_ttl_expired", `Int report.deterministic_ttl_expired
    ; "deterministic_dedup_removed", `Int report.deterministic_dedup_removed
    ; "deterministic_written", `Int report.deterministic_written
    ; "error_count", `Int report.error_count
    ; "keepers", `List (List.map result_to_json report.results)
    ]
;;

let render_duplicate_group group =
  Printf.sprintf
    "    - identity=%s indices=[%s]\n"
    group.claim_identity
    (group.member_indices |> List.map string_of_int |> String.concat ",")
;;

let render_keeper_result = function
  | Keeper_error row ->
    Printf.sprintf
      "- %s: ERROR %s (%s)\n"
      row.keeper_id
      (keeper_error_code row.error)
      (keeper_error_message row.error)
  | Keeper_ok row ->
    let duplicate_text =
      match row.duplicate_groups with
      | [] -> ""
      | groups ->
        "  duplicate claim groups:\n"
        ^ (groups |> List.map render_duplicate_group |> String.concat "")
    in
    Printf.sprintf
      "- %s: facts=%d current=%d expired=%d prompt_recallable_current=%d \
       gc_ttl_expired=%d gc_dedup_removed=%d gc_written=%d\n%s"
      row.keeper_id
      row.total_facts
      row.current_facts
      row.expired_facts
      row.prompt_recallable_current_facts
      row.gc_preview.ttl_expired
      row.gc_preview.dedup_removed
      row.gc_preview.written
      duplicate_text
;;

let render_text report =
  let header =
    Printf.sprintf
      "Memory OS sanity sweep (read-only dry-run)\n\
       policy: typed_state_only_no_prose_inference\n\
       keepers_dir: %s\n\
       keepers=%d total_facts=%d current=%d expired=%d \
       prompt_recallable_current=%d duplicate_groups=%d errors=%d\n\
       deterministic_gc: ttl_expired=%d dedup_removed=%d written=%d\n\n"
      report.keepers_dir
      (List.length report.results)
      report.total_facts
      report.current_facts
      report.expired_facts
      report.prompt_recallable_current_facts
      report.duplicate_group_count
      report.error_count
      report.deterministic_ttl_expired
      report.deterministic_dedup_removed
      report.deterministic_written
  in
  header ^ (report.results |> List.map render_keeper_result |> String.concat "")
;;
