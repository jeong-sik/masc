(** Memory subsystem dashboard HTTP JSON helpers. *)

open Server_utils

module StringMap = Map.Make (String)

let memory_subsystems_entry_cache_ttl_sec = 30.0

type memory_subsystems_entries = {
  rows : (string * Keeper_memory_policy.keeper_memory_line) list;
  errors : (string * string) list;
  keeper_names_known : bool option;
  keeper_name_discovery_read_errors : string list;
}

type memory_subsystems_entry_cache_entry = {
  base_path : string;
  cached_at : float;
  entries : memory_subsystems_entries;
}

type user_model_fact_read_error_source =
  | User_model_fact_store_parse
  | User_model_fact_store_read

type user_model_fact_read_error = {
  keeper : string;
  source : user_model_fact_read_error_source;
  path : string option;
  line_index : int option;
  error : string;
}

type user_model_facts = {
  items : (string * Keeper_memory_os_types.fact) list;
  fact_read_errors : user_model_fact_read_error list;
  keeper_ids_known : bool;
  keeper_id_discovery_read_errors : string list;
}

let empty_memory_subsystems_entries =
  {
    rows = [];
    errors = [];
    keeper_names_known = None;
    keeper_name_discovery_read_errors = [];
  }

(* RFC-0149 §3.1: cache holds typed errors alongside successful rows so the
   dashboard JSON can surface per-keeper Read failure class instead of silently
   swallowing them. *)
let memory_subsystems_entry_cache
  : memory_subsystems_entry_cache_entry option Atomic.t
  =
  Atomic.make None
;;

(** Single-flight mutex for refreshing the memory-subsystems cache. The cache
    itself is an [Atomic.t] so readers can check the TTL without contending for
    the lock; only a miss contends and one fiber performs the expensive IO. *)
let memory_subsystems_entry_cache_mu = Eio.Mutex.create ()
;;

let memory_quality_default_recent_limit = 500
let memory_quality_max_recent_limit = 2_000
let memory_quality_default_top_key_limit = 10
let memory_quality_max_top_key_limit = 100
let memory_quality_schema = "masc.memory_quality.recall_ledger.v1"
let memory_quality_source = "recall_injections"

let memory_quality_cache
  : (string * int * int * float * Yojson.Safe.t) option Atomic.t
  =
  Atomic.make None
;;

let memory_quality_cache_mu = Eio.Mutex.create ()
;;

let dashboard_memory_subsystems_include_entries request =
  bool_query_param request "include_memory_entries" ~default:false
  ||
  match query_param request "focus" |> Option.map String.trim with
  | Some "entries" -> true
  | _ -> false
;;

let load_memory_subsystems_entries ~(config : Workspace_utils.config) =
  (* NDT-OK: wall-clock read only gates a dashboard cache TTL. *)
  let now = Unix.gettimeofday () in
  let is_fresh = function
    | Some cached ->
      String.equal cached.base_path config.base_path
      && now -. cached.cached_at < memory_subsystems_entry_cache_ttl_sec
    | None -> false
  in
  match Atomic.get memory_subsystems_entry_cache with
  | Some cached when is_fresh (Some cached) -> cached.entries
  | _ ->
    Eio.Mutex.use_rw ~protect:true memory_subsystems_entry_cache_mu
    @@ fun () ->
    (match Atomic.get memory_subsystems_entry_cache with
     | Some cached when is_fresh (Some cached) -> cached.entries
     | _ ->
       let entries =
         match Keeper_meta_store.keeper_names_result config with
         | Error error ->
           {
             rows = [];
             errors = [];
             keeper_names_known = Some false;
             keeper_name_discovery_read_errors = [ error ];
           }
         | Ok names ->
           let rows, errors =
             names
             |> List.fold_left
                  (fun (rows_acc, errs_acc) keeper ->
                    match
                      Keeper_memory_recall.read_keeper_memory_summary_result
                        config
                        ~name:keeper
                        ~max_bytes:120000
                        ~max_lines:180
                        ~recent_limit:30
                    with
                    | Ok summary ->
                      let rows =
                        List.map
                          (fun (row : Keeper_memory_policy.keeper_memory_line) ->
                            keeper, row)
                          summary.recent_notes
                      in
                      List.rev_append rows rows_acc, errs_acc
                    | Error exn_class ->
                      let label =
                        Keeper_memory_recall_exn_class.to_label exn_class
                      in
                      rows_acc, (keeper, label) :: errs_acc)
                  ([], [])
           in
           {
             rows = List.rev rows;
             errors = List.rev errors;
             keeper_names_known = Some true;
             keeper_name_discovery_read_errors = [];
           }
       in
       Atomic.set memory_subsystems_entry_cache
         (Some { base_path = config.base_path; cached_at = now; entries });
       entries)
;;

let load_user_model_facts ~(config : Workspace_utils.config) =
  let now = Time_compat.now () in
  let base_path = config.base_path in
  let facts_path_for_keeper keeper_id =
    Keeper_memory_os_io.facts_path_for_keepers_dir
      ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path)
      ~keeper_id
  in
  let fact_parse_read_errors ~keeper_id errors =
    List.map
      (fun (error : Keeper_memory_os_io.fact_jsonl_parse_error) ->
        { keeper = keeper_id
        ; source = User_model_fact_store_parse
        ; path = Some error.path
        ; line_index = Some error.line_index
        ; error = Keeper_memory_os_io.fact_jsonl_parse_error_to_string error
        })
      errors
  in
  let fact_store_read_error ~keeper_id error =
    { keeper = keeper_id
    ; source = User_model_fact_store_read
    ; path = Some (facts_path_for_keeper keeper_id)
    ; line_index = None
    ; error
    }
  in
  match Keeper_memory_os_io.list_fact_store_keeper_ids_for_base_path_result ~base_path with
  | Error error ->
    {
      items = [];
      fact_read_errors = [];
      keeper_ids_known = false;
      keeper_id_discovery_read_errors = [ error ];
    }
  | Ok keeper_ids ->
    let items, errors =
      keeper_ids
      |> List.fold_left
           (fun (items_acc, errors_acc) keeper ->
              try
                match
                  Keeper_memory_os_io.read_facts_tail_with_errors_for_base_path
                    ~base_path
                    ~keeper_id:keeper
                    ~n:Keeper_memory_os_io.fact_store_max
                with
                | { parse_errors = _ :: _ as parse_errors; facts = _ } ->
                  items_acc, List.rev_append (fact_parse_read_errors ~keeper_id:keeper parse_errors) errors_acc
                | { facts; parse_errors = [] } ->
                  let items =
                    facts
                    |> List.filter Keeper_memory_os_types.fact_is_user_model
                    |> List.filter (Keeper_memory_os_types.fact_is_current ~now)
                    |> List.map (fun fact -> keeper, fact)
                  in
                  List.rev_append items items_acc, errors_acc
              with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn ->
                items_acc, fact_store_read_error ~keeper_id:keeper (Printexc.to_string exn) :: errors_acc)
           ([], [])
    in
    {
      items = List.rev items;
      fact_read_errors = List.rev errors;
      keeper_ids_known = true;
      keeper_id_discovery_read_errors = [];
    }
;;

let user_model_prompt_json () =
  `Assoc
    [ "enabled", `Bool (Keeper_user_model.enabled ())
    ; "block_id", `String (Prompt_block_id.to_string Prompt_block_id.User_model)
    ; "injection", `String "extra_system_context"
    ; "runtime_hook", `String "keeper_run_tools_hooks.before_turn_params"
    ; "producer", `String "keeper_user_model"
    ]
;;

let user_model_fact_read_error_source_to_string = function
  | User_model_fact_store_parse -> "user_model_fact_store_parse"
  | User_model_fact_store_read -> "user_model_fact_store_read"
;;

let user_model_fact_read_error_to_json error =
  let fields =
    [ ( "source"
      , `String (user_model_fact_read_error_source_to_string error.source) )
    ; "keeper", `String error.keeper
    ; "error", `String error.error
    ]
  in
  let fields =
    match error.path with
    | None -> fields
    | Some path -> fields @ [ "path", `String path ]
  in
  let fields =
    match error.line_index with
    | None -> fields
    | Some line_index -> fields @ [ "line_index", `Int line_index ]
  in
  `Assoc fields
;;

(* The Hebbian synapse weight is a DISPLAY-only saturation scale for the
   dashboard graph, not a learned or normalized synaptic strength: a keeper pair
   reaches [max_synapse_weight] once they co-observe [synapse_saturation_facts]
   shared facts, scaling linearly below that. Named so the scale is explicit and
   reviewable rather than an unexplained literal (it drives no behavior — purely
   how thick the dashboard edge renders). *)
let max_synapse_weight = 1.0
let synapse_saturation_facts = 10.0

let hebbian_read_error_json ?(source = "memory_os_shared_facts") ?path ?line_index error =
  let fields = [ "source", `String source; "error", `String error ] in
  let fields =
    match path with
    | Some value -> fields @ [ "path", `String value ]
    | None -> fields
  in
  let fields =
    match line_index with
    | Some value -> fields @ [ "line_index", `Int value ]
    | None -> fields
  in
  `Assoc fields
;;

let hebbian_fact_parse_read_errors errors =
  List.map
    (fun (error : Keeper_memory_os_io.fact_jsonl_parse_error) ->
      hebbian_read_error_json
        ~source:"memory_os_shared_fact_store_parse"
        ~path:error.path
        ~line_index:error.line_index
        (Keeper_memory_os_io.fact_jsonl_parse_error_to_string error))
    errors
;;

let hebbian_json ~known ~synapses ~last_consolidation ~read_errors =
  `Assoc
    [ "synapses", `List synapses
    ; "last_consolidation", `Float last_consolidation
    ; "hebbian_known", `Bool known
    ; "read_error_count", `Int (List.length read_errors)
    ; "read_errors", `List read_errors
    ]
;;

(* RFC-0244 Tier 2: derive the Hebbian synapse view from cross-keeper
   corroboration. Each shared fact that was observed by multiple keepers
   becomes one or more synapses; [last_consolidation] is the most recent
   verification timestamp of any shared fact. Before this, the field was a
   hardcoded placeholder that always reported an empty graph and
   last_consolidation=0.0, so recorded memory appeared unviewable. *)
let compute_hebbian ~base_path ~now () =
  try
    let keepers_dir =
      Config_dir_resolver.keepers_dir_for_base_path ~base_path
    in
    match
      Keeper_memory_os_io.read_facts_all_with_errors_for_keepers_dir
        ~keepers_dir
        ~keeper_id:Keeper_memory_os_types.shared_store_id
    with
    | { parse_errors = _ :: _ as parse_errors; facts = _ } ->
      let read_errors = hebbian_fact_parse_read_errors parse_errors in
      let first_error =
        match parse_errors with
        | first :: _ -> Keeper_memory_os_io.fact_jsonl_parse_error_to_string first
        | [] -> "unavailable"
      in
      Log.Server.warn
        "compute_hebbian: shared fact store parse errors count=%d first=%s"
        (List.length parse_errors)
        first_error;
      hebbian_json
        ~known:false
        ~synapses:[]
        ~last_consolidation:0.0
        ~read_errors
    | { facts; parse_errors = [] } ->
      let shared_facts =
        facts |> List.filter (Keeper_memory_os_types.fact_is_current ~now)
      in
      (* [last_consolidation] is the most recent [last_verified_at] of any
         current shared fact, not the timestamp of the last consolidator run.
         The name matches the dashboard schema; the value is fact-derived because
         the shared store is the SSOT for cross-keeper corroboration. *)
      let last_consolidation =
        shared_facts
        |> List.filter_map (fun (f : Keeper_memory_os_types.fact) -> f.last_verified_at)
        |> List.fold_left Float.max 0.0
      in
      let synapse_counts : ((string * string), int) Hashtbl.t = Hashtbl.create 16 in
      shared_facts
      |> List.iter (fun (fact : Keeper_memory_os_types.fact) ->
        (* Dedupe within a single fact so a duplicate observer cannot inflate the
           synapse count, and convert to an array for O(1) pairwise indexing. *)
        let keepers =
          fact.observed_by
          |> List.sort_uniq String.compare
          |> Array.of_list
        in
        let n = Array.length keepers in
        for i = 0 to n - 1 do
          for j = i + 1 to n - 1 do
            let a = keepers.(i) in
            let b = keepers.(j) in
            let key = if String.compare a b <= 0 then a, b else b, a in
            let prev = Option.value (Hashtbl.find_opt synapse_counts key) ~default:0 in
            Hashtbl.replace synapse_counts key (prev + 1)
          done
        done);
      let synapses =
        Hashtbl.fold
          (fun (a, b) count acc ->
             let weight =
               Float.min max_synapse_weight (float_of_int count /. synapse_saturation_facts)
             in
             `Assoc
               [ "from_agent", `String a
               ; "to_agent", `String b
               ; "weight", `Float weight
               ]
             :: acc)
          synapse_counts
          []
      in
      hebbian_json
        ~known:true
        ~synapses
        ~last_consolidation
        ~read_errors:[]
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    let error = Printexc.to_string exn in
    Log.Server.warn
      "compute_hebbian: synapse view derivation failed, marking Hebbian graph \
       unknown: %s"
      error;
    let shared_facts_path =
      try
        Ok
          (Keeper_memory_os_io.facts_path_for_keepers_dir
             ~keepers_dir:
               (Config_dir_resolver.keepers_dir_for_base_path ~base_path)
             ~keeper_id:Keeper_memory_os_types.shared_store_id)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> Error (Printexc.to_string exn)
    in
    let read_errors =
      match shared_facts_path with
      | Ok path -> [ hebbian_read_error_json ~path error ]
      | Error path_error ->
        [ hebbian_read_error_json error
        ; `Assoc
            [ "source", `String "memory_os_shared_facts_path"
            ; "error", `String path_error
            ]
        ]
    in
    hebbian_json
      ~known:false
      ~synapses:[]
      ~last_consolidation:0.0
      ~read_errors
;;

let dashboard_memory_quality_recent_limit request =
  int_query_param
    request
    "memory_quality_limit"
    ~default:memory_quality_default_recent_limit
  |> clamp ~min_v:1 ~max_v:memory_quality_max_recent_limit
;;

let dashboard_memory_quality_top_key_limit request =
  int_query_param
    request
    "memory_quality_top_key_limit"
    ~default:memory_quality_default_top_key_limit
  |> clamp ~min_v:1 ~max_v:memory_quality_max_top_key_limit
;;

type memory_quality_rows =
  { records : Keeper_recall_injection_ledger.record list
  ; decode_error_records : int
  }

let load_recall_quality_records ~(config : Workspace_utils.config) ~sample_limit =
  try
    let masc_root = Workspace_utils.masc_dir config in
    let store =
      Dated_jsonl.create
        ~base_dir:(Keeper_recall_injection_ledger.base_dir ~masc_root)
        ()
    in
    let records, decode_error_records =
      Dated_jsonl.read_recent_lines store sample_limit
      |> List.fold_left
           (fun (records_acc, decode_errors) line ->
              match Yojson.Safe.from_string line with
              | exception Yojson.Json_error _ -> records_acc, decode_errors + 1
              | json ->
                (match Keeper_recall_injection_ledger.record_of_json_result json with
                 | Ok record -> record :: records_acc, decode_errors
                 | Error _ -> records_acc, decode_errors + 1))
           ([], 0)
    in
    Ok { records = List.rev records; decode_error_records }
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Keeper_recall_injection_ledger.error_label_of_exn exn)
;;

let increment_count key counts =
  let next =
    match StringMap.find_opt key counts with
    | Some count -> count + 1
    | None -> 1
  in
  StringMap.add key next counts
;;

let sorted_counts counts =
  StringMap.bindings counts
  |> List.sort (fun (key_a, count_a) (key_b, count_b) ->
    let count_order = compare count_b count_a in
    if count_order <> 0 then count_order else String.compare key_a key_b)
;;

let count_rows_by ?(limit = max_int) pairs =
  pairs
  |> List.filteri (fun i _ -> i < limit)
  |> List.map (fun (key, count) ->
    `Assoc [ "key", `String key; "count", `Int count ])
;;

type recall_quality_summary =
  { sampled_records : int
  ; records_with_recall : int
  ; failure_records : int
  ; decode_error_records : int
  ; fact_counts : int StringMap.t
  ; failure_counts : int StringMap.t
  ; total_fact_injections : int
  ; error : string option
  }

let empty_recall_quality_summary ~decode_error_records ~error =
  { sampled_records = 0
  ; records_with_recall = 0
  ; failure_records = 0
  ; decode_error_records
  ; fact_counts = StringMap.empty
  ; failure_counts = StringMap.empty
  ; total_fact_injections = 0
  ; error
  }
;;

let summarize_recall_quality ({ records; decode_error_records } : memory_quality_rows) =
  let initial = empty_recall_quality_summary ~decode_error_records ~error:None in
  List.fold_left
    (fun summary (record : Keeper_recall_injection_ledger.record) ->
       let failure_counts =
         match record.failure_reason with
         | None -> summary.failure_counts
         | Some reason ->
           let reason =
             Keeper_recall_injection_ledger.bounded_failure_reason_label reason
           in
           increment_count reason summary.failure_counts
       in
       let has_recall =
         record.injected_fact_keys <> [] || record.injected_episode_keys <> []
       in
       let fact_counts, total_fact_injections =
         List.fold_left
           (fun (counts, total) key -> increment_count key counts, total + 1)
           (summary.fact_counts, summary.total_fact_injections)
           record.injected_fact_keys
       in
       { summary with
         sampled_records = summary.sampled_records + 1
       ; records_with_recall =
           summary.records_with_recall + (if has_recall then 1 else 0)
       ; failure_records =
           summary.failure_records
           + (if Option.is_some record.failure_reason then 1 else 0)
       ; failure_counts
       ; fact_counts
       ; total_fact_injections
       })
    initial
    records
;;

let recall_quality_summary_json ~sample_limit ~top_key_limit summary =
  let fact_count_rows = sorted_counts summary.fact_counts in
  let echoed_fact_keys =
    List.fold_left
      (fun acc (_key, count) -> if count > 1 then acc + 1 else acc)
      0
      fact_count_rows
  in
  let max_fact_echo_count =
    match fact_count_rows with
    | (_key, count) :: _ -> count
    | [] -> 0
  in
  `Assoc
    [ "schema", `String memory_quality_schema
    ; "source", `String memory_quality_source
    ; "sample_limit", `Int sample_limit
    ; "sampled_records", `Int summary.sampled_records
    ; "records_with_recall", `Int summary.records_with_recall
    ; ( "empty_recall_records"
      , `Int (summary.sampled_records - summary.records_with_recall) )
    ; "failure_records", `Int summary.failure_records
    ; "decode_error_records", `Int summary.decode_error_records
    ; "failure_reasons", `List (count_rows_by (sorted_counts summary.failure_counts))
    ; ( "fact_injections"
      , `Assoc
          [ "total", `Int summary.total_fact_injections
          ; "unique_fact_keys", `Int (List.length fact_count_rows)
          ; "echoed_fact_keys", `Int echoed_fact_keys
          ; "max_fact_echo_count", `Int max_fact_echo_count
          ; ( "top_echoed_fact_keys"
            , `List
                (count_rows_by
                   ~limit:top_key_limit
                   (List.filter (fun (_key, count) -> count > 1) fact_count_rows))
            )
          ] )
    ; "outcome_joined", `Bool false
    ; "useful_recalls", `Null
    ; "stale_recalls", `Null
    ; "loop_reductions", `Null
    ; "error", (match summary.error with Some label -> `String label | None -> `Null)
    ]
;;

let compute_memory_quality_dashboard_json
      ~(config : Workspace_utils.config)
      ~sample_limit
      ~top_key_limit
  =
  match load_recall_quality_records ~config ~sample_limit with
  | Ok rows ->
    rows
    |> summarize_recall_quality
    |> recall_quality_summary_json ~sample_limit ~top_key_limit
  | Error label ->
    empty_recall_quality_summary ~decode_error_records:0 ~error:(Some label)
    |> recall_quality_summary_json ~sample_limit ~top_key_limit
;;

let memory_quality_dashboard_json
      ~(config : Workspace_utils.config)
      ~sample_limit
      ~top_key_limit
  =
  (* NDT-OK: wall-clock read only gates the dashboard quality cache TTL. *)
  let now = Unix.gettimeofday () in
  let cache_matches = function
    | Some (base_path, cached_sample_limit, cached_top_key_limit, cached_at, _json) ->
      String.equal base_path config.base_path
      && cached_sample_limit = sample_limit
      && cached_top_key_limit = top_key_limit
      && now -. cached_at < memory_subsystems_entry_cache_ttl_sec
    | None -> false
  in
  match Atomic.get memory_quality_cache with
  | Some (_base_path, _sample_limit, _top_key_limit, _cached_at, json) as cached
    when cache_matches cached -> json
  | _ ->
    Eio.Mutex.use_rw ~protect:true memory_quality_cache_mu
    @@ fun () ->
    (match Atomic.get memory_quality_cache with
     | Some (_base_path, _sample_limit, _top_key_limit, _cached_at, json) as cached
       when cache_matches cached -> json
     | _ ->
       let json =
         compute_memory_quality_dashboard_json ~config ~sample_limit ~top_key_limit
       in
       Atomic.set memory_quality_cache
         (Some (config.base_path, sample_limit, top_key_limit, now, json));
       json)
;;

let dashboard_memory_subsystems_http_json
      ~(config : Workspace_utils.config)
      ?include_memory_entries
      request
  : Yojson.Safe.t
  =
  let include_memory_entries =
    Option.value
      include_memory_entries
      ~default:(dashboard_memory_subsystems_include_entries request)
  in
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:500 in
  let memory_quality_limit = dashboard_memory_quality_recent_limit request in
  let memory_quality_top_key_limit = dashboard_memory_quality_top_key_limit request in
  let keeper_filter =
    query_param request "keeper"
    |> Option.map String.trim
    |> Fun.flip Option.bind (fun s -> if s = "" then None else Some s)
  in
  let outcome_filter =
    query_param request "outcome"
    |> Option.map String.trim
    |> Fun.flip Option.bind (fun s -> if s = "" then None else Some s)
  in
  let search =
    query_param request "q"
    |> Option.map (fun s -> String.trim s |> String.lowercase_ascii)
    |> Fun.flip Option.bind (fun s -> if s = "" then None else Some s)
  in
  let now = Unix.gettimeofday () in
  let hebbian = compute_hebbian ~base_path:config.base_path ~now () in
  let institution_episode_read_error_json ~source ?path error =
    `Assoc
      ([
         ("source", `String source);
         ("error", `String error);
       ]
       @
       match path with
       | Some value -> [ ("path", `String value) ]
       | None -> [])
  in
  let all_episodes, episode_read_errors =
    try
      let path = Institution_eio.episodes_jsonl_path () in
      try
        (Institution_eio.load_recent_episodes_jsonl ~limit:max_int, [])
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        ( []
        , [ institution_episode_read_error_json
              ~source:"institution_episodes_jsonl"
              ~path
              (Printexc.to_string exn)
          ] )
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      ( []
      , [ institution_episode_read_error_json
            ~source:"institution_episodes_jsonl_path"
            (Printexc.to_string exn)
        ] )
  in
  let episodes_known =
    match episode_read_errors with
    | [] -> true
    | _ -> false
  in
  let total = List.length all_episodes in
  (* Empty filter [q] used to match all episodes; preserve that and
     delegate non-empty matching to the SSOT helper, which scans byte by
     byte without lowercasing the haystack or allocating per position. *)
  let contains_ci haystack needle =
    String.length needle = 0 || String_util.contains_substring_ci haystack needle
  in
  let memory_entry_to_json
        (keeper : string)
        (row : Keeper_memory_policy.keeper_memory_line)
    : Yojson.Safe.t
    =
    `Assoc
      [ "keeper", `String keeper
      ; "kind", `String row.kind
      ; "text", `String row.text
      ; "priority", `Int row.priority
      ; "ts_unix", `Float row.ts_unix
      ]
  in
  let user_model_item_to_json
        (keeper : string)
        (fact : Keeper_memory_os_types.fact)
    : Yojson.Safe.t
    =
    `Assoc
      [ "keeper", `String keeper
      ; "kind", `String (Keeper_memory_os_types.category_to_string fact.category)
      ; "claim", `String fact.claim
      ; ( "source_ref"
        , `String
            (Skill_candidate_projection.source_memory_fact_ref ~agent_name:keeper fact)
        )
      ; "source_trace_id", `String fact.source.trace_id
      ; "source_turn", `Int fact.source.turn
      ; "first_seen", `Float fact.first_seen
      ; ( "last_verified_at"
        , match fact.last_verified_at with
          | Some ts -> `Float ts
          | None -> `Null )
      ; ( "observed_by"
        , `List (List.map (fun keeper -> `String keeper) fact.observed_by) )
      ]
  in
  let memory_subsystems_entries =
    if include_memory_entries
    then load_memory_subsystems_entries ~config
    else empty_memory_subsystems_entries
  in
  let all_memory_entries = memory_subsystems_entries.rows in
  let memory_entry_errors = memory_subsystems_entries.errors in
  let user_model_facts = load_user_model_facts ~config in
  let all_user_model_items = user_model_facts.items in
  let user_model_errors = user_model_facts.fact_read_errors in
  let memory_total = List.length all_memory_entries in
  let memory_filtered =
    all_memory_entries
    |> List.filter (fun (keeper, (row : Keeper_memory_policy.keeper_memory_line)) ->
      let keeper_ok =
        match keeper_filter with
        | None -> true
        | Some k -> String.equal keeper k
      in
      let search_ok =
        match search with
        | None -> true
        | Some q ->
          contains_ci keeper q || contains_ci row.kind q || contains_ci row.text q
      in
      keeper_ok && search_ok)
  in
  let memory_filtered_total = List.length memory_filtered in
  let memory_entries =
    memory_filtered
    |> List.sort
         (fun
             (_, (a : Keeper_memory_policy.keeper_memory_line))
              (_, (b : Keeper_memory_policy.keeper_memory_line))
            -> compare b.ts_unix a.ts_unix)
    |> take limit
  in
  let user_model_filtered =
    all_user_model_items
    |> List.filter (fun (keeper, (fact : Keeper_memory_os_types.fact)) ->
      let keeper_ok =
        match keeper_filter with
        | None -> true
        | Some k -> String.equal keeper k
      in
      let search_ok =
        match search with
        | None -> true
        | Some q ->
          contains_ci keeper q
          || contains_ci (Keeper_memory_os_types.category_to_string fact.category) q
          || contains_ci fact.claim q
      in
      keeper_ok && search_ok)
  in
  let user_model_items =
    user_model_filtered
    |> List.sort
         (fun
             (_, (a : Keeper_memory_os_types.fact))
            (_, (b : Keeper_memory_os_types.fact))
            ->
            Float.compare
              (Keeper_memory_os_types.reference_time b)
              (Keeper_memory_os_types.reference_time a))
    |> take limit
  in
  let filtered =
    all_episodes
    |> List.filter (fun (e : Institution_eio.episode) ->
      let keeper_ok =
        match keeper_filter with
        | None -> true
        | Some k -> List.mem k e.participants
      in
      let outcome_ok =
        match outcome_filter with
        | None -> true
        | Some "success" -> e.outcome = `Success
        | Some "failure" -> e.outcome = `Failure
        | Some "partial" -> e.outcome = `Partial
        | Some _ -> true
      in
      let search_ok =
        match search with
        | None -> true
        | Some q ->
          contains_ci e.summary q
          || contains_ci e.event_type q
          || List.exists (fun l -> contains_ci l q) e.learnings
          || List.exists (fun p -> contains_ci p q) e.participants
      in
      keeper_ok && outcome_ok && search_ok)
  in
  let filtered_total = List.length filtered in
  let episodes =
    let rec drop n = function
      | [] -> []
      | rest when n <= 0 -> rest
      | _ :: rest -> drop (n - 1) rest
    in
    if filtered_total <= limit then filtered else drop (filtered_total - limit) filtered
  in
  let known_keepers =
    let episode_keepers =
      all_episodes
      |> List.concat_map (fun (e : Institution_eio.episode) -> e.participants)
    in
    let memory_keepers = List.map fst all_memory_entries in
    let user_model_keepers = List.map fst all_user_model_items in
    episode_keepers @ memory_keepers @ user_model_keepers
    |> List.sort_uniq String.compare
  in
  let known_memory_kinds =
    all_memory_entries
    |> List.map (fun (_, (row : Keeper_memory_policy.keeper_memory_line)) -> row.kind)
    |> List.sort_uniq String.compare
  in
  let draft_skill_candidates =
    match Skill_candidate_store.list_drafts ~base_path:config.base_path ~limit with
    | Ok listing ->
      `Assoc
        [ "total", `Int listing.total
        ; "shown", `Int listing.shown
        ; "limit", `Int listing.limit
        ; "index_path", `String listing.index_path
        ; ( "items"
          , `List (List.map Skill_candidate_store.draft_summary_to_json listing.items) )
        ; "error", `Null
        ]
    | Error msg ->
      `Assoc
        [ "total", `Int 0
        ; "shown", `Int 0
        ; "limit", `Int limit
        ; "index_path", `String (Skill_candidate_store.index_path ~base_path:config.base_path)
        ; "items", `List []
        ; "error", `String msg
        ]
  in
  let delegation_requests =
    match
      Keeper_delegation_request_store.list_requests ~base_path:config.base_path
        ~limit
    with
    | Ok listing ->
      `Assoc
        [ "total", `Int listing.total
        ; "shown", `Int listing.shown
        ; "limit", `Int listing.limit
        ; "index_path", `String listing.index_path
        ; ( "items"
          , `List
              (List.map
                 Keeper_delegation_request_store.request_summary_to_json
                 listing.items) )
        ; "error", `Null
        ]
    | Error msg ->
      `Assoc
        [ "total", `Int 0
        ; "shown", `Int 0
        ; "limit", `Int limit
        ; ( "index_path"
          , `String
              (Keeper_delegation_request_store.index_path
                 ~base_path:config.base_path) )
        ; "items", `List []
        ; "error", `String msg
        ]
  in
  let memory_keeper_names_known_json =
    match memory_subsystems_entries.keeper_names_known with
    | Some value -> `Bool value
    | None -> `Null
  in
  let memory_keeper_name_discovery_read_errors =
    List.map
      (fun error ->
        `Assoc [ "source", `String "keeper_names_result"; "error", `String error ])
      memory_subsystems_entries.keeper_name_discovery_read_errors
  in
  let memory_entry_read_errors =
    List.map
      (fun (keeper, error_class) ->
        `Assoc
          [ "source", `String "read_keeper_memory_summary_result"
          ; "keeper", `String keeper
          ; "error_class", `String error_class
          ])
      memory_entry_errors
  in
  let memory_read_errors =
    memory_keeper_name_discovery_read_errors @ memory_entry_read_errors
  in
  let user_model_keeper_id_discovery_read_errors =
    List.map
      (fun error ->
        `Assoc
          [ "source", `String "list_fact_store_keeper_ids_for_base_path"
          ; "error", `String error
          ])
      user_model_facts.keeper_id_discovery_read_errors
  in
  let user_model_fact_read_errors =
    List.map user_model_fact_read_error_to_json user_model_errors
  in
  let user_model_read_errors =
    user_model_keeper_id_discovery_read_errors @ user_model_fact_read_errors
  in
  `Assoc
    [ "generated_at", `String (Masc_domain.now_iso ())
    ; "hebbian", hebbian
    ; ( "memory_quality"
      , memory_quality_dashboard_json
          ~config
          ~sample_limit:memory_quality_limit
          ~top_key_limit:memory_quality_top_key_limit )
    ; ( "episodes"
      , `Assoc
          [ "total", `Int total
          ; "episodes_known", `Bool episodes_known
          ; "filtered", `Int filtered_total
          ; "shown", `Int (List.length episodes)
          ; "limit", `Int limit
          ; "read_error_count", `Int (List.length episode_read_errors)
          ; "read_errors", `List episode_read_errors
          ; "items", `List (List.map Institution_eio.episode_to_json episodes)
          ] )
    ; ( "memory_entries"
      , `Assoc
          [ "total", `Int memory_total
          ; "filtered", `Int memory_filtered_total
          ; "shown", `Int (List.length memory_entries)
          ; "limit", `Int limit
          ; "keeper_names_known", memory_keeper_names_known_json
          ; ( "keeper_name_discovery_read_error_count"
            , `Int (List.length memory_keeper_name_discovery_read_errors) )
          ; ( "keeper_name_discovery_read_errors"
            , `List memory_keeper_name_discovery_read_errors )
          ; "read_error_count", `Int (List.length memory_read_errors)
          ; "read_errors", `List memory_read_errors
          ; ( "items"
            , `List
                (List.map
                   (fun (keeper, row) -> memory_entry_to_json keeper row)
                   memory_entries) )
          ; ( "errors"
            , `List
                (List.map
                   (fun (keeper, error_class) ->
                     `Assoc
                       [ "keeper", `String keeper
                       ; "error_class", `String error_class
                       ])
                   memory_entry_errors) )
          ] )
    ; ( "user_model"
      , `Assoc
          [ "schema", `String "masc.user_model.memory_projection.v1"
          ; "source", `String "memory_os_facts"
          ; "prompt", user_model_prompt_json ()
          ; "total", `Int (List.length all_user_model_items)
          ; "filtered", `Int (List.length user_model_filtered)
          ; "shown", `Int (List.length user_model_items)
          ; "limit", `Int limit
          ; "keeper_ids_known", `Bool user_model_facts.keeper_ids_known
          ; ( "keeper_id_discovery_read_error_count"
            , `Int (List.length user_model_keeper_id_discovery_read_errors) )
          ; ( "keeper_id_discovery_read_errors"
            , `List user_model_keeper_id_discovery_read_errors )
          ; "read_error_count", `Int (List.length user_model_read_errors)
          ; "read_errors", `List user_model_read_errors
          ; ( "items"
            , `List
                (List.map
                   (fun (keeper, fact) -> user_model_item_to_json keeper fact)
                   user_model_items) )
          ; ( "errors"
            , `List
                (List.map
                   (fun error ->
                     `Assoc
                       [ "keeper", `String error.keeper
                       ; "error", `String error.error
                       ])
                   user_model_errors) )
          ] )
    ; "draft_skill_candidates", draft_skill_candidates
    ; "delegation_requests", delegation_requests
    ; ( "filters"
      , `Assoc
          [ "keepers", `List (List.map (fun k -> `String k) known_keepers)
          ; "outcomes", `List [ `String "success"; `String "partial"; `String "failure" ]
          ; "memory_kinds", `List (List.map (fun k -> `String k) known_memory_kinds)
          ] )
    ]
;;
