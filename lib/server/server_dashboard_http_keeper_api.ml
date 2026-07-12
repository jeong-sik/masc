(** Keeper HTTP API handlers — POST handlers + GET sub-routes.

    POST handlers extracted to [Server_dashboard_http_keeper_api_post]
    (godfile decomp). *)

include Server_dashboard_http_keeper_api_post

let standard_cache_ttl_s = Server_dashboard_http_core_cache.standard_cache_ttl_s
let freshness_slo_s = Server_dashboard_http_core_cache.freshness_slo_s

let keeper_hot_path_cache_ttl_s = 30.0
let keeper_composite_cache_ttl_s = 5.0

(* Bounded dashboard hydration defaults for the operator compaction inspector.
   These cap best-effort filesystem scans; [scan_truncated] in the response makes
   the bound observable when there are more manifest files/rows than scanned. *)
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

let compaction_snapshot_manifest_tail_max_lines =
  Env_config.KeeperCompactionSnapshots.manifest_tail_max_lines
;;

(* Maximum number of trajectory/trace entries returned per query. *)
let trajectory_max_limit = 500

let cached_assoc_body_or_self cached fields =
  match List.assoc_opt "body" fields with
  | Some body -> body
  | None -> cached
;;

let json_string_opt = function
  | Some value -> `String value
  | None -> `Null
;;

let json_float_opt = function
  | Some value -> `Float value
  | None -> `Null
;;

let json_time_iso_opt = function
  | Some value -> `String (Masc_domain.iso8601_of_unix_seconds value)
  | None -> `Null
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

let memory_os_fact_is_current ~now (fact : Keeper_memory_os_types.fact) =
  match fact.valid_until with
  | None -> true
  | Some ts -> ts >= now
;;

let memory_os_episode_is_current ~now (episode : Keeper_memory_os_types.episode) =
  match episode.valid_until with
  | None -> true
  | Some ts -> ts >= now
;;

let memory_os_count pred xs =
  List.fold_left (fun count value -> if pred value then count + 1 else count) 0 xs
;;

let keeper_chat_allowed_trace_ids (m : Keeper_meta_contract.keeper_meta) =
  Keeper_id.Trace_id.to_string m.runtime.trace_id :: m.runtime.trace_history
  |> Json_util.dedupe_keep_order
;;

let memory_os_read_episodes ~keeper_id ~n =
  try Keeper_memory_os_io.read_episodes_tail ~keeper_id ~n, None with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> [], Some (Printexc.to_string exn)
;;

let memory_os_read_facts ~keeper_id ~n =
  try Keeper_memory_os_io.read_facts_tail ~keeper_id ~n, None with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> [], Some (Printexc.to_string exn)
;;

let memory_os_episode_json ~now (episode : Keeper_memory_os_types.episode) =
  `Assoc
    [ "trace_id", `String episode.trace_id
    ; "generation", `Int episode.generation
    ; "created_at", `Float episode.created_at
    ; "created_at_iso", `String (Masc_domain.iso8601_of_unix_seconds episode.created_at)
    ; "valid_until", json_float_opt episode.valid_until
    ; "valid_until_iso", json_time_iso_opt episode.valid_until
    ; "current", `Bool (memory_os_episode_is_current ~now episode)
    ; "terminal_marker", json_string_opt episode.terminal_marker
    ; "claim_count", `Int (List.length episode.claims)
    ; ( "source_turn_range"
      , match episode.source_turn_range with
        | Some (lo, hi) -> `Assoc [ "lo", `Int lo; "hi", `Int hi ]
        | None -> `Null )
    ; "summary", `String episode.episode_summary
    ]
;;

(* RFC-keeper-memory-panel-real-data §4a: surface the fact rows the panel renders, mirroring
   [memory_os_episode_json]. Serializes ONLY the existing [fact] structure —
   claim, typed category, provenance, the three timestamps, and current-ness —
   never the deleted score fields (confidence / access_count / last_accessed,
   RFC-0247): they are absent from the [fact] record, so the type system makes
   re-emitting them unrepresentable. [reference_time] is the shared staleness
   anchor (last_verified_at else first_seen), reused rather than re-inlined.
   [prompt_recallable] is projected from [fact_prompt_recallable], the same typed
   SSOT recall uses, so the UI does not infer prompt eligibility from labels.
   [claim_kind] is omitted when [None] so a claim without optional metadata stays a
   minimal row. [external_ref] is intentionally not surfaced; PR/issue text remains
   claim context rather than a machine status field. *)
let memory_os_fact_json ~now (fact : Keeper_memory_os_types.fact) =
  `Assoc
    ([ "claim", `String fact.claim
     ; "category", `String (Keeper_memory_os_types.category_to_string fact.category)
     ; "source", Keeper_memory_os_types.provenance_event_to_json fact.source
     ; "first_seen", `Float fact.first_seen
     ; "first_seen_iso", `String (Masc_domain.iso8601_of_unix_seconds fact.first_seen)
     ; "reference_time", `Float (Keeper_memory_os_types.reference_time fact)
     ; "valid_until", json_float_opt fact.valid_until
	     ; "valid_until_iso", json_time_iso_opt fact.valid_until
	     ; "last_verified_at", json_float_opt fact.last_verified_at
	     ; "current", `Bool (memory_os_fact_is_current ~now fact)
	     ; "prompt_recallable", `Bool (Keeper_memory_os_types.fact_prompt_recallable fact)
	     ]
     @ (match fact.claim_kind with
        | Some k -> [ "claim_kind", `String (Keeper_memory_os_types.claim_kind_to_string k) ]
        | None -> []))
;;

type memory_os_selection_policy =
  { keeper_scope : string
  ; shared_scope : string option
  ; facts_source : string
  ; shared_facts_source : string option
  ; episodes_source : string
  ; dashboard_fact_tail_limit : int
  ; dashboard_episode_tail_limit : int
  ; recall_private_fact_limit : int
  ; recall_shared_fact_limit : int
  ; recall_episode_limit : int
  ; category_source : string
  ; claim_kind_source : string
  ; recall_block : string
  ; prompt_record : string
  }

let memory_os_selection_policy_json (policy : memory_os_selection_policy) =
  `Assoc
    [ "keeper_scope", `String policy.keeper_scope
    ; "shared_scope", json_string_opt policy.shared_scope
    ; "facts_source", `String policy.facts_source
    ; "shared_facts_source", json_string_opt policy.shared_facts_source
    ; "episodes_source", `String policy.episodes_source
    ; "dashboard_fact_tail_limit", `Int policy.dashboard_fact_tail_limit
    ; "dashboard_episode_tail_limit", `Int policy.dashboard_episode_tail_limit
    ; "recall_private_fact_limit", `Int policy.recall_private_fact_limit
    ; "recall_shared_fact_limit", `Int policy.recall_shared_fact_limit
    ; "recall_episode_limit", `Int policy.recall_episode_limit
    ; "category_source", `String policy.category_source
    ; "claim_kind_source", `String policy.claim_kind_source
    ; "recall_block", `String policy.recall_block
    ; "prompt_record", `String policy.prompt_record
    ]
;;

let memory_os_selection_policy ~keeper_id ~fact_tail_limit ~recent_episode_limit =
  let has_shared_tier =
    not (String.equal keeper_id Keeper_memory_os_types.shared_store_id)
  in
  { keeper_scope = keeper_id
  ; shared_scope =
      (if has_shared_tier then Some Keeper_memory_os_types.shared_store_id else None)
  ; facts_source = "Keeper_memory_os_io.read_facts_tail"
  ; shared_facts_source =
      (if has_shared_tier then Some "Keeper_memory_os_io.read_facts_all" else None)
  ; episodes_source = "Keeper_memory_os_io.read_episodes_tail"
  ; dashboard_fact_tail_limit = fact_tail_limit
  ; dashboard_episode_tail_limit = recent_episode_limit
  ; recall_private_fact_limit = Keeper_memory_os_policy.recall_default_max_facts
  ; recall_shared_fact_limit =
      (if has_shared_tier then Keeper_memory_os_policy.recall_default_max_shared_facts else 0)
  ; recall_episode_limit = Keeper_memory_os_policy.recall_default_max_episodes
  ; category_source = "Keeper_memory_os_types.category_to_string"
  ; claim_kind_source = "Keeper_memory_os_types.claim_kind_to_string"
  ; recall_block = "Keeper_memory_os_recall.render_if_enabled"
  ; prompt_record = "Keeper_run_tools_hooks.record_block Prompt_block_id.Memory_os_recall"
  }
;;

let memory_os_dashboard_json ~keeper_id =
  let now = Time_compat.now () in
  let recent_episode_limit = 12 in
  let fact_tail_limit = Keeper_memory_os_policy.fact_store_max in
  let episodes, episode_error =
    memory_os_read_episodes ~keeper_id ~n:recent_episode_limit
  in
  let facts, fact_error = memory_os_read_facts ~keeper_id ~n:fact_tail_limit in
  let facts_path = Keeper_memory_os_io.facts_path ~keeper_id in
  let keepers_dir = Filename.dirname facts_path in
  let episodes_store = Filename.concat (Filename.concat keepers_dir keeper_id) "episodes" in
  let current_episodes = memory_os_count (memory_os_episode_is_current ~now) episodes in
  let current_facts = memory_os_count (memory_os_fact_is_current ~now) facts in
  let terminal_marker_count =
    memory_os_count
      (fun (episode : Keeper_memory_os_types.episode) ->
         Option.is_some episode.terminal_marker)
      episodes
  in
  `Assoc
    [ "schema", `String "keeper.memory_os.recall_observability.v1"
    ; "keeper", `String keeper_id
    ; "source", `String "memory_os_files"
    ; "producer", `String "keeper_librarian|keeper_memory_os_recall"
    ; ( "selection_policy"
      , memory_os_selection_policy
          ~keeper_id
          ~fact_tail_limit
          ~recent_episode_limit
        |> memory_os_selection_policy_json )
    ; "facts_store", `String facts_path
    ; "episodes_store", `String episodes_store
    ; "recall_enabled", `Bool (Keeper_memory_os_recall.enabled ())
    ; "now", `Float now
    ; "now_iso", `String (Masc_domain.iso8601_of_unix_seconds now)
    ; ( "read_errors"
      , `List
          (List.filter_map
             (fun (scope, err) ->
                Option.map (fun message -> `Assoc [ "scope", `String scope; "error", `String message ]) err)
             [ "episodes", episode_error; "facts", fact_error ]) )
    ; ( "episodes"
      , `Assoc
          [ "tail_limit", `Int recent_episode_limit
          ; "shown", `Int (List.length episodes)
          ; "current", `Int current_episodes
          ; "expired", `Int (List.length episodes - current_episodes)
          ; "terminal_markers", `Int terminal_marker_count
          ; "items", `List (List.map (memory_os_episode_json ~now) episodes)
          ] )
    ; ( "facts"
      , `Assoc
          [ "tail_limit", `Int fact_tail_limit
          ; "shown", `Int (List.length facts)
          ; "current", `Int current_facts
          ; "expired", `Int (List.length facts - current_facts)
            (* RFC-keeper-memory-panel-real-data §4a: the individual fact rows (previously counts-only).
               Bounded by [fact_tail_limit]; [shown] documents the bound so a
               truncated tail is visible, not silent. *)
          ; "items", `List (List.map (memory_os_fact_json ~now) facts)
          ] )
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

let safe_regular_mtime ~base_dir path =
  try
    let st = Unix.stat path in
    if st.Unix.st_kind = Unix.S_REG
    then Some st.Unix.st_mtime, []
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
        |> List.filter
             (String.ends_with
                ~suffix:Keeper_runtime_manifest.manifest_file_suffix)
        |> List.fold_left
             (fun (entries, read_errors) file ->
        let path = Filename.concat dir file in
        let mtime, errors = safe_regular_mtime ~base_dir:dir path in
        let entries =
          match mtime with
          | Some mtime -> (path, mtime) :: entries
          | None -> entries
        in
        entries, List.rev_append errors read_errors)
             ([], [])
      in
      let sorted_entries = List.sort (fun (_, a) (_, b) -> Float.compare b a) entries in
      let scan_truncated = List.length sorted_entries > scan_limit in
      ( sorted_entries |> compaction_snapshot_take scan_limit |> List.map fst
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

let read_runtime_manifest_tail_rows ~base_dir path =
  try
    Dated_jsonl.load_tail_lines path
      ~max_lines:compaction_snapshot_manifest_tail_max_lines
    |> fun lines ->
    let compaction_snapshot_manifest_event_name = function
      | `Assoc fields -> (
          match List.assoc_opt "event" fields with
          | Some (`String event) -> Some event
          | _ -> None)
      | _ -> None
    in
    let rec parse_manifest_row line_no rows read_errors rest json =
      match Keeper_runtime_manifest.of_json json with
      | Ok row -> loop (line_no + 1) (row :: rows) read_errors rest
      | Error msg ->
        loop (line_no + 1) rows
          (compaction_snapshot_read_error
             ~scope:(runtime_manifest_row_scope ~base_dir path line_no)
             ~error:msg
           :: read_errors)
          rest
    and loop line_no rows read_errors = function
      | [] -> List.rev rows, List.rev read_errors
      | line :: rest ->
      try
        let json = Yojson.Safe.from_string line in
        (match compaction_snapshot_manifest_event_name json with
         | Some event -> (
           match Keeper_runtime_manifest.classify_compaction_snapshot_event event with
           | Keeper_runtime_manifest.Compaction_snapshot_known_unrelated ->
             loop (line_no + 1) rows read_errors rest
           | Keeper_runtime_manifest.Compaction_snapshot_relevant
           | Keeper_runtime_manifest.Compaction_snapshot_unknown ->
             parse_manifest_row line_no rows read_errors rest json)
         | None -> parse_manifest_row line_no rows read_errors rest json)
      with
          | Yojson.Json_error msg | Yojson.Safe.Util.Type_error (msg, _) ->
            loop (line_no + 1) rows
              (compaction_snapshot_read_error
                 ~scope:(runtime_manifest_row_scope ~base_dir path line_no)
                 ~error:msg
               :: read_errors)
              rest
    in
    let rows, read_errors = loop 1 [] [] lines in
    rows, read_errors, List.length lines >= compaction_snapshot_manifest_tail_max_lines
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    ( []
    , [ compaction_snapshot_read_error
          ~scope:(runtime_manifest_file_scope ~base_dir path)
          ~error:(Printexc.to_string exn)
      ]
    , false )
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
  ; status : string
  ; links : Yojson.Safe.t
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
    ; "status", `String item.status
    ; "links", item.links
    ]
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
         ; status = row.status
         ; links = compaction_snapshot_links_json row.links
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
            ; status = row.status
            ; links = compaction_snapshot_links_json row.links
            })
     | Some _ | None -> None)
;;

let compaction_context_snapshot_json ~keeper_id (row : Keeper_runtime_manifest.t) =
  (* TEL-OK: read-only dashboard projection; compaction telemetry is emitted by
     the keeper runtime/event bridge that produced the manifest row. *)
  let pre_dispatch_compacted =
    Json_util.get_bool row.decision "pre_dispatch_compacted" = Some true
  in
  if (not pre_dispatch_compacted) && Keeper_runtime_manifest.status_is_skipped row
  then None
  else
    let before_tokens =
      match Json_util.get_int row.decision "before_tokens" with
      | Some tokens -> Some tokens
      | None -> Json_util.get_int row.decision "pre_dispatch_compaction_before_tokens"
    in
    let after_tokens =
      match Json_util.get_int row.decision "after_tokens" with
      | Some tokens -> Some tokens
      | None -> Json_util.get_int row.decision "pre_dispatch_compaction_after_tokens"
    in
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
         ; trigger = Option.value ~default:"pre_dispatch_hygiene" compaction_source
         ; runtime_id = row.runtime_id
         ; before_tokens
         ; after_tokens
         ; saved_tokens = compaction_saved_tokens before_tokens after_tokens
         ; compaction_id = compaction_snapshot_clock_string row.decision "compaction_id"
         ; compaction_source
         ; status = row.status
         ; links = compaction_snapshot_links_json row.links
         })
;;

let compaction_snapshot_of_manifest_row ~keeper_id (row : Keeper_runtime_manifest.t) =
  match row.event with
  | Keeper_runtime_manifest.Event_bus_correlated ->
    compaction_event_bus_snapshot_json ~keeper_id row
  | Keeper_runtime_manifest.Context_compacted ->
    compaction_context_snapshot_json ~keeper_id row
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
             ; status = "latest"
             ; links = `Assoc []
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
    List.map (read_runtime_manifest_tail_rows ~base_dir:manifest_base_dir) manifest_paths
  in
  let manifest_rows = List.map (fun (rows, _, _) -> rows) rows_and_errors |> List.concat in
  let manifest_read_errors =
    path_read_errors
    @ (List.map (fun (_, read_errors, _) -> read_errors) rows_and_errors |> List.concat)
  in
  let tail_scan_truncated =
    List.exists (fun (_, _, scan_truncated) -> scan_truncated) rows_and_errors
  in
  let scan_truncated = path_scan_truncated || tail_scan_truncated in
  let manifest_items =
    manifest_rows
    |> List.sort (fun a b ->
      Float.compare
        (compaction_snapshot_manifest_sort_value b)
        (compaction_snapshot_manifest_sort_value a))
    |> List.filter_map (compaction_snapshot_of_manifest_row ~keeper_id)
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

let user_model_item_source_json = function
  | Keeper_user_model.Keeper_private -> "keeper", []
  | Keeper_user_model.Shared keepers -> "shared", keepers
;;

let user_model_item_json (item : Keeper_user_model.item) =
  let source, observed_by = user_model_item_source_json item.source in
  `Assoc
    [ "claim", `String item.claim
    ; "category", `String (Keeper_memory_os_types.category_to_string item.category)
    ; "source", `String source
    ; "observed_by", `List (List.map (fun name -> `String name) observed_by)
    ; "turn", `Int item.turn
    ; "first_seen", `Float item.first_seen
    ; "first_seen_iso", `String (Masc_domain.iso8601_of_unix_seconds item.first_seen)
    ; "last_verified_at", json_float_opt item.last_verified_at
    ; "last_verified_at_iso", json_time_iso_opt item.last_verified_at
    ]
;;

let user_model_dashboard_json ~keeper_id =
  let now = Time_compat.now () in
  let facts_store = Keeper_memory_os_io.facts_path ~keeper_id in
  let shared_facts_store =
    Keeper_memory_os_io.facts_path ~keeper_id:Keeper_memory_os_types.shared_store_id
  in
  try
    let model = Keeper_user_model.build ~keeper_id ~now () in
    `Assoc
      [ "schema", `String "keeper.user_model.dashboard.v1"
      ; "keeper", `String keeper_id
      ; "source", `String "memory_os_facts"
      ; "producer", `String "keeper_user_model"
      ; "facts_store", `String facts_store
      ; "shared_facts_store", `String shared_facts_store
      ; "enabled", `Bool (Keeper_user_model.enabled ())
      ; "now", `Float now
      ; "now_iso", `String (Masc_domain.iso8601_of_unix_seconds now)
      ; "read_errors", `List []
      ; "source_fact_count", `Int model.source_fact_count
      ; "shared_fact_count", `Int model.shared_fact_count
      ; "preferences", `List (List.map user_model_item_json model.preferences)
      ; "constraints", `List (List.map user_model_item_json model.constraints)
      ]
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    `Assoc
      [ "schema", `String "keeper.user_model.dashboard.v1"
      ; "keeper", `String keeper_id
      ; "source", `String "memory_os_facts"
      ; "producer", `String "keeper_user_model"
      ; "facts_store", `String facts_store
      ; "shared_facts_store", `String shared_facts_store
      ; "enabled", `Bool (Keeper_user_model.enabled ())
      ; "now", `Float now
      ; "now_iso", `String (Masc_domain.iso8601_of_unix_seconds now)
      ; ( "read_errors"
        , `List
            [ `Assoc
                [ "scope", `String "user_model"
                ; "error", `String (Printexc.to_string exn)
                ]
            ] )
      ; "source_fact_count", `Int 0
      ; "shared_fact_count", `Int 0
      ; "preferences", `List []
      ; "constraints", `List []
      ]
;;

let keeper_chat_receipt_state_json = function
  | Keeper_chat_queue.Pending ->
    `Assoc [ "kind", `String "pending" ]
  | Keeper_chat_queue.Inflight { lease_id; started_at } ->
    `Assoc
      [ "kind", `String "inflight"
      ; "lease_id", `String lease_id
      ; "started_at", `Float started_at
      ]
  | Keeper_chat_queue.Delivered completion ->
    `Assoc
      [ "kind", `String "delivered"
      ; "completed_at", `Float completion.completed_at
      ; "outcome_ref", json_string_opt completion.outcome_ref
      ]
  | Keeper_chat_queue.Failed failure ->
    `Assoc
      [ "kind", `String "failed"
      ; ( "failure_kind"
        , `String (Keeper_chat_queue.failure_kind_to_string failure.kind) )
      ; ( "detail"
        , `String (Observability_redact.redact_text failure.detail) )
      ; "completed_at", `Float failure.completed_at
      ; "outcome_ref", json_string_opt failure.outcome_ref
      ]
;;

let keeper_chat_receipt_json ~keeper_name ~revision
    (receipt : Keeper_chat_queue.receipt_view) =
  `Assoc
    [ "schema", `String "keeper_chat_queue.receipt.v1"
    ; "keeper_name", `String keeper_name
    ; ( "receipt_id"
      , `String
          (Keeper_chat_queue.Receipt_id.to_string receipt.receipt_id) )
    ; "revision", `Intlit (Int64.to_string revision)
    ; "state", keeper_chat_receipt_state_json receipt.state
    ]
;;

let keeper_chat_receipt_route req_path =
  if not (String.starts_with ~prefix:keeper_api_prefix req_path)
  then None
  else
    let rest =
      String.sub req_path (String.length keeper_api_prefix)
        (String.length req_path - String.length keeper_api_prefix)
    in
    match String.split_on_char '/' rest with
    | [ keeper_name; "chat"; "receipts"; receipt_id ]
      when keeper_name <> "" && receipt_id <> "" ->
      Some (keeper_name, receipt_id)
    | _ -> None
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
  match keeper_chat_receipt_route req_path with
  | Some (name, raw_receipt_id) ->
    if not (Keeper_config.validate_name name)
    then
      Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
        (error_json (Printf.sprintf "invalid keeper name: %s" name))
    else
      (match Keeper_chat_queue.Receipt_id.of_string raw_receipt_id with
       | Error message ->
         Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
           (error_json message)
       | Ok receipt_id ->
         (match Keeper_chat_queue.lookup_receipt ~keeper_name:name ~receipt_id with
          | Error error ->
            Server_auth.respond_json_value_with_cors ~status:`Service_unavailable
              request reqd
              (error_json (Keeper_chat_queue.mutation_error_to_string error))
          | Ok { receipt = None; _ } ->
            Server_auth.respond_json_value_with_cors ~status:`Not_found request reqd
              (error_json "keeper chat receipt not found")
          | Ok { revision; receipt = Some receipt } ->
            Server_auth.respond_json_value_with_cors ~status:`OK request reqd
              (keeper_chat_receipt_json ~keeper_name:name ~revision receipt)))
  | None ->
  if ends_with "/digest" then (
    (* Keeper catch-up digest (since-last-seen). Inherits the enclosing
       prefix_get "/api/v1/keepers/" + with_public_read gating, same as the
       sibling arms below; no separate router wiring. *)
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
             Keeper_catchup_digest.build_configured ~config
               ~keeper_name:name ~since_unix ~now_unix:(Time_compat.now ())
           in
           Server_auth.respond_json_value_with_cors ~status:`OK request reqd
             (Keeper_catchup_digest.to_json digest)))
  else if ends_with "/chat/history" then
    let name = extract_name "/chat/history" in
    if name = "" then
      Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
        (error_json "missing keeper name")
    else
      let config = Mcp_server.workspace_config state in
      let base_dir = config.base_path in
      let messages =
        Keeper_chat_store.load_configured ~config ~base_dir ~keeper_name:name
      in
      let trace_block_by_turn_ref =
        match Keeper_meta_store.read_meta config name with
        | Ok (Some m) ->
          Some
            (Server_dashboard_http_keeper_api_trace.chat_trace_block_by_turn_ref
               ~max_lines:trajectory_max_limit
               ~max_internal_lines:trajectory_max_limit
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
      in
      Server_auth.respond_json_value_with_cors ~status:`OK request reqd
        (Keeper_chat_store.to_json_array ~base_dir ?trace_block_by_turn_ref
           messages)
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
            let read_result =
              Trajectory.read_entries_since_result ~masc_root ~keeper_name:name ~since
            in
            let entries = read_result.Trajectory.entries in
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
                  "keeper_hooks_oas.post_tool_use|mcp_server_eio_call_tool.runtime_mcp" );
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
              ( "gate_decode",
                `Assoc
                  [
                    ( "parsed_gate_count",
                      `Int read_result.Trajectory.gate_decode.parsed_gate_count );
                    ( "legacy_default_count",
                      `Int read_result.Trajectory.gate_decode.legacy_default_count );
                  ] );
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
        |> max 1 |> min 200
      in
      let entries =
        Keeper_tool_call_log.read_recent ~keeper_name:name ~n:limit ()
      in
      let config = (Mcp_server.workspace_config state) in
      let masc_root = Workspace.masc_root_dir config in
      let latest_ts =
        List.fold_left
          (fun acc json ->
            match Safe_ops.json_float_opt "ts" json with
            | Some ts -> (
                match acc with
                | Some existing when existing >= ts -> acc
                | _ -> Some ts)
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
      let latest_gap = List.rev coverage_gaps |> List.find_opt (fun _ -> true) in
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
      let json = `Assoc [
        ("keeper", `String name);
        ("count", `Int (List.length entries));
        ("source", `String "tool_call_io");
        ( "producer",
          `String
            "keeper_hooks_oas.post_tool_use|mcp_server_eio_call_tool.runtime_mcp" );
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
      ] in
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
      let json =
        Domain_pool_ref.submit_io_or_inline (fun () ->
          compaction_snapshots_json ~config ~keeper_id:name ~limit)
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
      let health, stale_reason =
        match latest_age_s with
        | None -> ("empty", "no_entries")
        | Some age when age > freshness_slo_s ->
            ("stale", "freshness_slo_exceeded")
        | Some _ -> ("ok", "")
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
        ("memory_os", memory_os_dashboard_json ~keeper_id:name);
        ("user_model", user_model_dashboard_json ~keeper_id:name);
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
           let config = Mcp_server.workspace_config state in
           let base_dir = config.base_path in
           let messages =
             Keeper_chat_store.load_configured ~config ~base_dir ~keeper_name:name
           in
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
         let content_max_len =
           Server_utils.int_query_param req "content_max_len"
             ~default:Trajectory.default_thinking_truncation
           |> max 0 |> min 50000
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
             "keeper:trajectory:%s:%s:%s:%d:%d:%d:%b:%d"
             (Workspace.masc_root_dir config)
             name
             trace_id
             limit
             result_max_len
             content_max_len
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
               let all_lines =
                 if include_thinking then
                   merge_keeper_trace_lines ~config ~trace_id trajectory_lines
                 else
                   trajectory_lines
               in
               (* Filter out thinking entries if not requested *)
               let lines =
                 if include_thinking then all_lines
                 else List.filter (function
                   | Trajectory.Tool_call _ -> true
                   | Trajectory.Thinking _ -> false) all_lines
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
                 ("generation", `Int m.runtime.generation);
                 ("total_entries", `Int total);
                 ("total_entries_scope", `String "tail");
                 ("total_entries_exact", `Bool false);
                 ("tail_scan_lines", `Int tail_scan_lines);
                 ("showing", `Int (List.length recent));
                 ("entries", `List (List.map
                   (Trajectory.trajectory_line_to_json ~result_max_len ~content_max_len) recent));
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
      let stats = Thompson_sampling.get_stats name in
      let meta = Keeper_meta_store.read_meta
          (Mcp_server.workspace_config state) name in
      let turn_outcome : [`Ok | `Failed] option =
        match Keeper_registry.get ~base_path:(Mcp_server.workspace_config state).base_path name with
        | Some entry when entry.turn_consecutive_failures > 0 ->
          Some `Failed
        | Some _ -> Some `Ok
        | None -> None
      in
      let decision_pipeline_mermaid =
        Keeper_decision_audit.decision_pipeline_to_mermaid
          ?turn_outcome
          ~phase:current
          ~thompson_alpha:stats.alpha
          ~thompson_beta:stats.beta
          ()
      in
      let runtime_projection =
        state_diagram_runtime_projection
          (match meta with
           | Ok meta -> meta
           | Error _ -> None)
      in
      let runtime_fsm_mermaid =
        state_diagram_runtime_fsm_mermaid runtime_projection
      in
      (* Memory tier usage: join kind_caps (policy) with kind_counts (bank
         summary). Each kind reports used / cap so the dashboard tier
         panel can render saturation without re-reading the memory file.

         RFC-0149 §3.1: route the bank read through the typed Result
         resolver.  [memory_kind_usage] keeps its [`List …] shape for
         existing dashboard consumers
         (dashboard/src/components/keeper-memory-tier-panel.ts,
         dashboard/src/components/ide/ide-persistence-panel.ts).  The
         typed [Keeper_memory_recall_exn_class.t] label rides on the
         sibling [memory_kind_usage_error_class] field so an IO fault is
         distinguishable from "memory bank empty / no kinds recorded".  *)
      let used_by_kind, memory_kind_usage_error_class =
        match meta with
        | Ok (Some _) ->
          (match
             Keeper_memory.read_keeper_memory_summary_result
               (Mcp_server.workspace_config state)
               ~name ~max_bytes:120_000 ~max_lines:200 ~recent_limit:0
           with
           | Ok summary ->
             summary.Keeper_memory.kind_counts, None
           | Error exn_class ->
             [], Some (Keeper_memory_recall_exn_class.to_label exn_class))
        | _ -> [], None
      in
      let memory_kind_usage : Yojson.Safe.t =
        let caps = Keeper_memory_policy.kind_caps () in
        let lookup_used k =
          List.assoc_opt k used_by_kind |> Option.value ~default:0
        in
        `List (List.map (fun (kind, cap) ->
          let kind_wire = Keeper_memory_policy.memory_kind_to_wire kind in
          `Assoc [
            "kind", `String kind_wire;
            "used", `Int (lookup_used kind_wire);
            "cap", `Int cap;
            "priority", `Int (Keeper_memory_policy.priority_for_kind ~kind);
          ]) caps)
      in
      let memory_kind_usage_error_class_json : Yojson.Safe.t =
        Json_util.string_opt_to_json memory_kind_usage_error_class
      in
      (* Compaction sub-FSM: only emit a diagram when the keeper is in
         the [Compacting] phase. The three nodes mirror
         [specs/bug-models/MemoryCompaction.tla]. *)
      let compaction_submachine_mermaid =
        match current with
        | Keeper_state_machine.Compacting ->
          let b = Buffer.create 256 in
          Buffer.add_string b "stateDiagram-v2\n";
          Buffer.add_string b "    [*] --> Accumulating\n";
          Buffer.add_string b "    Accumulating --> Compacting: ratio_gate\n";
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
           ; "decision_pipeline_mermaid", `String decision_pipeline_mermaid
           ; "runtime_fsm_mermaid", `String runtime_fsm_mermaid
           ; "compaction_submachine_mermaid", compaction_submachine_mermaid
           ; "thompson_alpha", `Float stats.alpha
           ; "thompson_beta", `Float stats.beta
           ]
           @ runtime_projection_fields
           @ [ "memory_kind_usage", memory_kind_usage
             ; "memory_kind_usage_error_class", memory_kind_usage_error_class_json
             ])
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
  else if req_path = prefix ^ "regime" then
    (* 7th FSM axis MVP: fleet-wide behavioral-regime snapshot. Same
       purity contract as the composite route above, uses the
       [Keeper_behavioral_regime_observer] pure projection. *)
    let base_path = (Mcp_server.workspace_config state).base_path in
    let snapshots =
      Keeper_behavioral_regime_observer.all_snapshots ~base_path ()
    in
    let json =
      `Assoc [
        "generated_at", `String (Masc_domain.now_iso ());
        "count", `Int (List.length snapshots);
        "snapshots",
          `List
            (List.map
               Keeper_behavioral_regime_observer.snapshot_to_json
               snapshots);
      ]
    in
    Http.Response.json_value ~compress:true ~request:req json reqd
  else if ends_with "/regime" then
    (* Per-keeper behavioral-regime snapshot. *)
    let name = extract_name "/regime" in
    if String.length name = 0 then
      respond_error reqd "keeper name is required"
    else
      let base_path = (Mcp_server.workspace_config state).base_path in
      (match Keeper_registry.get ~base_path name with
       | None ->
         respond_error ~status:`Not_found reqd
           (Printf.sprintf "keeper %S not registered" name)
       | Some entry ->
         let snapshot =
           Keeper_behavioral_regime_observer.observe entry
         in
         let json =
           Keeper_behavioral_regime_observer.snapshot_to_json snapshot
         in
         Http.Response.json_value ~compress:true ~request:req json reqd)
  else
    respond_error ~status:`Not_found reqd "not found"
