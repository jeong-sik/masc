(** Read-side operations for raw traces: list runs, read, summarize, validate.

    Extracted from raw_trace.ml to separate write-path (recording) from
    read-path (query/analysis).  All functions operate on JSONL files
    written by Raw_trace and return structured results. *)

open Result_syntax

(* ── Run discovery ──────────────────────────────────────────── *)

module String_map = Map.Make (String)

(* Extract [run_ref] values from a list of parsed records.
   Groups records by [worker_run_id] and computes [start_seq]/[end_seq]. *)
let run_refs_of_records ~path records : Raw_trace.run_ref list =
  let table =
    List.fold_left
      (fun acc (record : Raw_trace.record) ->
         match String_map.find_opt record.worker_run_id acc with
         | None ->
           String_map.add
             record.worker_run_id
             { Raw_trace.worker_run_id = record.worker_run_id
             ; path
             ; start_seq = record.seq
             ; end_seq = record.seq
             ; agent_name = record.agent_name
             ; session_id = record.session_id
             }
             acc
         | Some current ->
           String_map.add
             record.worker_run_id
             { current with
               start_seq = min current.start_seq record.seq
             ; end_seq = max current.end_seq record.seq
             }
             acc)
      String_map.empty
      records
  in
  String_map.bindings table
  |> List.map snd
  |> List.sort (fun (a : Raw_trace.run_ref) (b : Raw_trace.run_ref) ->
    Int.compare a.start_seq b.start_seq)
;;

let read_runs ~path () =
  let* records = Raw_trace.read_all ~path () in
  Ok (run_refs_of_records ~path records)
;;

let read_run (run_ref : Raw_trace.run_ref) =
  let* records = Raw_trace.read_all ~path:run_ref.path () in
  Ok
    (List.filter
       (fun (record : Raw_trace.record) ->
          String.equal record.worker_run_id run_ref.worker_run_id
          && record.seq >= run_ref.start_seq
          && record.seq <= run_ref.end_seq)
       records)
;;

(* ── Summarize ──────────────────────────────────────────────── *)

let summarize_run run_ref =
  let* records = read_run run_ref in
  let count_block_kind kind =
    records
    |> List.filter (fun (record : Raw_trace.record) ->
      record.record_type = Assistant_block && record.block_kind = Some kind)
    |> List.length
  in
  let assistant_block_count =
    List.filter
      (fun (record : Raw_trace.record) -> record.record_type = Assistant_block)
      records
    |> List.length
  in
  let tool_execution_started_count =
    List.filter
      (fun (record : Raw_trace.record) -> record.record_type = Tool_execution_started)
      records
    |> List.length
  in
  let tool_execution_finished_count =
    List.filter
      (fun (record : Raw_trace.record) -> record.record_type = Tool_execution_finished)
      records
    |> List.length
  in
  let hook_invoked_count =
    List.filter
      (fun (record : Raw_trace.record) -> record.record_type = Hook_invoked)
      records
    |> List.length
  in
  let hook_names =
    records
    |> List.filter_map (fun (record : Raw_trace.record) -> record.hook_name)
    |> List.sort_uniq String.compare
  in
  let tool_names =
    records
    |> List.filter (fun (record : Raw_trace.record) ->
      match record.record_type with
      | Tool_execution_started | Tool_execution_finished -> true
      | Run_started | Assistant_block | Native_tool_started | Native_tool_finished
      | Hook_invoked | Run_finished -> false)
    |> List.filter_map (fun (record : Raw_trace.record) -> record.tool_name)
    |> List.sort_uniq String.compare
  in
  let start_record =
    records
    |> List.find_opt (fun (record : Raw_trace.record) -> record.record_type = Run_started)
  in
  let final_record =
    records
    |> List.rev
    |> List.find_opt (fun (record : Raw_trace.record) ->
      record.record_type = Run_finished)
  in
  let thinking_block_count =
    count_block_kind "thinking"
    + count_block_kind "reasoning_details"
    + count_block_kind "redacted_thinking"
  in
  let text_block_count = count_block_kind "text" in
  let tool_use_block_count = count_block_kind "tool_use" in
  let tool_result_block_count = count_block_kind "tool_result" in
  let first_assistant_block_kind =
    match
      List.find_opt
        (fun (record : Raw_trace.record) -> record.record_type = Assistant_block)
        records
    with
    | Some record -> record.block_kind
    | None -> None
  in
  let saw_tool_use = tool_use_block_count > 0 || tool_execution_started_count > 0 in
  let saw_thinking = thinking_block_count > 0 in
  let selection_outcome =
    match saw_tool_use, text_block_count > 0 with
    | true, true -> "mixed"
    | true, false -> "tool_only"
    | false, true -> "text_only"
    | false, false -> "empty"
  in
  let started_at =
    match records with
    | first :: _ -> Some first.ts
    | [] -> None
  in
  let finished_at =
    match List.rev records with
    | last :: _ -> Some last.ts
    | [] -> None
  in
  Ok
    { Raw_trace.run_ref
    ; record_count = List.length records
    ; assistant_block_count
    ; tool_execution_started_count
    ; tool_execution_finished_count
    ; hook_invoked_count
    ; hook_names
    ; tool_names
    ; model = Option.bind start_record (fun record -> record.model)
    ; tool_choice = Option.bind start_record (fun record -> record.tool_choice)
    ; enable_thinking = Option.bind start_record (fun record -> record.enable_thinking)
    ; preserve_thinking =
        Option.bind start_record (fun record -> record.preserve_thinking)
    ; reasoning_effort = Option.bind start_record (fun record -> record.reasoning_effort)
    ; thinking_block_count
    ; text_block_count
    ; tool_use_block_count
    ; tool_result_block_count
    ; first_assistant_block_kind
    ; selection_outcome
    ; saw_tool_use
    ; saw_thinking
    ; final_text = Option.bind final_record (fun record -> record.final_text)
    ; stop_reason = Option.bind final_record (fun record -> record.stop_reason)
    ; error = Option.bind final_record (fun record -> record.error)
    ; started_at
    ; finished_at
    }
;;

(* ── Validate ───────────────────────────────────────────────── *)

let validate_run run_ref =
  let* records = read_run run_ref in
  let seq_monotonic =
    let rec loop last = function
      | [] -> true
      | (record : Raw_trace.record) :: rest -> record.seq > last && loop record.seq rest
    in
    match records with
    | [] -> false
    | first :: rest -> loop first.seq rest
  in
  let has_run_started =
    List.exists
      (fun (record : Raw_trace.record) -> record.record_type = Run_started)
      records
  in
  let has_run_finished =
    List.exists
      (fun (record : Raw_trace.record) -> record.record_type = Run_finished)
      records
  in
  let exact_key (record : Raw_trace.record) tool_use_id =
    match record.tool_turn, record.tool_planned_index with
    | Some turn, Some planned_index -> Some (tool_use_id, turn, planned_index)
    | _ -> None
  in
  let pair_key record tool_use_id =
    match exact_key record tool_use_id with
    | Some (id, turn, planned_index) -> id, Some turn, Some planned_index
    | None -> tool_use_id, None, None
  in
  let module Pair_key_map =
    Map.Make (struct
      type t = string * int option * int option

      let compare (id1, t1, p1) (id2, t2, p2) =
        let c = String.compare id1 id2 in
        if c <> 0
        then c
        else (
          let c = Option.compare Int.compare t1 t2 in
          if c <> 0 then c else Option.compare Int.compare p1 p2)
    end)
  in
  let module Exact_key_set =
    Set.Make (struct
      type t = string * int * int

      let compare (id1, t1, p1) (id2, t2, p2) =
        let c = String.compare id1 id2 in
        if c <> 0
        then c
        else (
          let c = Int.compare t1 t2 in
          if c <> 0 then c else Int.compare p1 p2)
    end)
  in
  let outstanding, _seen_exact_starts, ordering_ok, paired_tool_result_count =
    List.fold_left
      (fun (outstanding, seen_exact_starts, ordering_ok, paired_count)
           (record : Raw_trace.record) ->
         match record.record_type, record.tool_use_id with
         | Tool_execution_started, Some tool_use_id ->
           let key = pair_key record tool_use_id in
           let count = Option.value ~default:0 (Pair_key_map.find_opt key outstanding) in
           (match exact_key record tool_use_id with
            | Some exact when Exact_key_set.mem exact seen_exact_starts ->
              outstanding, seen_exact_starts, false, paired_count
            | Some exact ->
              ( Pair_key_map.add key 1 outstanding
              , Exact_key_set.add exact seen_exact_starts
              , ordering_ok
              , paired_count )
            | None ->
              Pair_key_map.add key (count + 1) outstanding, seen_exact_starts, ordering_ok, paired_count)
         | Tool_execution_finished, Some tool_use_id ->
           let key = pair_key record tool_use_id in
           let count = Option.value ~default:0 (Pair_key_map.find_opt key outstanding) in
           if count = 0
           then outstanding, seen_exact_starts, false, paired_count
           else
             ( Pair_key_map.add key (count - 1) outstanding
             , seen_exact_starts
             , ordering_ok
             , paired_count + 1 )
         | (Tool_execution_started | Tool_execution_finished), None ->
           outstanding, seen_exact_starts, false, paired_count
         | ( ( Run_started
             | Assistant_block
             | Native_tool_started
             | Native_tool_finished
             | Hook_invoked
             | Run_finished )
           , _ ) -> outstanding, seen_exact_starts, ordering_ok, paired_count)
      (Pair_key_map.empty, Exact_key_set.empty, true, 0)
      records
  in
  let tool_pairs_ok =
    ordering_ok && Pair_key_map.for_all (fun _ count -> Int.equal count 0) outstanding
  in
  let checks =
    [ { Raw_trace.name = "seq_monotonic"; passed = seq_monotonic }
    ; { name = "run_started"; passed = has_run_started }
    ; { name = "run_finished"; passed = has_run_finished }
    ; { name = "tool_pairs"; passed = tool_pairs_ok }
    ]
  in
  let ok =
    List.for_all (fun (check : Raw_trace.validation_check) -> check.passed) checks
  in
  let* summary = summarize_run run_ref in
  let failure_reason =
    match summary.error with
    | Some _ as err -> err
    | None ->
      checks
      |> List.find_opt (fun (check : Raw_trace.validation_check) -> not check.passed)
      |> Option.map (fun (check : Raw_trace.validation_check) -> check.name)
  in
  let evidence =
    [ Printf.sprintf "record_count=%d" summary.record_count
    ; Printf.sprintf "assistant_blocks=%d" summary.assistant_block_count
    ; Printf.sprintf "tool_exec_started=%d" summary.tool_execution_started_count
    ; Printf.sprintf "tool_exec_finished=%d" summary.tool_execution_finished_count
    ; Printf.sprintf "hooks=%d" summary.hook_invoked_count
    ; Printf.sprintf "hook_names=%s" (String.concat "," summary.hook_names)
    ; Printf.sprintf "tool_names=%s" (String.concat "," summary.tool_names)
    ; Printf.sprintf "model=%s" (Option.value summary.model ~default:"")
    ; Printf.sprintf
        "tool_choice=%s"
        (match summary.tool_choice with
         | Some json -> Yojson.Safe.to_string json
         | None -> "")
    ; Printf.sprintf
        "enable_thinking=%s"
        (match summary.enable_thinking with
         | Some true -> "true"
         | Some false -> "false"
         | None -> "")
    ; Printf.sprintf
        "preserve_thinking=%s"
        (match summary.preserve_thinking with
         | Some true -> "true"
         | Some false -> "false"
         | None -> "")
    ; Printf.sprintf
        "reasoning_effort=%s"
        (Option.value summary.reasoning_effort ~default:"")
    ; Printf.sprintf "thinking_blocks=%d" summary.thinking_block_count
    ; Printf.sprintf "text_blocks=%d" summary.text_block_count
    ; Printf.sprintf "tool_use_blocks=%d" summary.tool_use_block_count
    ; Printf.sprintf "tool_result_blocks=%d" summary.tool_result_block_count
    ; Printf.sprintf
        "first_assistant_block_kind=%s"
        (Option.value summary.first_assistant_block_kind ~default:"")
    ; Printf.sprintf "selection_outcome=%s" summary.selection_outcome
    ; Printf.sprintf "saw_tool_use=%b" summary.saw_tool_use
    ; Printf.sprintf "saw_thinking=%b" summary.saw_thinking
    ; Printf.sprintf "final_text=%s" (Option.value summary.final_text ~default:"")
    ; Printf.sprintf "stop_reason=%s" (Option.value summary.stop_reason ~default:"")
    ; Printf.sprintf "error=%s" (Option.value summary.error ~default:"")
    ; Printf.sprintf "paired_tool_result_count=%d" !paired_tool_result_count
    ]
  in
  Ok
    { Raw_trace.run_ref
    ; ok
    ; checks
    ; evidence
    ; paired_tool_result_count = !paired_tool_result_count
    ; final_text = summary.final_text
    ; tool_names = summary.tool_names
    ; stop_reason = summary.stop_reason
    ; failure_reason
    }
;;
