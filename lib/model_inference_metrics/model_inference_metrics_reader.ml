(** Model_inference_metrics_reader — JSONL file readers for
    {!Model_inference_metrics}.

    Reads keeper [decisions.jsonl] files plus inference-level
    [costs.jsonl] (legacy single-file + dated subtree), merges duplicate
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
         | _ -> [])
      files)
;;

let read_cost_entries_legacy ~base_path ~since_unix : raw_entry list =
  let path = Filename.concat (Common.masc_dir_from_base_path ~base_path) "costs.jsonl" in
  if not (Sys.file_exists path)
  then []
  else (
    try
      Fs_compat.fold_jsonl_lines
        ~init:[]
        ~f:(fun acc ~line_no json ->
          match parse_cost_entry json ~since_unix with
          | Ok e -> e :: acc
          | Error err ->
            if parse_error_is_schema_violation err
            then
              Log.Model_inference_metrics.warn "costs.jsonl parse drop: %s:%d reason=%s"
                path
                line_no
                (parse_error_label err);
            acc)
        path
    with
    | Eio.Cancel.Cancelled _ as exn ->
      let bt = Printexc.get_raw_backtrace () in
      Printexc.raise_with_backtrace exn bt
    | _ -> [])
;;

let read_cost_entries_dated ~base_path ~since_unix : raw_entry list =
  let dir = Filename.concat (Common.masc_dir_from_base_path ~base_path) "costs" in
  if not (Sys.file_exists dir)
  then []
  else (
    let store = Dated_jsonl.create ~base_dir:dir () in
    let now = Unix.gettimeofday () in
    let since = Log.format_utc_date_of since_unix in
    let until = Log.format_utc_date_of now in
    try
      Dated_jsonl.read_range store ~since ~until
      |> List.filter_map (fun json ->
        match
          try Ok (parse_cost_entry json ~since_unix) with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | _ -> Error ()
        with
        | Ok (Ok e) -> Some e
        | Ok (Error err) ->
          if parse_error_is_schema_violation err
          then
            Log.Model_inference_metrics.warn "costs/dated parse drop: reason=%s"
              (parse_error_label err);
          None
        | Error () -> None)
    with
    | Eio.Cancel.Cancelled _ as exn ->
      let bt = Printexc.get_raw_backtrace () in
      Printexc.raise_with_backtrace exn bt
    | _ -> [])
;;

(** Read cost ledger entries from both the legacy single-file
    [masc_root/costs.jsonl] and the date-split
    [masc_root/costs/YYYY-MM/DD.jsonl] tree, merging the two streams.

    The migration to [Dated_jsonl] (Tier A T4) keeps the legacy file
    readable so historic 14k+ entries are not dropped from
    cost-summary reports.  Operators may archive the legacy file at
    any time once they are satisfied that all queries that mattered to
    them only touch dates after the cut-over. *)
let read_cost_entries ~base_path ~since_unix : raw_entry list =
  let legacy = read_cost_entries_legacy ~base_path ~since_unix in
  let dated = read_cost_entries_dated ~base_path ~since_unix in
  legacy @ dated
;;

let same_int_opt a b =
  match a, b with
  | Some x, Some y -> x = y
  | _ -> false
;;

let same_inference_sample a b =
  String.equal a.model b.model
  && Float.abs (a.ts_unix -. b.ts_unix) <= 5.0
  && same_int_opt a.input_tokens b.input_tokens
  && same_int_opt a.output_tokens b.output_tokens
;;

let merge_decision_and_cost_entries decisions costs =
  let decision_shadowed_by_cost d =
    d.tok_per_sec = None
    && List.exists (fun c -> c.tok_per_sec <> None && same_inference_sample d c) costs
  in
  let decisions_kept =
    List.filter (fun d -> not (decision_shadowed_by_cost d)) decisions
  in
  let cost_duplicate_of_decision c =
    List.exists (fun d -> d.tok_per_sec <> None && same_inference_sample d c) decisions
  in
  decisions_kept @ List.filter (fun c -> not (cost_duplicate_of_decision c)) costs
;;

let read_all_entries ~base_path ~since_unix =
  let decisions = read_all_decisions ~base_path ~since_unix in
  let costs = read_cost_entries ~base_path ~since_unix in
  merge_decision_and_cost_entries decisions costs
;;

(* ── Coverage helpers (used by aggregate stage) ───────────── *)

let usage_signal_present (entry : raw_entry) : bool =
  entry.input_tokens <> None
  || entry.output_tokens <> None
  || entry.cache_read_tokens <> None
  || entry.reasoning_tokens <> None
  || entry.cost_usd <> None
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
      | Some false, _ | _, Some false -> Some "oas"
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
