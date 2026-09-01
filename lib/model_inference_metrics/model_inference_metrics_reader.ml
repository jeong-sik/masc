(** Model_inference_metrics_reader — JSONL file readers for
    {!Model_inference_metrics}.

    Reads keeper [decisions.jsonl] files plus inference-level
    date-split [costs] rows, merges duplicate
    samples between the two sources, and exposes coverage helpers used
    by the aggregate stage.

    Stage 04 of the godfile decomposition build plan
    (docs/audit/2026-05-18-godfile-decomposition-build-plan.html, Lane A).
    Internal sibling module of the facade; do not call directly from
    outside the library. *)

open Model_inference_metrics_entry
open Model_inference_metrics_parser

(* ── Read decisions.jsonl files ─────────────────────────── *)

let read_all_decisions ~base_path ~since_unix : raw_entry list =
  let keeper_dir =
    Common.keepers_runtime_dir_of_base ~base_path
  in
  if not (Sys.file_exists keeper_dir)
  then []
  else (
    let files =
      Sys.readdir keeper_dir
      |> Array.to_list
      |> List.filter (fun f ->
        String.length f > 16 && Filename.check_suffix f ".decisions.jsonl")
      |> List.sort String.compare
    in
    List.concat_map
      (fun fname ->
         let path = Filename.concat keeper_dir fname in
         try
           Fs_compat.fold_jsonl_lines
             ~init:[]
             ~f:(fun acc ~line_no json ->
               match parse_telemetry_entry json ~since_unix with
               | Ok e -> e :: acc
               | Error err ->
                 if parse_error_is_schema_violation err
                 then
                   Log.Model_inference_metrics.warn "decisions.jsonl parse drop: %s:%d reason=%s"
                     path
                     line_no
                     (parse_error_label err);
                 acc)
             path
         with
         | Eio.Cancel.Cancelled _ as exn ->
           let bt = Printexc.get_raw_backtrace () in
           Printexc.raise_with_backtrace exn bt
         | exn ->
           Log.Model_inference_metrics.error
             "decisions.jsonl read failed: path=%s detail=%s"
             path
             (Printexc.to_string exn);
           [])
      files)
;;

let read_cost_entries_dated ~base_path ~since_unix
  : (raw_entry list * cost_read_diagnostics, Dated_jsonl.read_error) result
  =
  let store = Cost_ledger.store_of_base_path ~base_path in
  let entries = ref [] in
  let malformed_rows = ref 0 in
  let schema_violation_rows = ref 0 in
  let now = Time_compat.now () in
  match
    Dated_jsonl.iter_range_entries_result
      store
      ~since:(Log.format_utc_date_of since_unix)
      ~until:(Log.format_utc_date_of now)
      (function
        | Dated_jsonl.Parsed json ->
          (match Cost_ledger.of_json json with
           | Ok { usage_projection = Cost_ledger.Raw_observation; _ } -> ()
           | Ok _ | Error _ ->
             (match parse_cost_entry json ~since_unix with
              | Ok entry -> entries := entry :: !entries
              | Error Out_of_window -> ()
              | Error err ->
                incr schema_violation_rows;
                Log.Model_inference_metrics.warn
                  "cost ledger schema drop: reason=%s detail=%s"
                  (parse_error_label err)
                  (parse_error_detail err)))
        | Dated_jsonl.Malformed_json { path; line_number; detail } ->
          incr malformed_rows;
          let location =
            match line_number with
            | Some line_number -> Printf.sprintf "%s:%d" path line_number
            | None -> path
          in
          Log.Model_inference_metrics.warn
            "cost ledger malformed row: %s detail=%s"
            location
            detail)
  with
  | Ok () ->
    Ok
      ( List.rev !entries
      , { malformed_rows = !malformed_rows
        ; schema_violation_rows = !schema_violation_rows
        ; identity_conflict_rows = 0
        } )
  | Error error -> Error error
;;

let read_cost_entries ~base_path ~since_unix =
  read_cost_entries_dated ~base_path ~since_unix
;;

module Inference_identity_map = Map.Make (struct
    type t = Cost_ledger.inference_identity

    let compare = Cost_ledger.compare_inference_identity
  end)

type identity_bucket =
  { decisions : raw_entry list
  ; costs : raw_entry list
  }

let empty_identity_bucket = { decisions = []; costs = [] }

let value_or ~preferred ~fallback =
  match preferred with
  | Some _ -> preferred
  | None -> fallback
;;

let merge_exact_inference decision cost =
  { model = cost.model
  ; provider = value_or ~preferred:cost.provider ~fallback:decision.provider
  ; inference_identity = cost.inference_identity
  ; ts_unix = cost.ts_unix
  ; outcome = decision.outcome
  ; stop_reason = decision.stop_reason
  ; turn_lane = decision.turn_lane
  ; tok_per_sec =
      value_or ~preferred:cost.tok_per_sec ~fallback:decision.tok_per_sec
  ; prompt_tok_per_sec =
      value_or
        ~preferred:cost.prompt_tok_per_sec
        ~fallback:decision.prompt_tok_per_sec
  ; hw_decode_tok_per_sec =
      value_or
        ~preferred:cost.hw_decode_tok_per_sec
        ~fallback:decision.hw_decode_tok_per_sec
  ; peak_memory_gb =
      value_or ~preferred:cost.peak_memory_gb ~fallback:decision.peak_memory_gb
  ; thinking_enabled = decision.thinking_enabled
  ; latency_ms = value_or ~preferred:cost.latency_ms ~fallback:decision.latency_ms
  ; (* Decision usage is the single normalized per-turn authority. Cost rows
       retain the provider observation and may be conversation-cumulative. *)
    input_tokens = decision.input_tokens
  ; output_tokens = decision.output_tokens
  ; cache_read_tokens = decision.cache_read_tokens
  ; cache_creation_tokens = decision.cache_creation_tokens
  ; reasoning_tokens =
      value_or
        ~preferred:cost.reasoning_tokens
        ~fallback:decision.reasoning_tokens
  ; cost_usd = decision.cost_usd
  ; tool_call_count = decision.tool_call_count
  ; tools_used = decision.tools_used
  ; usage_reported = decision.usage_reported
  ; telemetry_reported =
      value_or
        ~preferred:cost.telemetry_reported
        ~fallback:decision.telemetry_reported
  ; usage_trust =
      value_or ~preferred:cost.usage_trust ~fallback:decision.usage_trust
  ; usage_anomaly_reasons =
      List.sort_uniq
        String.compare
        (decision.usage_anomaly_reasons @ cost.usage_anomaly_reasons)
  ; coverage_reason = decision.coverage_reason
  ; coverage_stage = decision.coverage_stage
  ; is_error = decision.is_error
  ; streaming_ttfrc_ms = decision.streaming_ttfrc_ms
  ; streaming_inter_chunk_count = decision.streaming_inter_chunk_count
  ; streaming_inter_chunk_avg_ms = decision.streaming_inter_chunk_avg_ms
  }
;;

let add_identity_entry ~is_decision (buckets, unkeyed) entry =
  match entry.inference_identity with
  | None -> buckets, entry :: unkeyed
  | Some identity ->
    let bucket =
      match Inference_identity_map.find_opt identity buckets with
      | Some bucket -> bucket
      | None -> empty_identity_bucket
    in
    let bucket =
      if is_decision
      then { bucket with decisions = entry :: bucket.decisions }
      else { bucket with costs = entry :: bucket.costs }
    in
    Inference_identity_map.add identity bucket buckets, unkeyed
;;

let merge_decision_and_cost_entries decisions costs =
  let buckets, unkeyed =
    List.fold_left
      (add_identity_entry ~is_decision:true)
      (Inference_identity_map.empty, [])
      decisions
  in
  let buckets, unkeyed =
    List.fold_left
      (add_identity_entry ~is_decision:false)
      (buckets, unkeyed)
      costs
  in
  Inference_identity_map.fold
    (fun _identity bucket (entries, identity_conflict_rows) ->
       let decisions = List.rev bucket.decisions in
       let costs = List.rev bucket.costs in
       match decisions, costs with
       | [ decision ], [ cost ] ->
         merge_exact_inference decision cost :: entries, identity_conflict_rows
       | [ decision ], [] -> decision :: entries, identity_conflict_rows
       | [], [ cost ] -> cost :: entries, identity_conflict_rows
       | [], [] -> entries, identity_conflict_rows
       | _ ->
         ( entries
         , identity_conflict_rows + List.length decisions + List.length costs ))
    buckets
    (unkeyed, 0)
;;

let read_all_entries ~base_path ~since_unix =
  let decisions = read_all_decisions ~base_path ~since_unix in
  match read_cost_entries ~base_path ~since_unix with
  | Ok (costs, diagnostics) ->
    let entries, identity_conflict_rows =
      merge_decision_and_cost_entries decisions costs
    in
    if identity_conflict_rows > 0
    then
      Log.Model_inference_metrics.warn
        "cost ledger exact identity conflict: rows=%d action=excluded"
        identity_conflict_rows;
    entries, Ok { diagnostics with identity_conflict_rows }
  | Error error ->
    Log.Model_inference_metrics.error
      "costs/dated read failed: %s"
      (Dated_jsonl.read_error_to_string error);
    decisions, Error error
;;

(* ── Coverage helpers (used by aggregate stage) ───────────── *)

let usage_signal_present (entry : raw_entry) : bool =
  entry.input_tokens <> None
  || entry.output_tokens <> None
  || entry.cache_read_tokens <> None
  || entry.cache_creation_tokens <> None
  || entry.reasoning_tokens <> None
;;

let telemetry_signal_present (entry : raw_entry) : bool =
  entry.tok_per_sec <> None
  || entry.prompt_tok_per_sec <> None
  || entry.hw_decode_tok_per_sec <> None
  || entry.peak_memory_gb <> None
  || entry.latency_ms <> None
;;

let usage_reported_effective (entry : raw_entry) : bool =
  match entry.usage_reported with
  | Some reported -> reported
  | None -> usage_signal_present entry
;;

let telemetry_reported_effective (entry : raw_entry) : bool =
  match entry.telemetry_reported with
  | Some reported -> reported
  | None -> telemetry_signal_present entry
;;

let coverage_reason_of_entry (entry : raw_entry) : string option =
  if entry.is_error
  then Some "error_turn"
  else (
    match entry.coverage_reason with
    | Some _ as reason -> reason
    | None ->
      let usage_reported = usage_reported_effective entry in
      let telemetry_reported = telemetry_reported_effective entry in
      (match usage_reported, telemetry_reported with
       | true, true -> None
       | false, false -> Some "missing_usage_and_inference"
       | false, true -> Some "missing_usage"
       | true, false -> Some "missing_inference"))
;;

let coverage_stage_of_entry (entry : raw_entry) : string option =
  match entry.coverage_stage with
  | Some _ as stage -> stage
  | None ->
    if entry.is_error
    then Some "unknown"
    else (
      match entry.usage_reported, entry.telemetry_reported with
      | Some false, _ | _, Some false -> Some "agent_core"
      | _ ->
        (match coverage_reason_of_entry entry with
         | Some _ -> Some "unknown"
         | None -> None))
;;

let coverage_reason_counts_of_entries (entries : raw_entry list)
  : coverage_reason_count list
  =
  let counts =
    List.fold_left
      (fun acc entry ->
         match coverage_reason_of_entry entry with
         | Some reason when not entry.is_error ->
           let prev =
             match StringMap.find_opt reason acc with
             | Some count -> count
             | None -> 0
           in
           StringMap.add reason (prev + 1) acc
         | _ -> acc)
      StringMap.empty
      entries
  in
  StringMap.bindings counts
  |> List.map (fun (reason, count) -> { crc_reason = reason; crc_count = count })
  |> List.sort (fun a b ->
    let by_count = compare b.crc_count a.crc_count in
    if by_count <> 0 then by_count else compare a.crc_reason b.crc_reason)
;;

let most_common_stage_of_entries (entries : raw_entry list) : string option =
  let counts =
    List.fold_left
      (fun acc entry ->
         match coverage_stage_of_entry entry, coverage_reason_of_entry entry with
         | Some stage, Some _ when not entry.is_error ->
           let prev =
             match StringMap.find_opt stage acc with
             | Some count -> count
             | None -> 0
           in
           StringMap.add stage (prev + 1) acc
         | _ -> acc)
      StringMap.empty
      entries
  in
  match StringMap.bindings counts with
  | [] -> None
  | bindings ->
    (match
       List.sort
         (fun (stage_a, count_a) (stage_b, count_b) ->
            let by_count = compare count_b count_a in
            if by_count <> 0 then by_count else compare stage_a stage_b)
         bindings
     with
     | [] -> None
     | (stage, _) :: _ -> Some stage)
;;
