(** Memory subsystem dashboard HTTP JSON helpers. *)

open Server_utils

module StringMap = Map.Make (String)

let memory_subsystems_entry_cache_ttl_sec = 30.0

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

(* masc#25052: the ledger now writes v2 delta rows (only the keys that
   changed since the keeper's previous row), so a raw [record] no longer
   carries the full injected set on its own. [Keeper_recall_injection_ledger
   .materialize] replays [payload] per keeper over this sample (already
   chronological -- see [load_recall_quality_records] below) to reconstruct
   it. This is exact whenever the sample includes a keeper's own genesis row,
   which is far more likely now than under the old schema: v2 rows are only
   written when the injected set actually changes, so a fixed-size recent
   sample now spans much more of each keeper's real history. Legacy
   (schema v1) rows replay to exactly their own list, so this is a
   behavior-preserving generalization for any all-legacy sample (e.g. the
   existing fixtures in test_server_dashboard_http_memory_subsystems.ml). *)
let summarize_recall_quality ({ records; decode_error_records } : memory_quality_rows) =
  let initial = empty_recall_quality_summary ~decode_error_records ~error:None in
  records
  |> Keeper_recall_injection_ledger.materialize
  |> List.fold_left
       (fun summary (m : Keeper_recall_injection_ledger.materialized) ->
          let failure_counts =
            match m.record.failure_reason with
            | None -> summary.failure_counts
            | Some reason ->
              let reason =
                Keeper_recall_injection_ledger.bounded_failure_reason_label reason
              in
              increment_count reason summary.failure_counts
          in
          let has_recall = m.fact_keys <> [] || m.episode_keys <> [] in
          let fact_counts, total_fact_injections =
            List.fold_left
              (fun (counts, total) key -> increment_count key counts, total + 1)
              (summary.fact_counts, summary.total_fact_injections)
              m.fact_keys
          in
          { summary with
            sampled_records = summary.sampled_records + 1
          ; records_with_recall =
              summary.records_with_recall + (if has_recall then 1 else 0)
          ; failure_records =
              summary.failure_records
              + (if Option.is_some m.record.failure_reason then 1 else 0)
          ; failure_counts
          ; fact_counts
          ; total_fact_injections
          })
       initial
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
      request
  : Yojson.Safe.t
  =
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:500 in
  let memory_quality_limit = dashboard_memory_quality_recent_limit request in
  let memory_quality_top_key_limit = dashboard_memory_quality_top_key_limit request in
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
  `Assoc
    [ "generated_at", `String (Masc_domain.now_iso ())
    ; ( "memory_quality"
      , memory_quality_dashboard_json
          ~config
          ~sample_limit:memory_quality_limit
          ~top_key_limit:memory_quality_top_key_limit )
    ; "delegation_requests", delegation_requests
    ]
;;
