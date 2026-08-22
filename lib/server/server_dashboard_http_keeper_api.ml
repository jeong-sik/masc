(** Keeper HTTP API handlers — POST handlers + GET sub-routes.

    POST handlers extracted to [Server_dashboard_http_keeper_api_post]
    (godfile decomp). *)

include Server_dashboard_http_keeper_api_post

let handle_keeper_paused_work_post =
  Server_dashboard_http_keeper_paused_work.handle_post
;;

let standard_cache_ttl_s = Server_dashboard_http_core_cache.standard_cache_ttl_s
let freshness_slo_s = Server_dashboard_http_core_cache.freshness_slo_s

let keeper_hot_path_cache_ttl_s = 30.0
let keeper_composite_cache_ttl_s = 5.0

let tool_calls_fleet_cache_revision_mu = Stdlib.Mutex.create ()
let tool_calls_fleet_cache_revisions : (string, int) Hashtbl.t = Hashtbl.create 4

let tool_calls_fleet_cache_key ~masc_root =
  let key = Printf.sprintf "keeper:tool-calls:fleet-rows:%s" masc_root in
  let revision = Keeper_tool_call_log.committed_revision () in
  Stdlib.Mutex.protect tool_calls_fleet_cache_revision_mu (fun () ->
    match Hashtbl.find_opt tool_calls_fleet_cache_revisions masc_root with
    | Some previous when previous = revision -> ()
    | Some _ | None ->
      (* Publish the observed revision only after the old value is gone.
         Otherwise a concurrent reader can observe the new revision between
         [replace] and [invalidate], treat the cache as current, and return the
         stale rows for the full TTL. *)
      Dashboard_cache.invalidate key;
      Hashtbl.replace tool_calls_fleet_cache_revisions masc_root revision);
  key
;;

(* Bounded dashboard hydration defaults for the operator compaction inspector.
   These cap best-effort filesystem scans; [scan_truncated] in the response makes
   the bound observable when there are more manifest segments than scanned. *)
let compaction_snapshot_default_limit =
  Env_config.KeeperCompactionSnapshots.default_limit
;;

let compaction_snapshot_max_limit = Env_config.KeeperCompactionSnapshots.max_limit

let compaction_snapshot_manifest_scan_min_files =
  Env_config.KeeperCompactionSnapshots.manifest_scan_min_files
;;

let compaction_snapshot_manifest_scan_limit_multiplier =
  Env_config.KeeperCompactionSnapshots.manifest_scan_limit_multiplier
;;

let compaction_snapshot_manifest_scan_max_bytes = 64 * 1024 * 1024

(* Maximum number of trajectory/trace entries returned per query. *)
let trajectory_max_limit = 500

(* Maximum per-keeper entries for /tool-calls; also sizes the shared
   fleet-row window that per-keeper responses derive from. *)
let tool_calls_limit_max = 200

let cached_assoc_body_or_self cached fields =
  match List.assoc_opt "body" fields with
  | Some body -> body
  | None -> cached
;;

type state_diagram_runtime_projection =
  { runtime_models : string list
  ; last_provider_result : string option
  ; runtime_models_source : string
  ; last_provider_result_source : string
  ; effective_runtime_reason : string option
  }

let public_runtime_model_label =
  Boundary_redaction.to_string Boundary_redaction.runtime_model_label
;;

let state_diagram_runtime_projection
    (meta : Keeper_meta_contract.keeper_meta option)
  =
  match meta with
  | None ->
    { runtime_models = []
    ; last_provider_result = None
    ; runtime_models_source = "missing_keeper_meta"
    ; last_provider_result_source = "missing_keeper_meta"
    ; effective_runtime_reason = None
    }
  | Some m ->
    let last_runtime_attempt =
      match m.runtime.last_runtime_attempt with
      | Some attempt
        when String.trim attempt.Keeper_meta_contract.provider_id <> "" ->
        Some attempt
      | Some _ | None -> None
    in
    let runtime_projection_evidence, runtime_projection_source =
      try
        let runtime_id = Keeper_meta_contract.runtime_id_of_meta m in
        let has_evidence =
          Provider_runtime_projection.default_execution_model_strings runtime_id
          |> List.exists (fun label -> String.trim label <> "")
        in
        ( has_evidence
        , if has_evidence
          then "provider_runtime_projection.default_execution_model_strings"
          else "provider_runtime_projection.empty" )
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | _ -> false, "provider_runtime_projection.unavailable"
    in
    let runtime_model_evidence =
      Option.is_some last_runtime_attempt || runtime_projection_evidence
    in
    let runtime_models =
      if runtime_model_evidence then [ public_runtime_model_label ] else []
    in
    let last_provider_result, last_provider_result_source =
      match last_runtime_attempt, runtime_models with
      | Some _, _ :: _ ->
        Some public_runtime_model_label, "keeper_meta.runtime.last_runtime_attempt"
      | Some _, [] ->
        None, "keeper_meta.runtime.last_runtime_attempt_without_model_evidence"
      | None, _ -> None, "missing_keeper_meta.runtime.last_runtime_attempt"
    in
    { runtime_models
    ; last_provider_result
    ; runtime_models_source =
        (match last_runtime_attempt with
         | Some _ -> "keeper_meta.runtime.last_runtime_attempt"
         | None -> runtime_projection_source)
    ; last_provider_result_source
    ; effective_runtime_reason =
        (if runtime_model_evidence then Some "keeper_meta.runtime_evidence" else None)
    }
;;

let state_diagram_runtime_projection_json
    (projection : state_diagram_runtime_projection)
  =
  `Assoc
    [ "runtime_models", Json_util.json_string_list projection.runtime_models
    ; "last_provider_result", Json_util.string_opt_to_json projection.last_provider_result
    ; "runtime_models_source", `String projection.runtime_models_source
    ; "last_provider_result_source", `String projection.last_provider_result_source
    ]
;;

let state_diagram_runtime_fsm_mermaid
    (projection : state_diagram_runtime_projection)
  =
  Keeper_decision_audit.runtime_fsm_to_mermaid
    ~provider_health:[]
    ?effective_runtime_reason:projection.effective_runtime_reason
    ~models:projection.runtime_models
    ~last_provider_result:projection.last_provider_result
    ()
;;

let keeper_chat_allowed_trace_ids (m : Keeper_meta_contract.keeper_meta) =
  Keeper_id.Trace_id.to_string m.runtime.trace_id :: m.runtime.trace_history
  |> Json_util.dedupe_keep_order
;;

(* Surface only the current fact structure. [current] is derived solely from
   membership in this snapshot and is never persisted as another authority. *)
let memory_os_fact_json ~current (fact : Keeper_memory_os_types.fact) =
  `Assoc
    [ "memory_id", `String (Keeper_memory_os_types.memory_id fact)
    ; "claim", `String fact.claim
    ; "category", `String (Keeper_memory_os_types.category_to_string fact.category)
    ; "first_seen", `Float fact.first_seen
    ; "current", `Bool current
     ]
;;

let memory_os_change_json (change : Keeper_memory_os_current.change) =
  `Assoc
    [ "added", `List (List.map (memory_os_fact_json ~current:true) change.added)
    ; "removed", `List (List.map (memory_os_fact_json ~current:false) change.removed)
    ; "retained", `Int change.retained
    ]
;;

let memory_os_keepers_dir (config : Workspace.config) =
  Config_dir_resolver.keepers_dir_for_base_path
    ~base_path:config.Workspace.base_path
;;

let memory_os_dashboard_json ~(config : Workspace.config) ~keeper_id =
  let keepers_dir = memory_os_keepers_dir config in
  let snapshot, read_error =
    match
      Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id
    with
    | Ok snapshot -> snapshot, None
    | Error message -> None, Some message
  in
  let facts, change, revision, updated_at, source =
    match snapshot with
    | None ->
      ( []
      , `Assoc [ "added", `List []; "removed", `List []; "retained", `Int 0 ]
      , 0
      , None
      , `Null )
    | Some snapshot ->
      let source = snapshot.Keeper_memory_os_current.source in
      ( snapshot.facts
      , memory_os_change_json snapshot.change
      , snapshot.revision
      , Some snapshot.updated_at
      , `Assoc
          [ ( "kind"
            , `String
                (match source.kind with
                 | Keeper_memory_os_current.Librarian -> "librarian"
                 | Explicit_write -> "explicit_write") )
          ; "trace_id", `String source.trace_id
          ; "generation", `Int source.generation
          ] )
  in
  let current_facts = List.length facts in
  `Assoc
    [ "keeper", `String keeper_id
    ; ( "snapshot_store"
      , `String
          (Keeper_memory_os_current.path_for_keepers_dir
             ~keepers_dir
             ~keeper_id) )
    ; "recall_enabled", `Bool (Keeper_memory_os_recall.enabled ())
    ; "revision", `Int revision
    ; "updated_at", (match updated_at with Some value -> `Float value | None -> `Null)
    ; "update_source", source
    ; ( "read_errors"
      , match read_error with
        | None -> `List []
        | Some error ->
          `List [ `Assoc [ "scope", `String "snapshot"; "error", `String error ] ] )
    ; ( "facts"
      , `Assoc
          [ "shown", `Int (List.length facts)
          ; "current", `Int current_facts
          ; ( "items"
            , `List (List.map (memory_os_fact_json ~current:true) facts) )
          ] )
    ; "change", change
    ]
;;

let compaction_snapshot_take n xs =
  let rec loop remaining acc = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | x :: rest -> loop (remaining - 1) (x :: acc) rest
  in
  loop n [] xs
;;

type compaction_snapshot_read_error =
  { scope : string
  ; error : string
  }

let compaction_snapshot_read_error ~scope ~error = { scope; error }

let compaction_snapshot_read_error_json { scope; error } =
  `Assoc [ "scope", `String scope; "error", `String error ]
;;

let compaction_snapshot_read_errors_json errors =
  `List (List.map compaction_snapshot_read_error_json errors)
;;

let log_compaction_snapshot_read_errors ~keeper_id errors =
  List.iter
    (fun { scope; error } ->
      Log.Dashboard.warn
        "compaction_snapshots: keeper=%s scope=%s error=%s"
        keeper_id scope error)
    errors
;;

let compaction_snapshot_unix_error_message err fn arg =
  Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message err)
;;

let compaction_snapshot_scope_path ~base_dir path =
  let base_prefix =
    if String.ends_with ~suffix:Filename.dir_sep base_dir
    then base_dir
    else base_dir ^ Filename.dir_sep
  in
  if String.equal path base_dir
  then "."
  else if String.starts_with ~prefix:base_prefix path
  then
    String.sub path (String.length base_prefix) (String.length path - String.length base_prefix)
  else Filename.basename path
;;

let runtime_manifest_file_scope ~base_dir path =
  "runtime_manifest_file:" ^ compaction_snapshot_scope_path ~base_dir path
;;

let runtime_manifest_row_scope ~base_dir path line_no =
  Printf.sprintf "runtime_manifest_row:%s:%d"
    (compaction_snapshot_scope_path ~base_dir path)
    line_no
;;

let safe_regular_file_info ~base_dir path =
  try
    let st = Unix.stat path in
    if st.Unix.st_kind = Unix.S_REG
    then Some (st.Unix.st_mtime, st.Unix.st_size), []
    else None, []
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Unix.Unix_error (Unix.ENOENT, _, _) -> None, []
  | Unix.Unix_error (err, fn, arg) ->
    ( None
    , [ compaction_snapshot_read_error
          ~scope:(runtime_manifest_file_scope ~base_dir path)
          ~error:(compaction_snapshot_unix_error_message err fn arg)
      ] )
  | exn ->
    ( None
    , [ compaction_snapshot_read_error
          ~scope:(runtime_manifest_file_scope ~base_dir path)
          ~error:(Printexc.to_string exn)
      ] )
;;

let is_runtime_manifest_segment_file name =
  Filename.check_suffix name Keeper_runtime_manifest.manifest_file_suffix
  ||
  match String.rindex_opt name '.' with
  | None -> false
  | Some dot ->
    let rotation = String.sub name (dot + 1) (String.length name - dot - 1) in
    rotation <> ""
    && String.for_all (fun c -> c >= '0' && c <= '9') rotation
    && Filename.check_suffix
         (String.sub name 0 dot)
         Keeper_runtime_manifest.manifest_file_suffix
;;

let runtime_manifest_paths ~config ~keeper_id ~limit =
  let dir = Keeper_runtime_manifest.base_dir config ~keeper_name:keeper_id in
  let scan_limit =
    max compaction_snapshot_manifest_scan_min_files
      (limit * compaction_snapshot_manifest_scan_limit_multiplier)
  in
  try
    let st = Unix.stat dir in
    if st.Unix.st_kind <> Unix.S_DIR
    then
      ( []
      , [ compaction_snapshot_read_error
            ~scope:("runtime_manifest_dir:" ^ keeper_id)
            ~error:"path is not a directory"
        ]
      , false )
    else
      let entries, read_errors =
        Sys.readdir dir
        |> Array.to_list
        |> List.filter is_runtime_manifest_segment_file
        |> List.fold_left
             (fun (entries, read_errors) file ->
        let path = Filename.concat dir file in
        let file_info, errors = safe_regular_file_info ~base_dir:dir path in
        let entries =
          match file_info with
          | Some (mtime, size) -> (path, mtime, size) :: entries
          | None -> entries
        in
        entries, List.rev_append errors read_errors)
             ([], [])
      in
      let sorted_entries =
        List.sort (fun (_, a, _) (_, b, _) -> Float.compare b a) entries
      in
      let rec select selected_count selected_bytes selected = function
        | [] -> List.rev selected, false
        | _ when selected_count >= scan_limit -> List.rev selected, true
        | (path, _, size) :: rest ->
          if selected_bytes + size > compaction_snapshot_manifest_scan_max_bytes
          then List.rev selected, true
          else
            select
              (selected_count + 1)
              (selected_bytes + size)
              (path :: selected)
              rest
      in
      let selected_paths, scan_truncated = select 0 0 [] sorted_entries in
      ( selected_paths
      , List.rev read_errors
      , scan_truncated )
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Unix.Unix_error (Unix.ENOENT, _, _) -> [], [], false
  | Unix.Unix_error (err, fn, arg) ->
    ( []
    , [ compaction_snapshot_read_error
          ~scope:("runtime_manifest_dir:" ^ keeper_id)
          ~error:(compaction_snapshot_unix_error_message err fn arg)
      ]
    , false )
  | exn ->
    ( []
    , [ compaction_snapshot_read_error
          ~scope:("runtime_manifest_dir:" ^ keeper_id)
          ~error:(Printexc.to_string exn)
      ]
    , false )
;;

let read_runtime_manifest_rows ~base_dir path =
  try
    let compaction_snapshot_manifest_event_name = function
      | `Assoc fields -> (
          match List.assoc_opt "event" fields with
          | Some (`String event) -> Some event
          | _ -> None)
      | _ -> None
    in
    let parse_manifest_row line_no rows read_errors json =
      match Keeper_runtime_manifest.of_json json with
      | Ok row -> row :: rows, read_errors
      | Error msg ->
        ( rows
        , compaction_snapshot_read_error
            ~scope:(runtime_manifest_row_scope ~base_dir path line_no)
            ~error:msg
          :: read_errors )
    in
    let input = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr input)
      (fun () ->
    let rec loop line_no rows read_errors =
      match input_line input with
      | line ->
        let trimmed = String.trim line in
        if String.equal trimmed ""
        then loop line_no rows read_errors
        else
          let next_line_no = line_no + 1 in
          (try
        let json = Yojson.Safe.from_string trimmed in
        (match compaction_snapshot_manifest_event_name json with
         | Some event -> (
           match Keeper_runtime_manifest.classify_compaction_snapshot_event event with
           | Keeper_runtime_manifest.Compaction_snapshot_known_unrelated ->
             loop next_line_no rows read_errors
           | Keeper_runtime_manifest.Compaction_snapshot_relevant
           | Keeper_runtime_manifest.Compaction_snapshot_unknown ->
             let rows, read_errors =
               parse_manifest_row next_line_no rows read_errors json
             in
             loop next_line_no rows read_errors)
         | None ->
           let rows, read_errors =
             parse_manifest_row next_line_no rows read_errors json
           in
           loop next_line_no rows read_errors)
      with
          | Yojson.Json_error msg | Yojson.Safe.Util.Type_error (msg, _) ->
            loop next_line_no rows
              (compaction_snapshot_read_error
                 ~scope:(runtime_manifest_row_scope ~base_dir path next_line_no)
                 ~error:msg
               :: read_errors))
      | exception End_of_file -> List.rev rows, List.rev read_errors
    in
    loop 0 [] [])
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    ( []
    , [ compaction_snapshot_read_error
          ~scope:(runtime_manifest_file_scope ~base_dir path)
          ~error:(Printexc.to_string exn)
      ]
    )
;;

let compaction_snapshot_clock_refs decision =
  match Json_util.assoc_member_opt "clock_refs" decision with
  | Some (`Assoc _ as clock_refs) -> Some clock_refs
  | _ -> None
;;

let compaction_snapshot_clock_string decision key =
  match compaction_snapshot_clock_refs decision with
  | Some clock_refs -> Json_util.assoc_string_opt key clock_refs
  | None -> None
;;

let compaction_snapshot_links_json (links : Keeper_runtime_manifest.links) =
  `Assoc
    [ "receipt_path", Json_util.string_opt_to_json links.receipt_path
    ; "checkpoint_path", Json_util.string_opt_to_json links.checkpoint_path
    ; "tool_call_log_path", Json_util.string_opt_to_json links.tool_call_log_path
    ]
;;

let compaction_snapshot_display_runtime ~source ~runtime_id ~compaction_source =
  match runtime_id with
  | Some value when String.trim value <> "" -> value
  | Some _ | None ->
    (match compaction_source with
     | Some value when String.trim value <> "" -> value
     | Some _ | None -> source)
;;

type compaction_snapshot_item =
  { id : string
  ; keeper_id : string
  ; ts_iso : string
  ; ts_unix : float option
  ; trace_id : string option
  ; keeper_turn_id : int option
  ; source : string
  ; trigger : string
  ; runtime_id : string option
  ; before_tokens : int option
  ; after_tokens : int option
  ; saved_tokens : int option
  ; compaction_id : string option
  ; compaction_source : string option
  ; compaction_outcome : string option
  ; cause : string option
  ; status : string
  ; links : Yojson.Safe.t
  ; exact_evidence : Yojson.Safe.t option
  ; reinjection_observation : Yojson.Safe.t
  }

let compaction_snapshot_item_json (item : compaction_snapshot_item) =
  `Assoc
    [ "id", `String item.id
    ; "keeper", `String item.keeper_id
    ; "ts_iso", `String item.ts_iso
    ; "ts_unix", Json_util.float_opt_to_json item.ts_unix
    ; "trace_id", Json_util.string_opt_to_json item.trace_id
    ; "keeper_turn_id", Json_util.int_opt_to_json item.keeper_turn_id
    ; "source", `String item.source
    ; "trigger", `String item.trigger
    ; "runtime_id", Json_util.string_opt_to_json item.runtime_id
    ; ( "display_runtime"
      , `String
          (compaction_snapshot_display_runtime
             ~source:item.source
             ~runtime_id:item.runtime_id
             ~compaction_source:item.compaction_source)
      )
    ; "before_tokens", Json_util.int_opt_to_json item.before_tokens
    ; "after_tokens", Json_util.int_opt_to_json item.after_tokens
    ; "saved_tokens", Json_util.int_opt_to_json item.saved_tokens
    ; "compaction_id", Json_util.string_opt_to_json item.compaction_id
    ; "compaction_source", Json_util.string_opt_to_json item.compaction_source
    ; "compaction_outcome", Json_util.string_opt_to_json item.compaction_outcome
    ; "cause", Json_util.string_opt_to_json item.cause
    ; "status", `String item.status
    ; "links", item.links
    ; ( "exact_evidence"
      , match item.exact_evidence with
        | Some evidence -> evidence
        | None -> `Null )
    ; "reinjection_observation", item.reinjection_observation
    ]
;;

type compaction_reinjection_state =
  | Not_linked
  | Awaiting_load
  | Checkpoint_not_loaded
  | Loaded_not_injected
  | Reinserted
  | Sequence_incomplete
  | Sequence_reversed
  | Duplicate_receipt

let compaction_reinjection_state_to_string = function
  | Not_linked -> "not_linked"
  | Awaiting_load -> "awaiting_load"
  | Checkpoint_not_loaded -> "checkpoint_not_loaded"
  | Loaded_not_injected -> "loaded_not_injected"
  | Reinserted -> "reinserted"
  | Sequence_incomplete -> "sequence_incomplete"
  | Sequence_reversed -> "sequence_reversed"
  | Duplicate_receipt -> "duplicate_receipt"
;;

let compaction_not_linked_observation_json =
  `Assoc
    [ "state", `String (compaction_reinjection_state_to_string Not_linked)
    ; "keeper_turn_id", `Null
    ; "checkpoint_loaded_receipts", `Int 0
    ; "context_injected_receipts", `Int 0
    ]
;;

type compaction_receipt_kind =
  | Checkpoint_load of bool option
  | Context_injection

type compaction_receipt =
  { index : int
  ; keeper_turn_id : int option
  ; kind : compaction_receipt_kind
  }

let compaction_reinjection_observation_json ~manifest_rows ~row_index row =
  let observation state ?keeper_turn_id ~loads ~injections () =
    `Assoc
      [ "state", `String (compaction_reinjection_state_to_string state)
      ; "keeper_turn_id", Json_util.int_opt_to_json keeper_turn_id
      ; "checkpoint_loaded_receipts", `Int loads
      ; "context_injected_receipts", `Int injections
      ]
  in
  match row.Keeper_runtime_manifest.links.checkpoint_path with
  | None -> compaction_not_linked_observation_json
  | Some checkpoint_path ->
    let receipts =
      manifest_rows
      |> List.filter_map (fun (index, (candidate : Keeper_runtime_manifest.t)) ->
        if index <= row_index
           || not (String.equal candidate.Keeper_runtime_manifest.trace_id row.trace_id)
           || candidate.links.checkpoint_path <> Some checkpoint_path
        then None
        else
          match candidate.event with
          | Keeper_runtime_manifest.Checkpoint_loaded ->
            Some
              { index
              ; keeper_turn_id = candidate.keeper_turn_id
              ; kind =
                  Checkpoint_load
                    (Json_util.get_bool
                       candidate.decision
                       "loaded_checkpoint_present")
              }
          | Keeper_runtime_manifest.Context_injected ->
            Some
              { index
              ; keeper_turn_id = candidate.keeper_turn_id
              ; kind = Context_injection
              }
          | _ -> None)
    in
    (match receipts with
     | [] -> observation Awaiting_load ~loads:0 ~injections:0 ()
     | first :: _ ->
       let turn_receipts =
         List.filter
           (fun receipt -> receipt.keeper_turn_id = first.keeper_turn_id)
           receipts
       in
       let loads, injections =
         List.fold_left
           (fun (loads, injections) receipt ->
             match receipt.kind with
             | Checkpoint_load _ -> receipt :: loads, injections
             | Context_injection -> loads, receipt :: injections)
           ([], [])
           turn_receipts
       in
       let state =
         match loads, injections, first.keeper_turn_id with
         | _, _, None -> Sequence_incomplete
         | _ :: _ :: _, _, _ | _, _ :: _ :: _, _ -> Duplicate_receipt
         | [ { kind = Checkpoint_load (Some true); index = load_index; _ } ]
         , [ { index = injection_index; _ } ]
         , _ ->
           if load_index < injection_index then Reinserted else Sequence_reversed
         | [ { kind = Checkpoint_load (Some true); _ } ], [], _ ->
           Loaded_not_injected
         | [ { kind = Checkpoint_load (Some false); _ } ], [], _ ->
           Checkpoint_not_loaded
         | _ -> Sequence_incomplete
       in
       observation
         state
         ?keeper_turn_id:first.keeper_turn_id
         ~loads:(List.length loads)
         ~injections:(List.length injections)
         ())
;;

let compaction_saved_tokens before_tokens after_tokens =
  match before_tokens, after_tokens with
  | Some before_tokens, Some after_tokens -> Some (max 0 (before_tokens - after_tokens))
  | _ -> None
;;

let compaction_event_bus_snapshot_json ~keeper_id (row : Keeper_runtime_manifest.t) =
  match Json_util.assoc_member_opt "last_compaction" row.decision with
  | Some (`Assoc _ as compaction) ->
    let before_tokens = Json_util.get_int compaction "before_tokens" in
    let after_tokens = Json_util.get_int compaction "after_tokens" in
    let saved_tokens =
      match Json_util.get_int compaction "tokens_freed" with
      | Some tokens -> Some tokens
      | None -> compaction_saved_tokens before_tokens after_tokens
    in
    let trigger =
      Json_util.get_string compaction "phase_hint"
      (* DET-OK: manifest projection fallback only; a missing phase hint maps to
         a stable UI label and does not drive keeper policy. *)
      |> Option.value ~default:"event_bus_context_compacted"
    in
    Some
      (compaction_snapshot_item_json
         { id =
             Printf.sprintf "manifest:%s:%s:%s" row.trace_id
               (Keeper_runtime_manifest.event_kind_to_string row.event)
               row.ts
         ; keeper_id
         ; ts_iso = row.ts
         ; ts_unix = Masc_domain.parse_iso8601_opt row.ts
         ; trace_id = Some row.trace_id
         ; keeper_turn_id = row.keeper_turn_id
         ; source = "runtime_manifest"
         ; trigger
         ; runtime_id = row.runtime_id
         ; before_tokens
         ; after_tokens
         ; saved_tokens
         ; compaction_id = compaction_snapshot_clock_string row.decision "compaction_id"
         ; compaction_source =
             compaction_snapshot_clock_string row.decision "compaction_source"
         ; compaction_outcome = None
         ; cause = None
         ; status = row.status
         ; links = compaction_snapshot_links_json row.links
         ; exact_evidence = None
         ; reinjection_observation = compaction_not_linked_observation_json
         })
  | _ ->
    (match Json_util.get_int row.decision "context_compacted_count" with
     | Some count when count > 0 ->
       let compaction_source =
         compaction_snapshot_clock_string row.decision "compaction_source"
       in
       Some
         (compaction_snapshot_item_json
            { id =
                Printf.sprintf "manifest:%s:%s:%s" row.trace_id
                  (Keeper_runtime_manifest.event_kind_to_string row.event)
                  row.ts
            ; keeper_id
            ; ts_iso = row.ts
            ; ts_unix = Masc_domain.parse_iso8601_opt row.ts
            ; trace_id = Some row.trace_id
            ; keeper_turn_id = row.keeper_turn_id
            ; source = "runtime_manifest"
            ; trigger =
                Option.value
                  ~default:"event_bus_context_compacted"
                  compaction_source
            ; runtime_id = row.runtime_id
            ; before_tokens = None
            ; after_tokens = None
            ; saved_tokens = None
            ; compaction_id = compaction_snapshot_clock_string row.decision "compaction_id"
            ; compaction_source
            ; compaction_outcome = None
            ; cause = None
            ; status = row.status
            ; links = compaction_snapshot_links_json row.links
            ; exact_evidence = None
            ; reinjection_observation = compaction_not_linked_observation_json
            })
     | Some _ | None -> None)
;;

let compaction_context_snapshot_json
      ~keeper_id
      ~manifest_rows
      ~row_index
      (row : Keeper_runtime_manifest.t)
  =
  (* TEL-OK: read-only dashboard projection; compaction telemetry is emitted by
     the keeper runtime/event bridge that produced the manifest row. *)
  if Keeper_runtime_manifest.status_is_skipped row
  then None
  else
    let before_tokens = Json_util.get_int row.decision "before_tokens" in
    let after_tokens = Json_util.get_int row.decision "after_tokens" in
    let compaction_source =
      compaction_snapshot_clock_string row.decision "compaction_source"
    in
    Some
      (compaction_snapshot_item_json
         { id =
             Printf.sprintf "manifest:%s:%s:%s" row.trace_id
               (Keeper_runtime_manifest.event_kind_to_string row.event)
               row.ts
         ; keeper_id
         ; ts_iso = row.ts
         ; ts_unix = Masc_domain.parse_iso8601_opt row.ts
         ; trace_id = Some row.trace_id
         ; keeper_turn_id = row.keeper_turn_id
         ; source = "runtime_manifest"
         (* DET-OK: manifest projection fallback only; a missing source maps to
            a stable UI label and does not drive keeper policy. *)
         ; trigger = Option.value ~default:"context_compacted" compaction_source
         ; runtime_id = row.runtime_id
         ; before_tokens
         ; after_tokens
         ; saved_tokens = compaction_saved_tokens before_tokens after_tokens
         ; compaction_id = compaction_snapshot_clock_string row.decision "compaction_id"
         ; compaction_source
         ; compaction_outcome =
             Json_util.get_string
               row.decision
               Keeper_runtime_manifest.compaction_outcome_key
         ; cause = Json_util.get_string row.decision "error"
         ; status = row.status
         ; links = compaction_snapshot_links_json row.links
         ; exact_evidence =
             Json_util.assoc_member_opt
               Keeper_compaction_evidence.exact_evidence_key
               row.decision
         ; reinjection_observation =
             compaction_reinjection_observation_json
               ~manifest_rows
               ~row_index
               row
         })
;;

let compaction_snapshot_of_manifest_row
      ~keeper_id
      ~manifest_rows
      (row_index, (row : Keeper_runtime_manifest.t))
  =
  match row.event with
  | Keeper_runtime_manifest.Event_bus_correlated ->
    compaction_event_bus_snapshot_json ~keeper_id row
  | Keeper_runtime_manifest.Context_compacted ->
    compaction_context_snapshot_json ~keeper_id ~manifest_rows ~row_index row
  | _ -> None
;;

let compaction_snapshot_manifest_sort_value (row : Keeper_runtime_manifest.t) =
  match Masc_domain.parse_iso8601_opt row.ts with
  | Some ts -> ts
  (* DET-OK: dashboard projection only. A malformed manifest timestamp is not
     used for keeper policy; sorting it last keeps the response deterministic
     while the row-level read_errors surface malformed JSON/shape issues. *)
  | None -> 0.0
;;

let keeper_meta_compaction_snapshot_json ~config ~keeper_id =
  match Keeper_meta_store.read_meta config keeper_id with
  | Ok (Some meta) ->
    let rt = meta.runtime.compaction_rt in
    if rt.count <= 0 || rt.last_ts <= 0.0
    then None, []
    else
      let before_tokens = Some rt.last_before_tokens in
      let after_tokens = Some rt.last_after_tokens in
      ( Some
          (compaction_snapshot_item_json
             { id = "keeper_meta:last_compaction"
             ; keeper_id
             ; ts_iso = Masc_domain.iso8601_of_unix_seconds rt.last_ts
             ; ts_unix = Some rt.last_ts
             ; trace_id = None
             ; keeper_turn_id = None
             ; source = "keeper_meta"
             ; trigger =
                 Keeper_meta_contract.compaction_runtime_decision_to_string
                   rt.last_decision
             ; runtime_id = None
             ; before_tokens
             ; after_tokens
             ; saved_tokens = compaction_saved_tokens before_tokens after_tokens
             ; compaction_id = None
             ; compaction_source = None
             ; compaction_outcome = None
             ; cause = None
             ; status = "latest"
             ; links = `Assoc []
             ; exact_evidence = None
             ; reinjection_observation = compaction_not_linked_observation_json
             })
      , [] )
  | Ok None -> None, []
  | Error msg ->
    ( None
    , [ compaction_snapshot_read_error
          ~scope:("keeper_meta:" ^ keeper_id)
          ~error:msg
      ] )
;;

let compaction_snapshots_json ~config ~keeper_id ~limit =
  let limit = limit |> max 1 |> min compaction_snapshot_max_limit in
  let manifest_base_dir =
    Keeper_runtime_manifest.base_dir config ~keeper_name:keeper_id
  in
  let manifest_paths, path_read_errors, path_scan_truncated =
    runtime_manifest_paths ~config ~keeper_id ~limit
  in
  let rows_and_errors =
    List.map (read_runtime_manifest_rows ~base_dir:manifest_base_dir) manifest_paths
  in
  let manifest_rows =
    rows_and_errors
    |> List.rev
    |> List.map fst
    |> List.concat
  in
  let manifest_read_errors =
    path_read_errors
    @ (List.map snd rows_and_errors |> List.concat)
  in
  let scan_truncated = path_scan_truncated in
  let manifest_items =
    let manifest_rows = List.mapi (fun index row -> index, row) manifest_rows in
    manifest_rows
    |> List.sort (fun a b ->
      Float.compare
        (compaction_snapshot_manifest_sort_value (snd b))
        (compaction_snapshot_manifest_sort_value (snd a)))
    |> List.filter_map
         (compaction_snapshot_of_manifest_row ~keeper_id ~manifest_rows)
    |> compaction_snapshot_take limit
  in
  let items, read_errors =
    match manifest_items with
    | [] ->
      let meta_item, meta_read_errors =
        keeper_meta_compaction_snapshot_json ~config ~keeper_id
      in
      (match meta_item with
       | Some item -> [ item ], manifest_read_errors @ meta_read_errors
       | None -> [], manifest_read_errors @ meta_read_errors)
    | _ -> manifest_items, manifest_read_errors
  in
  log_compaction_snapshot_read_errors ~keeper_id read_errors;
  `Assoc
    [ "schema", `String "keeper.compaction_snapshots.v1"
    ; "keeper", `String keeper_id
    ; "source", `String "runtime_manifest|keeper_meta"
    ; "producer", `String "keeper_runtime_manifest|keeper_meta_store"
    ; "limit", `Int limit
    ; "count", `Int (List.length items)
    ; "read_error_count", `Int (List.length read_errors)
    ; "read_errors", compaction_snapshot_read_errors_json read_errors
    ; "scan_truncated", `Bool scan_truncated
    ; "items", `List items
    ]
;;

type compaction_snapshot_cache_entry =
  { body : Yojson.Safe.t
  ; refreshed_at : float
  }

let compaction_snapshot_cache :
    (string, compaction_snapshot_cache_entry) Hashtbl.t =
  Hashtbl.create 16
;;

(* [true] means a force-refresh arrived while the current scan was running, so
   completion must schedule exactly one trailing scan. *)
let compaction_snapshot_refreshes : (string, bool) Hashtbl.t = Hashtbl.create 16
let compaction_snapshot_cache_mu = Stdlib.Mutex.create ()
let compaction_snapshot_cache_max_entries = 128

let with_compaction_snapshot_cache_lock f =
  Stdlib.Mutex.lock compaction_snapshot_cache_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock compaction_snapshot_cache_mu)
    f
;;

let compaction_snapshot_cache_key config keeper_id limit =
  String.concat "\x00" [ config.Workspace.base_path; keeper_id; string_of_int limit ]
;;

let compaction_snapshot_with_hydration_status status = function
  | `Assoc fields ->
    `Assoc
      (("hydration_status", `String status)
       :: List.remove_assoc "hydration_status" fields)
  | body -> body
;;

let compaction_snapshot_empty_json ~keeper_id ~limit ~status ~read_errors =
  `Assoc
    [ "schema", `String "keeper.compaction_snapshots.v1"
    ; "keeper", `String keeper_id
    ; "source", `String "runtime_manifest|keeper_meta"
    ; "producer", `String "keeper_runtime_manifest|keeper_meta_store"
    ; "limit", `Int limit
    ; "count", `Int 0
    ; "read_error_count", `Int (List.length read_errors)
    ; ( "read_errors"
      , `List
          (List.map
             (fun error ->
               `Assoc
                 [ "scope", `String "background_hydration"
                 ; "error", `String error
                 ])
             read_errors) )
    ; "scan_truncated", `Bool false
    ; "items", `List []
    ; "hydration_status", `String status
    ]
;;

let broadcast_compaction_snapshot_refresh ~keeper_id ~status =
  match
    Sse.broadcast
      (`Assoc
         [ "type", `String "keeper_compaction_snapshots_changed"
         ; "keeper_name", `String keeper_id
         ; "status", `String status
         ; "ts_unix", `Float (Time_compat.now ())
         ])
  with
  | () -> ()
  | exception Eio.Cancel.Cancelled _ -> ()
  | exception exn ->
    Log.Dashboard.warn
      "keeper compaction snapshot completion broadcast failed: keeper=%s status=%s error=%s"
      keeper_id status (Printexc.to_string exn)
;;

let finish_compaction_snapshot_refresh key ~keeper_id body =
  let refresh_again =
    with_compaction_snapshot_cache_lock (fun () ->
      let refresh_again =
        match Hashtbl.find_opt compaction_snapshot_refreshes key with
        | Some pending -> pending
        | None ->
          Log.Dashboard.warn
            "keeper compaction snapshot refresh completed without an in-flight marker: keeper=%s"
            keeper_id;
          false
      in
      if not (Hashtbl.mem compaction_snapshot_cache key)
      then
        Server_utils.evict_oldest_if_full
          ~max_entries:compaction_snapshot_cache_max_entries
          ~age_of:(fun entry -> entry.refreshed_at)
          compaction_snapshot_cache;
      Hashtbl.replace compaction_snapshot_cache key
        { body; refreshed_at = Time_compat.now () };
      Hashtbl.remove compaction_snapshot_refreshes key;
      refresh_again)
  in
  let status =
    match body with
    | `Assoc fields ->
      (match List.assoc_opt "hydration_status" fields with
       | Some (`String value) -> value
       | _ -> "failed")
    | _ -> "failed"
  in
  broadcast_compaction_snapshot_refresh ~keeper_id ~status;
  refresh_again
;;

let rec start_compaction_snapshot_refresh
    ~config
    ~keeper_id
    ~limit
    ~force_refresh
    key
  =
  let admitted =
    with_compaction_snapshot_cache_lock (fun () ->
      if Hashtbl.mem compaction_snapshot_refreshes key
      then begin
        if force_refresh
        then Hashtbl.replace compaction_snapshot_refreshes key true;
        false
      end
      else begin
        Hashtbl.add compaction_snapshot_refreshes key false;
        true
      end)
  in
  if not admitted
  then true
  else
    match Eio_context.get_switch_opt () with
    | None ->
      with_compaction_snapshot_cache_lock (fun () ->
        Hashtbl.remove compaction_snapshot_refreshes key);
      false
    | Some sw ->
      let run () =
        let finish body =
          let refresh_again =
            finish_compaction_snapshot_refresh key ~keeper_id body
          in
          if refresh_again
          then
            ignore
              (start_compaction_snapshot_refresh ~config ~keeper_id ~limit
                 ~force_refresh:false key)
        in
        match
          Domain_pool_ref.submit_io_or_inline (fun () ->
            compaction_snapshots_json ~config ~keeper_id ~limit)
        with
        | body ->
          finish
            (compaction_snapshot_with_hydration_status "ready" body)
        | exception Eio.Cancel.Cancelled _ ->
          with_compaction_snapshot_cache_lock (fun () ->
            Hashtbl.remove compaction_snapshot_refreshes key)
        | exception exn ->
          let error = Printexc.to_string exn in
          Log.Dashboard.warn
            "keeper compaction snapshot hydration failed: keeper=%s error=%s"
            keeper_id error;
          finish
            (compaction_snapshot_empty_json ~keeper_id ~limit ~status:"failed"
               ~read_errors:[ error ])
      in
      (match Eio.Fiber.fork ~sw run with
       | () -> true
       | exception exn ->
         with_compaction_snapshot_cache_lock (fun () ->
           Hashtbl.remove compaction_snapshot_refreshes key);
         Log.Dashboard.warn
           "keeper compaction snapshot background fork failed: keeper=%s error=%s"
           keeper_id (Printexc.to_string exn);
         false)
;;

let cached_compaction_snapshots_json
    ~config
    ~keeper_id
    ~limit
    ~force_refresh
  =
  let limit = limit |> max 1 |> min compaction_snapshot_max_limit in
  let key = compaction_snapshot_cache_key config keeper_id limit in
  let now = Time_compat.now () in
  let cached =
    with_compaction_snapshot_cache_lock (fun () ->
      Hashtbl.find_opt compaction_snapshot_cache key)
  in
  let stale =
    match cached with
    | None -> true
    | Some entry -> now -. entry.refreshed_at >= keeper_hot_path_cache_ttl_s
  in
  let scheduled =
    if force_refresh || stale
    then
      start_compaction_snapshot_refresh ~config ~keeper_id ~limit ~force_refresh
        key
    else true
  in
  match cached with
  | Some entry -> entry.body
  | None when scheduled ->
    compaction_snapshot_empty_json ~keeper_id ~limit ~status:"warming"
      ~read_errors:[]
  | None ->
    compaction_snapshot_empty_json ~keeper_id ~limit ~status:"failed"
      ~read_errors:[ "background refresh context unavailable" ]
;;

let cached_keeper_runtime_trace_json config name ?trace_id ?turn_id ~limit () =
  let cache_key =
    keeper_runtime_trace_cache_key config name ?trace_id ?turn_id ~limit ()
  in
  let cached =
    Dashboard_cache.get_or_compute cache_key ~ttl:keeper_hot_path_cache_ttl_s (fun () ->
      let status, body =
        Domain_pool_ref.submit_io_or_inline (fun () ->
          keeper_runtime_trace_json config name ?trace_id ?turn_id ~limit ())
      in
      `Assoc
        [ ( "status"
          , `String
              (match status with
               | `OK -> "ok"
               | `Not_found -> "not_found") )
        ; "body", body
        ])
  in
  match cached with
  | `Assoc fields ->
    let status =
      match List.assoc_opt "status" fields with
      | Some (`String "not_found") -> `Not_found
      | _ -> `OK
    in
    let body = cached_assoc_body_or_self cached fields in
    status, body
  | other -> `OK, other
;;

let cached_keeper_config_json config name =
  let cache_key = keeper_config_cache_key config name in
  let cached =
    Dashboard_cache.get_or_compute cache_key ~ttl:keeper_hot_path_cache_ttl_s (fun () ->
      let status, body =
        Domain_pool_ref.submit_io_or_inline (fun () ->
          Dashboard_http_keeper.keeper_config_json config name)
      in
      `Assoc
        [ ( "status"
          , `String
              (match status with
               | `OK -> "ok"
               | `Not_found -> "not_found") )
        ; "body", body
        ])
  in
  match cached with
  | `Assoc fields ->
    let status =
      match List.assoc_opt "status" fields with
      | Some (`String "not_found") -> `Not_found
      | _ -> `OK
    in
    let body = cached_assoc_body_or_self cached fields in
    status, body
  | other -> `OK, other
;;

(* Dashboard hydration fetches every keeper's chat history concurrently on
   page load. The uncached build ran inline on the main Eio domain at
   ~1-2 s per keeper (chat tail parse + per-trace trajectory and
   internal-history tail reads + redaction), so a 16-keeper hydration
   serialized 15 s+ of main-domain work and pushed unrelated HTTP/WS
   responses past the dashboard's 35 s client timeout.

   Freshness lives in the cached VALUE, not the key: the key space is
   exactly one entry per (validated) keeper name, so append bursts can
   never grow cache cardinality. Each entry stamps the chat file's
   (mtime, size) observed by its compute; a request whose current stat
   differs invalidates the entry and recomputes, so a newly persisted
   message is served fresh on the next request without an invalidation
   hook at every append site. Enrichment-only drift (trajectory/meta
   appends with no chat append) is bounded by the TTL, the same
   staleness contract as the cached trajectory handler above. *)
let keeper_chat_history_freshness config name =
  let base_dir = (config : Workspace.config).base_path in
  let path = Keeper_chat_store.chat_path ~base_dir ~keeper_name:name in
  (* Sound-partial: a missing chat file is its own state ("absent"),
     never conflated with a real (mtime, size) pair. A half-readable
     stat (racing writer) also maps to "absent", which only costs a
     recompute on the next request. *)
  let chat_stamp =
    match Fs_compat.file_mtime path, Fs_compat.file_size path with
    | Some mtime, Some size -> Printf.sprintf "%h:%d" mtime size
    | Some _, None | None, Some _ | None, None -> "absent"
  in
  (* Autonomous turns never touch the chat file, so the chat stat alone
     would pin a stale body for the whole TTL. Raw trace creation and the
     authoritative turn-record append are separate commits: directory mtime
     observes the former but cannot prove the latter. Fingerprint the newest
     physical turn-record row as well, so a record appended after a racing
     cache compute invalidates that value on the next request. *)
  let trace_stamp =
    match Fs_compat.file_mtime (Keeper_types_support.keeper_raw_trace_dir config name) with
    | Some mtime -> Printf.sprintf "%h" mtime
    | None -> "absent"
  in
  let turn_record_stamp =
    let store = Keeper_types_support.keeper_turn_record_store config name in
    match
      Dated_jsonl.find_latest_entry_result store (fun entry -> Some entry)
    with
    | Error error -> "error:" ^ Dated_jsonl.read_error_to_string error
    | Ok None -> "absent"
    | Ok (Some (Dated_jsonl.Parsed json)) ->
      Yojson.Safe.to_string json |> Digest.string |> Digest.to_hex
    | Ok (Some (Dated_jsonl.Malformed_json { path; line_number; detail })) ->
      Printf.sprintf "malformed:%s:%s:%s" path
        (Option.fold ~none:"unknown" ~some:string_of_int line_number)
        detail
  in
  Printf.sprintf "%s|%s|%s" chat_stamp trace_stamp turn_record_stamp
;;

(* The canonical autonomous User/Assistant/Tool exchange lives in the Keeper's
   AGENT_CORE checkpoint, not as duplicate chat-store rows. This read projection uses
   typed turn identity only for stable dashboard grouping and exact raw-trace
   lookup; it is not the Keeper's semantic continuity mechanism. Final text
   and work trace come from the same exact AGENT_CORE run. The [id] is required:
   the dashboard history schema drops any row without one. Its value is a pure
   schema satisfier -- the dashboard re-mints its entry id from
   [autonomous_turn.turn_id] and never reads this field. *)
let autonomous_turn_json (turn : Keeper_autonomous_turn_source.turn) =
  let trace_fields =
    match turn.trace with
    | [] -> []
    | trace ->
      [ ( "blocks"
        , Keeper_chat_blocks.blocks_to_yojson
            [ Keeper_chat_blocks.Trace { trace; omitted = 0 } ] ) ]
  in
  `Assoc
    ([ "id", `String ("autonomous:" ^ turn.turn_id)
     ; "role", `String "assistant"
     ; "ts", `Float turn.started_at
     ; ( "content"
       , match turn.final_text with
         | Some text -> `String text
         | None -> `Null )
     ; "autonomous_turn", `Assoc [ "turn_id", `String turn.turn_id ]
     ]
     @ trace_fields)
;;

let keeper_chat_trace_blocks config name =
  match Keeper_meta_store.read_meta config name with
  | Ok (Some m) ->
    Some
      (Server_dashboard_http_keeper_api_trace.chat_trace_block_by_turn_ref
         ~max_lines:trajectory_max_limit
         ~config
         ~keeper_name:name
         ~allowed_trace_ids:(keeper_chat_allowed_trace_ids m))
  | Ok None -> None
  | Error err ->
    Log.Keeper.warn
      "dashboard keeper chat history: read_meta failed for %s; trace enrichment skipped: %s"
      name
      err;
    None
;;

let keeper_chat_history_json config name =
  let base_dir = (config : Workspace.config).base_path in
  let messages = Keeper_chat_store.load ~base_dir ~keeper_name:name in
  let trace_block_by_turn_ref = keeper_chat_trace_blocks config name in
  let chat_rows = Keeper_chat_store.to_json_array ~base_dir ?trace_block_by_turn_ref messages in
  (* Appended, not merged by timestamp: the client already sorts the whole
     transcript by [ts] and breaks ties by original index, and rows the chat
     store persisted without a [ts] must keep their relative order rather
     than be repositioned by a sort here. *)
  let autonomous_rows =
    Keeper_autonomous_turn_source.load_recent ~config ~keeper_name:name ()
    |> List.map autonomous_turn_json
  in
  match autonomous_rows, chat_rows with
  | [], _ -> chat_rows
  | _ :: _, `List rows -> `List (rows @ autonomous_rows)
  | _ :: _, other ->
    Log.Keeper.warn
      "dashboard keeper chat history: chat store for %s did not emit an array; %d \
       autonomous turn(s) omitted"
      name
      (List.length autonomous_rows);
    other
;;

(* Direct-conversation rows older than [before], one [Keeper_chat_store] window
   at a time. Separate from [keeper_chat_history_json] rather than a mode of it,
   because the two answer different questions:

   - /chat/history is the transcript: the tail window plus every autonomous turn
     the retention root still holds ([Keeper_raw_trace_retention.history_limit]).
   - this is the walk backwards through direct rows the tail window evicted.
     Autonomous turns are excluded on purpose -- they are bounded by retention,
     not by this window, so the first transcript fetch already carried every one
     that exists. Repeating them per page would duplicate rows the client holds.

   [next_before] is the cursor for the following page, computed here so the
   caller does not reimplement the rule: the oldest [ts] among the returned
   rows, or [null] for an empty page. The fold tolerates a row carrying no [ts]
   by skipping it, which today cannot happen -- [Keeper_chat_store.parse_line]
   maps an absent [ts] to [Some 0.0] rather than [None] (see the store's own
   [quiet_line_ts], which maps the same absence to [None]). That disagreement
   is tracked separately; this fold is written against the documented type so
   it stays correct when the store's decoder is repaired.

   Uncached: pages are user-initiated and [load_page] is already bounded I/O
   (binary-search probes plus one window slice). A cache keyed by cursor would
   add entries per click without a measured hot path asking for it. *)
let keeper_chat_history_page_json config name ~before =
  let base_dir = (config : Workspace.config).base_path in
  let { Keeper_chat_store.messages; has_more } =
    Keeper_chat_store.load_page ~base_dir ~keeper_name:name ?before ()
  in
  let trace_block_by_turn_ref = keeper_chat_trace_blocks config name in
  let next_before =
    List.fold_left
      (fun acc ({ ts; _ } : Keeper_chat_store.chat_message) ->
        match ts, acc with
        | None, _ -> acc
        | Some t, None -> Some t
        | Some t, Some a -> Some (Float.min a t))
      None
      messages
  in
  `Assoc
    [ "schema", `String "masc.keeper_chat_history.page.v1"
    ; ( "messages"
      , Keeper_chat_store.to_json_array ~base_dir ?trace_block_by_turn_ref messages )
    ; "has_more", `Bool has_more
    ; "next_before", (match next_before with Some t -> `Float t | None -> `Null)
    ]
;;

let cached_keeper_chat_history_json config name =
  let cache_key =
    Printf.sprintf "keeper:chat-history:%s:%s"
      (Workspace.masc_root_dir config) name
  in
  let current = keeper_chat_history_freshness config name in
  (match Dashboard_cache.peek cache_key with
   | Some (`Assoc fields) ->
     (match List.assoc_opt "freshness" fields with
      | Some (`String stamped) when String.equal stamped current -> ()
      | Some _ | None -> Dashboard_cache.invalidate cache_key)
   | Some _ -> Dashboard_cache.invalidate cache_key
   | None -> ());
  let cached =
    Dashboard_cache.get_or_compute cache_key ~ttl:keeper_hot_path_cache_ttl_s
      (fun () ->
        Domain_pool_ref.submit_io_or_inline (fun () ->
          (* Stamp the stat observed by THIS compute (stat before load):
             an append racing the load makes the data newer than the
             stamp, which the next request's stat comparison detects and
             recomputes — never silently stale. *)
          let stamped = keeper_chat_history_freshness config name in
          `Assoc
            [ ("freshness", `String stamped)
            ; ("body", keeper_chat_history_json config name)
            ]))
  in
  match cached with
  | `Assoc fields ->
    (match List.assoc_opt "body" fields with
     | Some body -> body
     | None -> cached)
  | other -> other
;;

let offline_keeper_composite_json ~config name (m : Keeper_meta_contract.keeper_meta) =
  let now = Time_compat.now () in
  let phase = if m.paused then "paused" else "offline" in
  let reason =
    if m.paused then "paused_without_registry_entry" else "registry_absent"
  in
  let secret_projection =
    Keeper_secret_projection.dashboard_status_json
      ~base_path:config.Workspace.base_path
      ~keeper_name:name
  in
  `Assoc
    [ "keeper", `String name
    ; "correlation_id", `String (Printf.sprintf "keeper:%s:offline" name)
    ; "run_id", `String (Printf.sprintf "keeper:%s:offline" name)
    ; "ts", `Float now
    ; "phase", `String phase
    ; "turn_phase", `String "idle"
    ; "decision", `Assoc [ "stage", `String "idle" ]
    ; "runtime", `Assoc [ "state", `String "offline" ]
    ; "compaction", `Assoc [ "stage", `String "accumulating" ]
    ; "measurement", `Assoc [ "captured", `Bool false ]
    ; ( "invariants"
      , `Assoc
          [ "phase_turn_alignment", `Bool true
          ; "no_runtime_before_measurement", `Bool true
          ; "compaction_atomicity", `Bool true
          ; "event_priority_monotone", `Bool true
          ; "phase_derivation_agreement", `Bool true
          ] )
    ; "is_live", `Bool false
    ; "live_turn", `Null
    ; "last_outcome", `Null
    ; "idle_seconds", `Int 0
    ; "last_turn_ts", `Float m.runtime.usage.last_turn_ts
    ; "fsm_guard_violations", `Int 0
    ; "fsm_guard_violation_breakdown", `List []
    ; "secret_projection", secret_projection
    ; ( "runtime_attention"
      , `Assoc
          [ "state", `String phase
          ; "needs_attention", `Bool true
          ; "blocked", `Bool false
          ; "fiber_stop_requested", `Bool false
          ; "reason", `String reason
          ; "raw_phase", `String phase
          ; "is_live", `Bool false
          ; "source", `String "offline_composite_fallback"
          ; "execution_current", `Bool false
          ; "stale_execution_receipt", `Bool false
          ; "live_turn_started_at", `Null
          ; "live_turn_last_progress_at", `Null
          ] )
    ; "recommended_actions", `List []
    ]
;;

let keeper_composite_status_to_string = function
  | `OK -> "ok"
  | `Not_found -> "not_found"
  | `Internal_server_error -> "internal_server_error"
;;

let keeper_composite_status_of_string_opt = function
  | "ok" -> Some `OK
  | "not_found" -> Some `Not_found
  | "internal_server_error" -> Some `Internal_server_error
  | _ -> None
;;

let cached_keeper_composite_json config name =
  let cache_key = keeper_composite_cache_key config name in
  let cached =
    Dashboard_cache.get_or_compute cache_key ~ttl:keeper_composite_cache_ttl_s (fun () ->
      let status, body =
        Domain_pool_ref.submit_io_or_inline (fun () ->
          match Keeper_registry.get ~base_path:config.base_path name with
          | Some entry ->
            `OK, Server_dashboard_http.dashboard_keeper_composite_json ~config entry
          | None ->
            (match Keeper_meta_store.read_meta config name with
             | Error e -> `Internal_server_error, error_json e
             | Ok None ->
               ( `Not_found
               , error_json (Printf.sprintf "keeper %S not found" name) )
             | Ok (Some m) -> `OK, offline_keeper_composite_json ~config name m))
      in
      `Assoc
        [ "status", `String (keeper_composite_status_to_string status)
        ; "body", body
        ])
  in
  match cached with
  | `Assoc fields ->
    let status =
      match List.assoc_opt "status" fields with
      | Some (`String value) ->
        (match keeper_composite_status_of_string_opt value with
         | Some status -> status
         | None -> `Internal_server_error)
      | _ -> `Internal_server_error
    in
    let body = cached_assoc_body_or_self cached fields in
    status, body
  | other -> `OK, other
;;

let handle_keeper_get_subroutes state req request reqd =
  let req_path = Http.Request.path req in
  let prefix = keeper_api_prefix in
  let plen = String.length prefix in
  let tlen = String.length req_path in
  let ends_with suffix =
    let slen = String.length suffix in
    tlen > plen + slen
    && String.sub req_path (tlen - slen) slen = suffix
  in
  let extract_name suffix =
    let slen = String.length suffix in
    String.trim (String.sub req_path plen (tlen - plen - slen))
  in
  if ends_with keeper_suffix_github_identity then (
    let name = extract_name keeper_suffix_github_identity in
    if name = "" then
      Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
        (error_json "missing keeper name")
    else if not (Keeper_config.validate_name name) then
      Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
        (error_json (Printf.sprintf "invalid keeper name: %s" name))
    else
      let config = Mcp_server.workspace_config state in
      match Keeper_meta_store.read_meta config name with
      | Error message ->
        Server_auth.respond_json_value_with_cors ~status:`Internal_server_error request reqd
          (error_json message)
      | Ok None ->
        Server_auth.respond_json_value_with_cors ~status:`Not_found request reqd
          (error_json (Printf.sprintf "keeper %S not found" name))
      | Ok (Some _) ->
        let hostname =
          match Server_utils.query_param req "hostname" with
          | Some hostname -> hostname
          | None -> "github.com"
        in
        (match
           Keeper_github_identity.observe
             ~config
             ~keeper_name:name
             ~hostname
         with
         | Error message ->
           Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
             (error_json message)
         | Ok observation ->
           Server_auth.respond_json_value_with_cors ~status:`OK request reqd
             (Keeper_github_identity.observation_to_yojson observation)))
  else if ends_with "/digest" then (
    (* Keeper catch-up digest (since-last-seen). The enclosing keeper GET
       router leaves this route on its public-read policy; sensitive sibling
       routes declare a mandatory token-bound permission before dispatch. *)
    let name = extract_name "/digest" in
    if name = "" then
      Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
        (error_json "missing keeper name")
    else if not (Keeper_config.validate_name name) then
      Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
        (error_json (Printf.sprintf "invalid keeper name: %s" name))
    else
      match Server_utils.query_param req "since_unix" with
      | None ->
        Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
          (error_json "missing required query param: since_unix")
      | Some raw ->
        (match float_of_string_opt (String.trim raw) with
         | None ->
           Server_auth.respond_json_value_with_cors ~status:`Bad_request request
             reqd
             (error_json "since_unix must be a unix-seconds float")
         | Some since_unix ->
           let config = Mcp_server.workspace_config state in
           let digest =
             Keeper_catchup_digest.build ~base_path:config.base_path
               ~keeper_name:name ~since_unix ~now_unix:(Time_compat.now ())
           in
           Server_auth.respond_json_value_with_cors ~status:`OK request reqd
             (Keeper_catchup_digest.to_json digest)))
  else if ends_with "/chat/history/page" then
    (* Checked before "/chat/history": [ends_with] would not confuse the two,
       but keeping the longer suffix first means adding a third sub-route later
       cannot silently shadow this one. *)
    let name = extract_name "/chat/history/page" in
    if name = "" then
      Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
        (error_json "missing keeper name")
    else if not (Keeper_config.validate_name name) then
      Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
        (error_json (Printf.sprintf "invalid keeper name: %s" name))
    else (
      (* Absent [before] means the newest window -- the same rows /chat/history
         serves, minus the autonomous turns. Present but unparseable is a client
         bug, not a request for the newest page, so it is rejected rather than
         silently treated as absent. *)
      match Server_utils.query_param req "before" with
      | Some raw when float_of_string_opt (String.trim raw) = None ->
        Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
          (error_json "before must be a unix-seconds float")
      | before_raw ->
        let before =
          Option.bind before_raw (fun raw -> float_of_string_opt (String.trim raw))
        in
        let config = Mcp_server.workspace_config state in
        Server_auth.respond_json_value_with_cors ~status:`OK request reqd
          (keeper_chat_history_page_json config name ~before))
  else if ends_with "/chat/history" then
    let name = extract_name "/chat/history" in
    if name = "" then
      Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
        (error_json "missing keeper name")
    else if not (Keeper_config.validate_name name) then
      (* Reject before touching the cache: the cache key embeds the raw
         name, so unvalidated garbage names would mint unbounded
         process-global cache entries (the sibling /tool-calls route
         already validates). *)
      Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
        (error_json (Printf.sprintf "invalid keeper name: %s" name))
    else
      let config = Mcp_server.workspace_config state in
      Server_auth.respond_json_value_with_cors ~status:`OK request reqd
        (cached_keeper_chat_history_json config name)
  else if ends_with "/person-notes" then
    (* RFC-0229 P2: keeper-authored person notes for the roster pane.
       Read-only fold over the notes store; same shape as the tool
       surface ([{speaker_id, note}]). *)
    let name = extract_name "/person-notes" in
    if name = "" then
      Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
        (error_json "missing keeper name")
    else
      let base_dir = (Mcp_server.workspace_config state).base_path in
      let notes = Keeper_person_notes.notes ~base_dir ~keeper_name:name in
      Server_auth.respond_json_value_with_cors ~status:`OK request reqd
        (`List
          (List.map
             (fun (speaker_id, note) ->
               `Assoc
                 [ ("speaker_id", `String speaker_id)
                 ; ("note", `String note)
                 ])
             notes))
  else if ends_with keeper_suffix_checkpoints then
    let name = extract_name keeper_suffix_checkpoints in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
      let (st, json) = keeper_checkpoint_inventory_json (Mcp_server.workspace_config state) name in
      let status : Httpun.Status.t =
        match st with `OK -> `OK | `Not_found -> `Not_found
      in
      Http.Response.json_value ~status ~compress:true ~request:req json reqd
  else if ends_with keeper_suffix_paused_work then
    Server_dashboard_http_keeper_paused_work.handle_get state req reqd
  else if ends_with keeper_suffix_runtime_trace then
    let name = extract_name keeper_suffix_runtime_trace in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
      let trace_id = Server_utils.query_param req "trace_id" in
      let turn_id =
        match Server_utils.query_param req "turn_id" with
        | Some raw -> int_of_string_opt (String.trim raw)
        | None -> None
      in
      let limit =
        Server_utils.int_query_param req "limit" ~default:200
        |> max 1 |> min trajectory_max_limit
      in
      let st, json =
        cached_keeper_runtime_trace_json (Mcp_server.workspace_config state) name
          ?trace_id ?turn_id ~limit ()
      in
      let status : Httpun.Status.t =
        match st with `OK -> `OK | `Not_found -> `Not_found
      in
      Http.Response.json_value ~status ~compress:true ~request:req json reqd
  else if ends_with "/config" then
    let name = extract_name "/config" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
      let config = (Mcp_server.workspace_config state) in
      let (st, json) =
        cached_keeper_config_json config name
      in
      let status : Httpun.Status.t =
        match st with `OK -> `OK | `Not_found -> `Not_found
      in
      Http.Response.json_value ~status ~compress:true ~request:req json reqd
  else if ends_with "/tool-stats" then
    let name = extract_name "/tool-stats" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else if not (Keeper_config.validate_name name) then
      Http.Response.json_value ~status:`Bad_request
        (`Assoc
           [("error", `String (Printf.sprintf "invalid keeper name: %s" name))])
        reqd
    else
      let config = (Mcp_server.workspace_config state) in
      let masc_root = Workspace.masc_root_dir config in
      let window_hours =
        Server_utils.int_query_param req "window_hours"
          ~default:24
        |> max 1 |> min 168  (* 1h .. 7d *)
      in
      (* Trajectory scan + tool-stat aggregation + hourly timeline +
         coverage-gap lookup all hit disk under [masc_root]. 5-trial
         latency variance 0.16s..1.92s (mean ~1.0s) on PR #19097 HEAD
         because each miss ran on the calling fiber's Eio main domain.
         Mirrors PRs #19088 / #19097 — cache + offload, key includes the
         inputs that change the result. *)
      let cache_key =
        Printf.sprintf "keeper:tool-stats:%s:%s:%d" masc_root name window_hours
      in
      let json =
        Dashboard_cache.get_or_compute cache_key ~ttl:standard_cache_ttl_s (fun () ->
          Domain_pool_ref.submit_io_or_inline (fun () ->
            let since =
              Time_compat.now ()
              -. (float_of_int window_hours *. Masc_time_constants.hour)
            in
            let entries =
              Trajectory.read_entries_since ~masc_root ~keeper_name:name ~since
            in
            let tools = Trajectory.aggregate_tool_stats entries in
            let timeline = Trajectory.hourly_timeline entries in
            let latest_ts =
              List.fold_left
                (fun acc (entry : Trajectory.tool_call_entry) ->
                  match acc with
                  | Some ts when ts >= entry.ts -> acc
                  | _ -> Some entry.ts)
                None entries
            in
            let latest_age_s =
              match latest_ts with
              | Some ts -> Some (max 0.0 (Time_compat.now () -. ts))
              | None -> None
            in
            let dashboard_surface = "/api/v1/keepers/:name/tool-stats" in
            let coverage_gaps =
              Telemetry_coverage_gap.read_recent ~masc_root ~n:32
              |> List.filter (fun gap ->
                   String.equal
                     (Safe_ops.json_string ~default:"" "dashboard_surface" gap)
                     dashboard_surface
                   &&
                   match Safe_ops.json_string_opt "keeper_name" gap with
                   | Some keeper_name -> String.equal keeper_name name
                   | None -> true)
            in
            let latest_gap =
              List.rev coverage_gaps |> List.find_opt (fun _ -> true)
            in
            let health, stale_reason =
              match latest_gap with
              | Some gap ->
                  ( "coverage_gap",
                    Safe_ops.json_string ~default:"coverage_gap" "stale_reason" gap )
              | None -> (
                  match latest_age_s with
                  | None -> ("empty", "no_entries")
                  | Some age when age > freshness_slo_s ->
                      ("stale", "freshness_slo_exceeded")
                  | Some _ -> ("ok", ""))
            in
            `Assoc [
              ("keeper", `String name);
              ("window_hours", `Int window_hours);
              ("total_entries", `Int (List.length entries));
              ("source", `String "trajectory_tool_call");
              ( "producer",
                `String
                  "keeper_hooks_agent_core.post_tool_use|mcp_server_eio_call_tool.runtime_mcp" );
              ("durable_store", `String (Trajectory.trajectories_dir masc_root name));
              ("dashboard_surface", `String dashboard_surface);
              ("freshness_slo_s", `Float freshness_slo_s);
              ("latest_ts_unix", Json_util.float_opt_to_json latest_ts);
              ( "latest_ts_iso",
                match latest_ts with
                | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
                | None -> `Null );
              ("latest_age_s", Json_util.float_opt_to_json latest_age_s);
              ("health", `String health);
              ( "stale_reason",
                if stale_reason = "" then `Null else `String stale_reason );
              ("coverage_gaps", `List coverage_gaps);
              ("tools", `List (List.map Trajectory.tool_stat_to_json tools));
              ("timeline", `List (List.map Trajectory.hourly_bucket_to_json timeline));
            ]))
      in
      Http.Response.json_value ~compress:true ~request:req json reqd
  else if ends_with "/tool-calls" then
    let name = extract_name "/tool-calls" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else if not (Keeper_config.validate_name name) then
      Http.Response.json_value ~status:`Bad_request
        (`Assoc
           [("error", `String (Printf.sprintf "invalid keeper name: %s" name))])
        reqd
    else
      let limit =
        Server_utils.int_query_param req "limit" ~default:50
        |> max 1 |> min tool_calls_limit_max
      in
      let config = (Mcp_server.workspace_config state) in
      let masc_root = Workspace.masc_root_dir config in
      (* The per-keeper read Yojson-parsed the newest [limit * 5] rows of
         the fleet-wide dated store just to filter one keeper (~3.6 s
         measured at limit=200), inline on the main Eio domain for every
         keeper pane the dashboard hydrates — a 16-keeper cold hydration
         ran 16 identical fleet parses. Parse the fleet window once per
         TTL on the CPU pool lane (the cost is JSON parsing, not
         blocking IO) and derive each keeper's slice from it. The window
         is sized to reproduce [read_recent]'s coverage at this
         endpoint's maximum limit; deriving smaller limits from the
         wider window can only widen per-keeper coverage, never narrow
         it. TTL-bounded staleness also freezes the [latest_age_s] /
         [health] fields for up to the TTL, which is well inside the
         freshness SLO this surface reports on. *)
      let fleet_rows =
        match
          Dashboard_cache.get_or_compute
            (tool_calls_fleet_cache_key ~masc_root)
            ~ttl:keeper_hot_path_cache_ttl_s (fun () ->
              Domain_pool_ref.submit_cpu_or_inline (fun () ->
                `List
                  (Keeper_tool_call_log.read_recent_rows
                     ~n:
                       (tool_calls_limit_max
                        * Keeper_tool_call_log.read_over_scan_factor)
                     ())))
        with
        | `List rows -> rows
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _
        | `Assoc _ -> []
      in
      (* No per-keeper cache entry: the expensive part (the fleet parse)
         is behind the single fleet-rows key above, and the per-request
         remainder — filtering an in-memory window plus a bounded
         coverage-gap tail read — is milliseconds off the main domain.
         Skipping the per-(name, limit) entry keeps this route's cache
         cardinality at exactly one key and never pins a per-keeper
         response shape. *)
      let json =
        Domain_pool_ref.submit_io_or_inline (fun () ->
              let entries =
                Keeper_tool_call_log.filter_rows_for_keeper
                  ~keeper_name:name ~n:limit fleet_rows
              in
              let latest_ts =
                List.fold_left
                  (fun acc json ->
                    match Safe_ops.json_float_opt "ts" json with
                    | Some ts -> (
                        match acc with
                        | Some existing when existing >= ts -> acc
                        | Some _ | None -> Some ts)
                    | None -> acc)
                  None entries
              in
              let dashboard_surface = "/api/v1/keepers/:name/tool-calls" in
              let latest_age_s =
                match latest_ts with
                | Some ts -> Some (max 0.0 (Time_compat.now () -. ts))
                | None -> None
              in
              let coverage_gaps =
                Telemetry_coverage_gap.read_recent ~masc_root ~n:32
                |> List.filter (fun gap ->
                     String.equal "tool_call_io"
                       (Safe_ops.json_string ~default:"" "source" gap)
                     &&
                     match Safe_ops.json_string_opt "keeper_name" gap with
                     | Some keeper_name -> String.equal keeper_name name
                     | None -> true)
              in
              let latest_gap =
                List.rev coverage_gaps |> List.find_opt (fun _ -> true)
              in
              let health, stale_reason =
                match latest_gap with
                | Some gap ->
                  ( "coverage_gap",
                    Safe_ops.json_string ~default:"coverage_gap" "stale_reason"
                      gap )
                | None -> (
                    match latest_age_s with
                    | None -> ("empty", "no_entries")
                    | Some age when age > freshness_slo_s ->
                        ("stale", "freshness_slo_exceeded")
                    | Some _ -> ("ok", ""))
              in
              `Assoc [
                ("keeper", `String name);
                ("count", `Int (List.length entries));
                ("source", `String "tool_call_io");
                ( "producer",
                  `String
                    "keeper_hooks_agent_core.post_tool_use|mcp_server_eio_call_tool.runtime_mcp" );
                ("durable_store", `String (Filename.concat masc_root "tool_calls"));
                ("dashboard_surface", `String dashboard_surface);
                ("freshness_slo_s", `Float freshness_slo_s);
                ("latest_ts_unix", Json_util.float_opt_to_json latest_ts);
                ( "latest_ts_iso",
                  match latest_ts with
                  | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
                  | None -> `Null );
                ("latest_age_s", Json_util.float_opt_to_json latest_age_s);
                ("health", `String health);
                ( "stale_reason",
                  if stale_reason = "" then `Null else `String stale_reason );
                ("coverage_gaps", `List coverage_gaps);
                ("entries", `List entries);
              ])
      in
      Http.Response.json_value ~compress:true ~request:req json reqd
  else if ends_with "/waiting-inventory" then
    let name = extract_name "/waiting-inventory" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else if not (Keeper_config.validate_name name) then
      Http.Response.json_value ~status:`Bad_request
        (`Assoc
           [ ("error", `String (Printf.sprintf "invalid keeper name: %s" name)) ])
        reqd
    else
      let config = Mcp_server.workspace_config state in
      let json =
        Domain_pool_ref.submit_io_or_inline (fun () ->
          Server_keeper_waiting_inventory.dashboard_json_for_keeper
            config
            ~keeper_name:name)
      in
      Http.Response.json_value ~compress:true ~request:req json reqd
  else if ends_with "/feedback" then
    (* keeper-v2 #9: aggregated response-feedback tally (read API).
       GET /api/v1/keepers/:name/feedback. The per-keeper feedback log is the
       SSOT; the view renders this tally (no view-side derivation). A read IO
       fault surfaces as 500, never a silently-empty success. *)
    let name = extract_name "/feedback" in
    if String.length name = 0 then respond_error reqd "keeper name is required"
    else if not (Keeper_config.validate_name name) then
      Http.Response.json_value ~status:`Bad_request
        (`Assoc
           [ ("error", `String (Printf.sprintf "invalid keeper name: %s" name)) ])
        reqd
    else
      let config = Mcp_server.workspace_config state in
      (match Keeper_response_feedback.read_tally ~config ~keeper_id:name with
       | Ok tally ->
         Http.Response.json_value ~compress:true ~request:req
           (Keeper_response_feedback.tally_to_json tally) reqd
       | Error (`Io msg) ->
         Http.Response.json_value ~status:`Internal_server_error
           (`Assoc [ ("error", `String msg) ]) reqd)
  else if ends_with "/memory-journal" then
    (* Why this keeper's memory looks the way it does. The librarian's passes
       reach disk here — committed and failed alike since RFC-0361 Part 5 — and
       the internal-agents monitor could show that a pass ran but not what it
       decided. A failed pass is the case an operator actually opens. *)
    let name = extract_name "/memory-journal" in
    if not (Keeper_config.validate_name name)
    then
      Http.Response.json_value ~status:`Bad_request
        (`Assoc
           [ "error", `String (Printf.sprintf "invalid keeper name: %s" name) ])
        reqd
    else (
      let limit =
        Server_utils.int_query_param req "limit" ~default:50 |> max 1 |> min 500
      in
      let config = Mcp_server.workspace_config state in
      let keepers_dir = memory_os_keepers_dir config in
      let lines =
        Keeper_memory_os_current.read_journal_tail
          ~keepers_dir
          ~keeper_id:name
          ~limit
      in
      let undecodable =
        List.length (List.filter (function Error _ -> true | Ok _ -> false) lines)
      in
      Http.Response.json_value ~compress:true ~request:req
        (`Assoc
           [ "keeper", `String name
           ; "dashboard_surface", `String "/api/v1/keepers/:name/memory-journal"
           ; "returned", `Int (List.length lines)
           ; (* Reported rather than hidden: a journal this build cannot fully
                read is a different observation from a shorter one. *)
             "undecodable_lines", `Int undecodable
           ; ( "entries"
             , `List (List.map Keeper_memory_os_current.journal_line_to_json lines) )
           ])
        reqd)
  else if ends_with "/operator-note" then
    (* RFC-0366. Read-only here: the operator asks whether a note is pending or
       which turn consumed it. The write surface belongs to the operator control
       plane and is a separate change. *)
    let name = extract_name "/operator-note" in
    (match
       Keeper_operator_note.read ~config:(Mcp_server.workspace_config state) ~keeper:name
     with
     | Ok note ->
       Http.Response.json_value ~compress:true ~request:req
         (`Assoc
            [ "keeper", `String name
            ; "dashboard_surface", `String "/api/v1/keepers/:name/operator-note"
            ; "pending", `Bool (Option.is_none note.consumed_at)
            ; "note", Keeper_operator_note.to_json note
            ])
         reqd
     | Error (Keeper_operator_note.No_note as error) ->
       Http.Response.json_value ~status:`Not_found
         (`Assoc
            [ "error", `String (Keeper_operator_note.read_error_to_string error) ])
         reqd
     | Error error ->
       Http.Response.json_value ~status:`Bad_request
         (`Assoc
            [ "error", `String (Keeper_operator_note.read_error_to_string error) ])
         reqd)
  else if ends_with "/last-prompt" then
    (* What this keeper was actually told, as text. The turn record keeps each
       block's bytes and digest — how much, never what. The blocks are stable
       turn to turn, so the last assembly is also the preview of the next. *)
    let name = extract_name "/last-prompt" in
    (match
       Keeper_prompt_capture.read ~config:(Mcp_server.workspace_config state) ~keeper:name
     with
     | Ok capture ->
       Http.Response.json_value ~compress:true ~request:req
         (match Keeper_prompt_capture.to_json capture with
          | `Assoc fields ->
            `Assoc
              (("keeper", `String name)
               :: ("dashboard_surface", `String "/api/v1/keepers/:name/last-prompt")
               :: fields)
          | json -> json)
         reqd
     | Error (Keeper_prompt_capture.Not_captured as error) ->
       Http.Response.json_value ~status:`Not_found
         (`Assoc
            [ "error", `String (Keeper_prompt_capture.read_error_to_string error) ])
         reqd
     | Error error ->
       Http.Response.json_value ~status:`Bad_request
         (`Assoc
            [ "error", `String (Keeper_prompt_capture.read_error_to_string error) ])
         reqd)
  else if ends_with "/raw-traces" then
    (* The turn record already carries a raw_trace_run_ref naming this file;
       until now nothing served it, so the pointer reached the dashboard type
       and the content had no route. Listing is separate from reading because a
       turn file runs to hundreds of records and an operator picks one first. *)
    let name = extract_name "/raw-traces" in
    let limit =
      Server_utils.int_query_param req "limit" ~default:25 |> max 1 |> min 200
    in
    (match Keeper_raw_trace_reader.list_turns
             ~config:(Mcp_server.workspace_config state)
             ~keeper:name
             ~limit
     with
     | Error error ->
       Http.Response.json_value ~status:`Bad_request
         (`Assoc
            [ "error", `String (Keeper_raw_trace_reader.read_error_to_string error) ])
         reqd
     | Ok turns ->
       Http.Response.json_value ~compress:true ~request:req
         (`Assoc
            [ "keeper", `String name
            ; "count", `Int (List.length turns)
            ; ( "turns"
              , `List (List.map Keeper_raw_trace_reader.turn_summary_to_json turns) )
            ; "dashboard_surface", `String "/api/v1/keepers/:name/raw-traces"
            ])
         reqd)
  else if ends_with "/raw-trace" then
    (* One turn's records. [file] is a handle from the listing, never a path;
       the reader rejects anything that could leave the keeper's directory
       rather than normalizing it. *)
    let name = extract_name "/raw-trace" in
    let offset = Server_utils.int_query_param req "offset" ~default:0 |> max 0 in
    let limit =
      Server_utils.int_query_param req "limit" ~default:200 |> max 1 |> min 2000
    in
    (* A missing [file] is a caller that named no turn. Defaulting it to the
       empty string would route that request into the reader's file-name
       validation and report it as an invalid name, which describes a different
       mistake than the one made. *)
    (match Server_utils.query_param req "file" with
     | None ->
       Http.Response.json_value ~status:`Bad_request
         (`Assoc [ "error", `String "file is required; list turns at /raw-traces" ])
         reqd
     | Some file ->
       (match Keeper_raw_trace_reader.read_turn
                ~config:(Mcp_server.workspace_config state)
                ~keeper:name
                ~file
                ~offset
                ~limit
        with
     | Error (Keeper_raw_trace_reader.No_such_turn _ as error) ->
       Http.Response.json_value ~status:`Not_found
         (`Assoc
            [ "error", `String (Keeper_raw_trace_reader.read_error_to_string error) ])
         reqd
     | Error error ->
       Http.Response.json_value ~status:`Bad_request
         (`Assoc
            [ "error", `String (Keeper_raw_trace_reader.read_error_to_string error) ])
         reqd
     | Ok records ->
       Http.Response.json_value ~compress:true ~request:req
         (match Keeper_raw_trace_reader.turn_records_to_json records with
          | `Assoc fields ->
            `Assoc
              (("keeper", `String name)
               :: ("dashboard_surface", `String "/api/v1/keepers/:name/raw-trace")
               :: fields)
          | json -> json)
         reqd))
  else if ends_with "/compaction-snapshots" then
    let name = extract_name "/compaction-snapshots" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else if not (Keeper_config.validate_name name) then
      Http.Response.json_value ~status:`Bad_request
        (`Assoc
           [("error", `String (Printf.sprintf "invalid keeper name: %s" name))])
        reqd
    else
      let limit =
        Server_utils.int_query_param req "limit" ~default:compaction_snapshot_default_limit
        |> max 1 |> min compaction_snapshot_max_limit
      in
      let config = Mcp_server.workspace_config state in
      let force_refresh =
        Server_utils.bool_query_param req "refresh" ~default:false
      in
      let json =
        cached_compaction_snapshots_json ~config ~keeper_id:name ~limit
          ~force_refresh
      in
      Http.Response.json_value ~compress:true ~request:req
        json reqd
  else if ends_with "/turn-records" then
    (* RFC-0233 §2.3 PR-4: serve TurnRecords with server-side
       consecutive-pair block diffs so the dashboard stays a renderer
       of the tested OCaml diff (views derive; no view-side repair). *)
    let name = extract_name "/turn-records" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else if not (Keeper_config.validate_name name) then
      Http.Response.json_value ~status:`Bad_request
        (`Assoc
           [("error", `String (Printf.sprintf "invalid keeper name: %s" name))])
        reqd
    else
      let limit =
        Server_utils.int_query_param req "limit" ~default:50
        |> max 1 |> min trajectory_max_limit
      in
      let config = (Mcp_server.workspace_config state) in
      let turn_record_freshness_slo_s =
        Runtime_params.get Runtime_settings.keeper_keepalive_interval_sec
        |> float_of_int
        |> fun keepalive_interval_s ->
        Keeper_status_runtime.keeper_turn_record_freshness_slo_s
          ~keepalive_interval_s
      in
      let store = Keeper_types_support.keeper_turn_record_store config name in
      let raw_rows = Dated_jsonl.read_recent store limit in
      (* Strict decode: malformed rows are counted and reported, never
         repaired or silently dropped (RFC-0233 §4). *)
      let records_rev, skipped_rows =
        List.fold_left
          (fun (acc, skipped) json ->
            match Turn_record.of_json json with
            | Ok record -> (record :: acc, skipped)
            | Error _ -> (acc, skipped + 1))
          ([], 0) raw_rows
      in
      let records = List.rev records_rev in
      let block_json = Turn_record.prompt_block_to_json in
      let entries =
        Turn_record.entries_with_diffs records
        |> List.map (fun ((record : Turn_record.t), diff) ->
             let diff_vs_prev =
               match diff with
               | Some (d : Turn_record.block_diff) ->
                 `Assoc
                   [ ("added", `List (List.map block_json d.added))
                   ; ("removed", `List (List.map block_json d.removed))
                   ; ( "changed"
                     , `List
                         (List.map
                            (fun (prev_b, next_b) ->
                              `Assoc
                                [ ("prev", block_json prev_b)
                                ; ("next", block_json next_b)
                                ])
                            d.changed) )
                   ]
               | None -> `Null
             in
             `Assoc
               [ ("record", Turn_record.to_json record)
               ; ("diff_vs_prev", diff_vs_prev)
               ])
      in
      let latest_ts =
        List.fold_left
          (fun acc (r : Turn_record.t) ->
            match acc with
            | Some existing when existing >= r.ts -> acc
            | _ -> Some r.ts)
          None records
      in
      let latest_age_s =
        match latest_ts with
        | Some ts -> Some (max 0.0 (Time_compat.now () -. ts))
        | None -> None
      in
      let live_turn =
        match Keeper_registry.get ~base_path:config.base_path name with
        | Some { current_turn_observation = Some observation; _ } ->
          Some observation
        | Some _ | None -> None
      in
      let health, stale_reason =
        Keeper_status_runtime.keeper_turn_record_source_health
          ~skipped_rows
          ~live_turn_in_progress:(Option.is_some live_turn)
          ~latest_age_s
          ~freshness_slo_s:turn_record_freshness_slo_s
      in
      let json = `Assoc [
        ("keeper", `String name);
        ("count", `Int (List.length records));
        ("skipped_rows", `Int skipped_rows);
        ("source", `String "turn_record");
        ("producer", `String "keeper_agent_run.run_turn|keeper_turn_record_writer");
        ( "durable_store",
          `String
            (Filename.concat
               (Workspace.masc_root_dir config)
               (Printf.sprintf "keepers/%s/turn-records" name)) );
        ("dashboard_surface", `String "/api/v1/keepers/:name/turn-records");
        ("freshness_slo_s", `Float turn_record_freshness_slo_s);
        ("live_turn_in_progress", `Bool (Option.is_some live_turn));
        ( "live_turn_started_at_unix",
          match live_turn with
          | Some observation -> `Float observation.started_at
          | None -> `Null );
        ( "live_turn_last_progress_at_unix",
          match live_turn with
          | Some observation -> `Float observation.last_progress_at
          | None -> `Null );
        ("latest_ts_unix", Json_util.float_opt_to_json latest_ts);
        ( "latest_ts_iso",
          match latest_ts with
          | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
          | None -> `Null );
        ("latest_age_s", Json_util.float_opt_to_json latest_age_s);
        ("health", `String health);
        ( "stale_reason",
          if stale_reason = "" then `Null else `String stale_reason );
        ( "memory_os"
        , memory_os_dashboard_json
            ~config:(Mcp_server.workspace_config state)
            ~keeper_id:name );
        ("entries", `List entries);
      ] in
      Http.Response.json_value ~compress:true ~request:req json reqd
  else if ends_with "/turn-transcript" then
    (* RFC-0233 §7: serve one keeper turn's operator request + keeper
       response by an exact join on the persisted chat row turn_ref
       ("<trace_id>#<absolute_turn>"). Lazily fetched by the turn
       inspector so the transcript (which can be large) never bloats the
       turn-records list. Content is the load-time redacted view the chat
       history endpoint already serves (RFC-0132); an unmatched turn_ref
       returns [found:false] rather than a fabricated transcript. *)
    let name = extract_name "/turn-transcript" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else if not (Keeper_config.validate_name name) then
      Http.Response.json_value ~status:`Bad_request
        (`Assoc
           [("error", `String (Printf.sprintf "invalid keeper name: %s" name))])
        reqd
    else (
      match Server_utils.query_param req "turn_ref" with
      | None ->
        Http.Response.json_value ~status:`Bad_request
          (`Assoc
             [("error", `String "turn_ref query parameter is required")])
          reqd
      | Some turn_ref_str ->
        (match Ids.Turn_ref.of_string turn_ref_str with
         | None ->
           Http.Response.json_value ~status:`Bad_request
             (`Assoc
                [ ( "error",
                    `String
                      (Printf.sprintf "invalid turn_ref: %s" turn_ref_str) )
                ])
             reqd
         | Some turn_ref ->
           let base_dir = (Mcp_server.workspace_config state).base_path in
           let messages = Keeper_chat_store.load ~base_dir ~keeper_name:name in
           let transcript =
             Keeper_chat_store.transcript_of_messages messages ~turn_ref
           in
           let json =
             Keeper_chat_store.turn_transcript_to_json ~keeper:name ~turn_ref
               transcript
           in
           Http.Response.json_value ~compress:true ~request:req json reqd))
  else if ends_with "/trajectory" then
    let name = extract_name "/trajectory" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else if not (Keeper_config.validate_name name) then
      Http.Response.json_value ~status:`Bad_request
        (`Assoc
           [("error", `String (Printf.sprintf "invalid keeper name: %s" name))])
        reqd
    else
      let config = (Mcp_server.workspace_config state) in
      (match Keeper_meta_store.read_meta config name with
       | Error e ->
         respond_error ~status:`Internal_server_error reqd e
       | Ok None ->
         respond_error ~status:`Not_found reqd (Printf.sprintf "keeper %S not found" name)
       | Ok (Some m) ->
         let trajectory_default_limit = 50 in
         let trace_id =
           Keeper_id.Trace_id.to_string m.runtime.trace_id
         in
         let limit =
           Server_utils.int_query_param req "limit"
             ~default:trajectory_default_limit
           |> max 1 |> min trajectory_max_limit
         in
         (* Allow caller to request more result text up to a safe max.
            Default 2000 chars is enough for the collapsed list view;
            set result_max_len=10000 (or higher, capped at 10000) to
            get full detail for an expanded entry. *)
         let result_max_len =
           Server_utils.int_query_param req "result_max_len"
             ~default:2000
           |> max 0 |> min 10000
         in
         let include_thinking =
           Server_utils.bool_query_param req "include_thinking"
             ~default:false
         in
         let tail_scan_lines =
           let multiplier = if include_thinking then 3 else 8 in
           max 500 (min 5000 (limit * multiplier))
         in
         let cache_key =
           Printf.sprintf
             "keeper:trajectory:%s:%s:%s:%d:%d:%b:%d"
             (Workspace.masc_root_dir config)
             name
             trace_id
             limit
             result_max_len
             include_thinking
             tail_scan_lines
         in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:keeper_hot_path_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               let masc_root = Workspace.masc_root_dir config in
               let trajectory_lines =
                 Trajectory.read_recent_lines ~masc_root ~keeper_name:m.name
                   ~trace_id ~max_lines:tail_scan_lines
               in
               (* Reasoning evidence comes only from the metadata-only
                  trajectory producer. Internal assistant history is never
                  reclassified into this surface. *)
               let lines =
                 if include_thinking then trajectory_lines
                 else List.filter (function
                   | Trajectory.Tool_call _ -> true
                   | Trajectory.Withheld_thinking _ -> false) trajectory_lines
               in
               let total = List.length lines in
               let recent =
                 if total <= limit then lines
                 else
                   let drop = total - limit in
                   List.filteri (fun i _e -> i >= drop) lines
               in
               `Assoc [
                 ("keeper", `String name);
                 ("trace_id", `String trace_id);
                 ("generation", `Int m.runtime.nonce);
                 ("total_entries", `Int total);
                 ("showing", `Int (List.length recent));
                 ("entries", `List (List.map
                   (Trajectory.trajectory_line_to_json ~result_max_len) recent));
               ]))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd)
  else if ends_with "/transitions" then
    let name = extract_name "/transitions" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
      let limit =
        Server_utils.int_query_param req "limit" ~default:20
        |> max 1 |> min 50
      in
      let base_path = (Mcp_server.workspace_config state).base_path in
      let phase = Keeper_registry.get_phase ~base_path name in
      let phase_str = match phase with
        | Some p -> `String (Keeper_state_machine.phase_to_string p)
        | None -> `Null
      in
      let transitions =
        Keeper_transition_audit.recent_transitions_json
          ~keeper_name:name ~limit
      in
      let json = `Assoc [
        "keeper", `String name;
        "current_phase", phase_str;
        "count", `Int (json_list_length transitions);
        "transitions", transitions;
      ] in
      Http.Response.json_value ~compress:true ~request:req json reqd
  (* #12798 Dashboard Gaps: lifecycle event timeline per keeper. *)
  else if ends_with "/lifecycle" then
    let name = extract_name "/lifecycle" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
      let limit =
        Server_utils.int_query_param req "limit" ~default:50
        |> max 1 |> min 200
      in
      let events =
        Keeper_lifecycle_audit.recent_json ~keeper_name:name ~limit
      in
      let json = `Assoc [
        "keeper", `String name;
        "count", `Int (json_list_length events);
        "events", events;
      ] in
      Http.Response.json_value ~compress:true ~request:req json reqd
  else if ends_with "/eval" then
    let name = extract_name "/eval" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
      let base_path = (Mcp_server.workspace_config state).base_path in
      let limit =
        Server_utils.int_query_param req "limit" ~default:10
        |> max 1 |> min 100
      in
      (* Use keeper name as agent_name for eval lookup.
         Keepers may also have a separate agent_name — look up both. *)
      let config = (Mcp_server.workspace_config state) in
      let agent_name_opt =
        match Keeper_meta_store.read_meta config name with
        | Ok (Some m) when m.agent_name <> name -> Some m.agent_name
        | _ -> None
      in
      let snapshots_by_name =
        Dashboard_eval_feed.read_latest ~base_path ~agent_name:name ~limit
      in
      let snapshots =
        match agent_name_opt with
        | Some agent_name when snapshots_by_name = [] ->
            Dashboard_eval_feed.read_latest ~base_path ~agent_name ~limit
        | _ -> snapshots_by_name
      in
      let latest_verdict =
        match snapshots with
        | s :: _ -> Some s.Dashboard_eval_feed.verdict
        | [] -> None
      in
      let json = `Assoc [
        ("keeper", `String name);
        ("count", `Int (List.length snapshots));
        ("latest_coverage",
          match latest_verdict with
          | Some v -> `Float v.Dashboard_eval_feed.coverage
          | None -> `Null);
        ("latest_all_passed",
          match latest_verdict with
          | Some v -> `Bool v.Dashboard_eval_feed.all_passed
          | None -> `Null);
        ("snapshots",
          `List (List.map Dashboard_eval_feed.snapshot_to_json snapshots));
      ] in
      Http.Response.json_value ~compress:true ~request:req json reqd
  else if ends_with "/state-diagram" then
    let name = extract_name "/state-diagram" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
      let base_path = (Mcp_server.workspace_config state).base_path in
      let phase = Keeper_registry.get_phase ~base_path name in
      let current = match phase with Some p -> p | None -> Keeper_state_machine.Offline in
      let mermaid = Keeper_state_machine_mermaid.phase_to_mermaid ~current in
      let phase_str = Keeper_state_machine.phase_to_string current in
      let meta = Keeper_meta_store.read_meta
          (Mcp_server.workspace_config state) name in
      let runtime_projection =
        state_diagram_runtime_projection
          (match meta with
           | Ok meta -> meta
           | Error _ -> None)
      in
      let runtime_fsm_mermaid =
        state_diagram_runtime_fsm_mermaid runtime_projection
      in
      (* Compaction sub-FSM: only emit a diagram when the keeper is in
         the [Compacting] phase. *)
      let compaction_submachine_mermaid =
        match current with
        | Keeper_state_machine.Compacting ->
          let b = Buffer.create 256 in
          Buffer.add_string b "stateDiagram-v2\n";
          Buffer.add_string b "    [*] --> Accumulating\n";
          Buffer.add_string b "    Accumulating --> Compacting: Compaction_started\n";
          Buffer.add_string b "    Compacting --> Done: Compaction_completed\n";
          Buffer.add_string b "    Compacting --> Accumulating: Compaction_failed\n";
          Buffer.add_string b "    Done --> [*]\n";
          Buffer.add_string b
            "    classDef active fill:#22c55e,stroke:#16a34a,color:#fff,stroke-width:3px\n";
          Buffer.add_string b "    class Compacting active\n";
          `String (Buffer.contents b)
        | _ -> `Null
      in
      let runtime_projection_fields =
        match state_diagram_runtime_projection_json runtime_projection with
        | `Assoc fields -> fields
        | _ -> []
      in
      let json =
        `Assoc
          ([ "keeper", `String name
           ; "current_phase", `String phase_str
           ; "mermaid", `String mermaid
           ; "runtime_fsm_mermaid", `String runtime_fsm_mermaid
           ; "compaction_submachine_mermaid", compaction_submachine_mermaid
           ]
           @ runtime_projection_fields)
      in
      Http.Response.json_value ~compress:true ~request:req json reqd
  else if req_path = prefix ^ "composite" then
    (* LT-16a: fleet-wide composite snapshot. Enumerates every
       registered keeper via [Keeper_registry.all] and projects each
       through [Keeper_composite_observer.observe]. Same purity
       contract as the per-keeper route below.

       Shape:
         { "generated_at": 1234567890.1,
           "count": 3,
           "snapshots": [ <snapshot JSON>, ... ] }

       Consumed by [dashboard/src/components/fleet-fsm-matrix.ts]
       (LT-16b, upcoming). *)
    let json =
      Server_dashboard_http.dashboard_fleet_composite_json
        ~config:(Mcp_server.workspace_config state) ()
    in
    Http.Response.json_value ~compress:true ~request:req json reqd
  else if ends_with "/composite" then
    (* RFC-0003 §7: composite lifecycle snapshot derived from the
       registry entry via the [Keeper_composite_observer] pure
       projection. No mutation, no I/O, no provider/token access. *)
    let name = extract_name "/composite" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
      let config = Mcp_server.workspace_config state in
      let status, json = cached_keeper_composite_json config name in
      let status : Httpun.Status.t =
        match status with
        | `OK -> `OK
        | `Not_found -> `Not_found
        | `Internal_server_error -> `Internal_server_error
      in
      Http.Response.json_value ~status ~compress:true ~request:req json reqd
  else
    respond_error ~status:`Not_found reqd "not found"
