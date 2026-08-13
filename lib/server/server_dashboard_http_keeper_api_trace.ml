(** Runtime trace trajectory helpers for keeper dashboard API. *)

let line_ts = function
  | Trajectory.Tool_call entry -> entry.ts
  | Trajectory.Thinking entry -> entry.ts
  | Trajectory.Withheld_thinking entry -> entry.ts
;;

module Thinking_key = struct
  type t =
    | Persisted_content of float * bool * string
    | Withheld_observation of int * int * Trajectory.withheld_reasoning_kind

  let compare = Stdlib.compare
end

module Thinking_set = Set.Make (Thinking_key)

let dedupe_thinking_lines (lines : Trajectory.trajectory_line list)
  : Trajectory.trajectory_line list
  =
  let _, rev_deduped =
    List.fold_left
      (fun (seen, acc) line ->
         match line with
         | Trajectory.Tool_call _ -> seen, line :: acc
         | Trajectory.Thinking entry ->
           let key = Thinking_key.Persisted_content (entry.ts, entry.redacted, entry.content) in
           if Thinking_set.mem key seen
           then seen, acc
           else Thinking_set.add key seen, line :: acc
         | Trajectory.Withheld_thinking entry ->
           let key =
             Thinking_key.Withheld_observation
               (entry.turn, entry.block_index, entry.reasoning_kind)
           in
           if Thinking_set.mem key seen
           then seen, acc
           else Thinking_set.add key seen, line :: acc)
      (Thinking_set.empty, [])
      lines
  in
  List.rev rev_deduped
;;

let log_internal_history_skips ~trace_id ~skipped ~total =
  if skipped > 0 then
    Log.Dashboard.warn
      "internal history trace %s: %d of %d rows did not decode to a thinking \
       line (older content-block format or non-assistant rows)"
      trace_id skipped total
;;

let internal_history_lines_of_jsons ~trace_id jsons =
  let lines_rev, skipped, total =
    List.fold_left
      (fun (acc, skipped, total) json ->
        match
          Server_dashboard_http_keeper_api_types
          .internal_history_json_to_trajectory_line
            json
        with
        | Some line -> line :: acc, skipped, total + 1
        | None -> acc, skipped + 1, total + 1)
      ([], 0, 0)
      jsons
  in
  log_internal_history_skips ~trace_id ~skipped ~total;
  List.rev lines_rev
;;

let read_internal_history_tail_lines ~max_lines ~(config : Workspace.config)
    ~(trace_id : string)
  : Trajectory.trajectory_line list
  =
  let path = Keeper_types_support.keeper_internal_history_path config trace_id in
  let jsons, _malformed =
    Dated_jsonl.load_tail_lines path ~max_lines
    |> Fs_compat.parse_jsonl_lines ~source:path
  in
  internal_history_lines_of_jsons ~trace_id jsons
;;

let read_internal_history_lines ~(config : Workspace.config) ~(trace_id : string)
  : Trajectory.trajectory_line list
  =
  let path = Keeper_types_support.keeper_internal_history_path config trace_id in
  (* Streaming filter: avoid materialising the full JSONL list when only a
     subset of lines decode to [trajectory_line].

     Rows that do not decode to a thinking line (older content-block format,
     non-assistant sources, or empty-text rows) are expected here. They are
     summarised once per read rather than warned per row: the dashboard re-reads
     each trace file on every poll, so a single undecodable file emitted one
     WARN per skipped row per read — a busy trace produced ~16k warnings/day,
     dominating the WARN log and drowning genuine warnings. The per-file summary
     keeps the signal (skipped/total counts) without the per-row volume. *)
  let lines_rev, skipped, total =
    Fs_compat.fold_jsonl_lines
      ~init:([], 0, 0)
      ~f:(fun (acc, skipped, total) ~line_no:_ json ->
         match
           Server_dashboard_http_keeper_api_types
           .internal_history_json_to_trajectory_line
             json
         with
       | Some line -> (line :: acc, skipped, total + 1)
       | None -> (acc, skipped + 1, total + 1))
      path
  in
  log_internal_history_skips ~trace_id ~skipped ~total;
  List.rev lines_rev
;;

let merge_lines ~internal_lines (trajectory_lines : Trajectory.trajectory_line list)
  : Trajectory.trajectory_line list
  =
  (* [stable_sort], not [sort]: the comparator returns 0 for two lines of the
     same kind at the same timestamp, and [List.sort] does not guarantee those
     keep their original order (only [stable_sort] does, per the OCaml 5.4
     manual). Stability preserves the deterministic merge order
     ([trajectory_lines] then [internal_lines]) so repeated same-timestamp
     thinking/tool lines render in a fixed sequence rather than an arbitrary
     one. *)
  dedupe_thinking_lines (trajectory_lines @ internal_lines)
  |> List.stable_sort (fun left right ->
    let cmp = Float.compare (line_ts left) (line_ts right) in
    if cmp <> 0
    then cmp
    else
      match left, right with
      | Trajectory.Thinking _, Trajectory.Tool_call _ -> -1
      | Trajectory.Tool_call _, Trajectory.Thinking _ -> 1
      | Trajectory.Withheld_thinking _, Trajectory.Tool_call _ -> -1
      | Trajectory.Tool_call _, Trajectory.Withheld_thinking _ -> 1
      | _ -> 0)
;;

let merge_keeper_trace_lines ~(config : Workspace.config) ~(trace_id : string)
      (trajectory_lines : Trajectory.trajectory_line list)
  : Trajectory.trajectory_line list
  =
  let internal_lines = read_internal_history_lines ~config ~trace_id in
  merge_lines ~internal_lines trajectory_lines
;;

let merge_keeper_trace_lines_bounded ~max_internal_lines
    ~(config : Workspace.config)
    ~(trace_id : string)
    (trajectory_lines : Trajectory.trajectory_line list)
  : Trajectory.trajectory_line list
  =
  let internal_lines =
    read_internal_history_tail_lines ~max_lines:max_internal_lines ~config
      ~trace_id
  in
  merge_lines ~internal_lines trajectory_lines
;;

let trajectory_line_to_chat_trace_step = function
  | Trajectory.Thinking entry ->
    Some
      (Keeper_chat_blocks.Trace_think
         { text = entry.content
         ; content_withheld = false
         ; ts = Some entry.ts_iso
         ; agent_core_block_index = None
         })
  | Trajectory.Withheld_thinking entry ->
    Some
      (Keeper_chat_blocks.Trace_think
         { text = ""
         ; content_withheld = true
         ; ts = Some entry.ts_iso
         ; agent_core_block_index = Some entry.block_index
         })
  | Trajectory.Tool_call entry ->
    let result =
      Option.map
        (fun text ->
          try Yojson.Safe.from_string text with
          | Yojson.Json_error _ -> `String text)
        entry.result
    in
    Some
      (Keeper_chat_blocks.Trace_tool
         { name = entry.tool_name
         ; tool_call_id = entry.execution_id
         ; status =
             (match entry.error with
              | Some _ -> Some Keeper_chat_blocks.Trace_tool_err
              | None -> Some Keeper_chat_blocks.Trace_tool_ok)
         ; dur = Some (Printf.sprintf "%dms" entry.duration_ms)
         ; args =
             Some
               (try Yojson.Safe.from_string entry.args_json with
                | Yojson.Json_error _ -> `String entry.args_json)
         ; result
         ; ts = Some entry.ts_iso
         ; agent_core_block_index = None
         })
;;

let allowed_trace_id_set trace_ids =
  List.fold_left
    (fun acc trace_id -> Set_util.StringSet.add trace_id acc)
    Set_util.StringSet.empty
    trace_ids
;;

(* How many of one turn's trace steps the chat transcript carries.

   A trace block is one turn's steps, and the transcript embeds every block.
   Measured on this host: one keeper's transcript held 22,296 steps across 162
   blocks, of which a single runaway turn held 16,882 — 1.65 MB of the 2.29 MB
   that trace blocks contributed to a 2.51 MB response, against 0.02 MB of
   actual conversation prose. The median block held 17 steps and the
   second-largest 175, so this cap leaves every ordinary turn whole and abridges
   only the pathological one.

   The block reports how many steps it dropped rather than just being shorter,
   and the turn's steps stay available in full from the raw-trace surface. *)
let chat_trace_steps_per_turn = 200

let chat_trace_block_by_turn_ref ~max_lines ~max_internal_lines
    ~(config : Workspace.config)
    ~(keeper_name : string)
    ~(allowed_trace_ids : string list)
  =
  let allowed_trace_ids = Json_util.dedupe_keep_order allowed_trace_ids in
  let allowed = allowed_trace_id_set allowed_trace_ids in
  let cache = Hashtbl.create (max 1 (List.length allowed_trace_ids)) in
  let masc_root = Workspace.masc_root_dir config in
  let lines_for_trace_id trace_id =
    if not (Set_util.StringSet.mem trace_id allowed)
    then None
    else (
      match Hashtbl.find_opt cache trace_id with
      | Some lines -> Some lines
      | None ->
        let trajectory_lines =
          Trajectory.read_recent_lines ~masc_root ~keeper_name ~trace_id
            ~max_lines
        in
        let all_lines =
          merge_keeper_trace_lines_bounded ~config ~trace_id ~max_internal_lines
            trajectory_lines
        in
        Hashtbl.replace cache trace_id all_lines;
        Some all_lines)
  in
  fun turn_ref ->
    let trace_id = Ids.Turn_ref.trace_id turn_ref in
    match lines_for_trace_id trace_id with
    | None -> None
    | Some all_lines ->
      let absolute_turn = Ids.Turn_ref.absolute_turn turn_ref in
      let trace =
        all_lines
        |> List.filter (function
             | Trajectory.Thinking entry -> entry.turn = absolute_turn
             | Trajectory.Withheld_thinking entry -> entry.turn = absolute_turn
             | Trajectory.Tool_call entry -> entry.turn = absolute_turn)
        |> List.filter_map trajectory_line_to_chat_trace_step
      in
      (match trace with
       | [] -> None
       | trace ->
         (* Newest steps are the ones an operator is reading toward, so the
            tail is what survives the cap. *)
         let total = List.length trace in
         let omitted = max 0 (total - chat_trace_steps_per_turn) in
         let trace =
           if omitted = 0
           then trace
           else List.filteri (fun index _ -> index >= omitted) trace
         in
         Some (Keeper_chat_blocks.Trace { trace; omitted }))
;;
