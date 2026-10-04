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

type decision_read =
  | Decisions_read
  | Decision_directory_unavailable
  | Decision_files_unreadable of int
  | Decision_rows_invalid of { malformed_rows : int; schema_violation_rows : int }

let decision_files directory =
  let log exn = Log.Model_inference_metrics.error
      "decisions.jsonl directory read failed: path=%s detail=%s"
      directory (Printexc.to_string exn) in
  let opened =
    try Ok (Some (Unix.opendir directory)) with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
    | Unix.Unix_error _ as exn -> log exn; Error () in
  match opened with
  | Error () -> Error ()
  | Ok None -> Ok []
  | Ok (Some handle) ->
      Fun.protect ~finally:(fun () -> Unix.closedir handle) (fun () ->
        let rec read files = match Unix.readdir handle with
          | name -> read (name :: files)
          | exception End_of_file -> Ok files
          | exception (Unix.Unix_error _ as exn) -> log exn; Error () in
        read [])

(* Inventory already observed each path. Open it directly: the permissive
   JSONL helper's existence check can hide denied stat calls and dangling
   symlinks as an empty file. Keep streaming and propagate every open/read
   failure to the typed decision diagnostics below. *)
let fold_decision_file ~init ~on_malformed ~f path =
  let line_no = ref 0 in
  let consume acc raw =
    let line = String.trim raw in
    if line = "" then acc
    else begin
      incr line_no;
      match Fs_compat.parse_jsonl_line ~source:path ~line_no:!line_no line with
      | None -> on_malformed (); acc
      | Some json -> f acc ~line_no:!line_no json
    end in
  match Fs_compat.get_fs_opt (), Fs_compat.execution_context () with
  | Some fs, Fs_compat.Eio_fiber ->
      Eio.Path.with_open_in Eio.Path.(fs / path) (fun flow ->
        Eio.Buf_read.of_flow ~max_size:(16 * 1024 * 1024) flow
        |> Eio.Buf_read.lines |> Seq.fold_left consume init)
  | None, _ | Some _, Fs_compat.Non_eio ->
      let channel = open_in path in
      Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
        let rec read acc = match input_line channel with
          | line -> read (consume acc line)
          | exception End_of_file -> acc in
        read init)

let read_all_decisions ~base_path ~since_unix =
  let keeper_dir =
    Common.keepers_runtime_dir_of_base ~base_path
  in
  match decision_files keeper_dir with
  | Error () -> [], Decision_directory_unavailable
  | Ok files ->
    let unreadable = ref 0 in
    let malformed_rows = ref 0 in
    let schema_violation_rows = ref 0 in
    let files =
      files
      |> List.filter (fun f ->
        String.length f > 16 && Filename.check_suffix f ".decisions.jsonl")
      |> List.sort String.compare
    in
    let entries = List.concat_map
      (fun fname ->
         let path = Filename.concat keeper_dir fname in
         try
           fold_decision_file
             ~init:[]
             ~on_malformed:(fun () -> incr malformed_rows)
             ~f:(fun acc ~line_no json ->
               match parse_telemetry_entry json ~since_unix with
               | Ok e -> e :: acc
               | Error err ->
                 if parse_error_is_schema_violation err
                 then begin
                   incr schema_violation_rows;
                   Log.Model_inference_metrics.warn "decisions.jsonl parse drop: %s:%d reason=%s"
                     path
                     line_no
                     (parse_error_label err)
                 end;
                 acc)
             path
         with
         | Eio.Cancel.Cancelled _ as exn ->
           let bt = Printexc.get_raw_backtrace () in
           Printexc.raise_with_backtrace exn bt
         | exn ->
           incr unreadable;
           Log.Model_inference_metrics.error
             "decisions.jsonl read failed: path=%s detail=%s"
             path
             (Printexc.to_string exn);
           [])
      files in
    let reading =
      if !unreadable > 0 then Decision_files_unreadable !unreadable
      else if !malformed_rows > 0 || !schema_violation_rows > 0 then
        Decision_rows_invalid { malformed_rows = !malformed_rows;
          schema_violation_rows = !schema_violation_rows }
      else Decisions_read in
    entries, reading
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
           | Ok { usage_projection = Cost_ledger.Raw_observation _; _ } -> ()
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

module Inference_key_map = Map.Make (struct
    type t = Cost_ledger.inference_key

    let compare = Cost_ledger.compare_inference_key
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
  ; executed_runtime_id = decision.executed_runtime_id
  ; inference_key = cost.inference_key
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
  match entry.inference_key with
  | None -> buckets, entry :: unkeyed
  | Some identity ->
    let bucket =
      match Inference_key_map.find_opt identity buckets with
      | Some bucket -> bucket
      | None -> empty_identity_bucket
    in
    let bucket =
      if is_decision
      then { bucket with decisions = entry :: bucket.decisions }
      else { bucket with costs = entry :: bucket.costs }
    in
    Inference_key_map.add identity bucket buckets, unkeyed
;;

let merge_decision_and_cost_entries decisions costs =
  let buckets, unkeyed =
    List.fold_left
      (add_identity_entry ~is_decision:true)
      (Inference_key_map.empty, [])
      decisions
  in
  let buckets, unkeyed =
    List.fold_left
      (add_identity_entry ~is_decision:false)
      (buckets, unkeyed)
      costs
  in
  Inference_key_map.fold
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
  let decisions, decision_read = read_all_decisions ~base_path ~since_unix in
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
    entries, Ok { diagnostics with identity_conflict_rows }, decision_read
  | Error error ->
    Log.Model_inference_metrics.error
      "costs/dated read failed: %s"
      (Dated_jsonl.read_error_to_string error);
    decisions, Error error, decision_read
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
