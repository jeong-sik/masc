(** Runtime trace trajectory helpers for keeper dashboard API. *)

let line_ts = function
  | Trajectory.Tool_call entry -> entry.ts
  | Trajectory.Thinking entry -> entry.ts
;;

module Thinking_key = struct
  type t = float * bool * string

  let compare (ts1, r1, c1) (ts2, r2, c2) =
    let c_ts = Float.compare ts1 ts2 in
    if c_ts <> 0
    then c_ts
    else
      let c_r = Bool.compare r1 r2 in
      if c_r <> 0 then c_r else String.compare c1 c2
  ;;
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
           let key = entry.ts, entry.redacted, entry.content in
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
