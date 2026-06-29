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

let read_internal_history_lines ~(config : Workspace.config) ~(trace_id : string)
  : Trajectory.trajectory_line list
  =
  let path = Keeper_types_support.keeper_internal_history_path config trace_id in
  (* Streaming filter: avoid materialising the full JSONL list when only a
     subset of lines decode to [trajectory_line]. *)
  Fs_compat.fold_jsonl_lines
    ~init:[]
    ~f:(fun acc ~line_no json ->
       match
         Server_dashboard_http_keeper_api_types
         .internal_history_json_to_trajectory_line
           json
       with
       | Some line -> line :: acc
       | None ->
         Log.Dashboard.warn "Skipped invalid internal history trace row (trace=%s, line=%d)" trace_id line_no;
         acc)
    path
  |> List.rev
;;

let merge_keeper_trace_lines ~(config : Workspace.config) ~(trace_id : string)
      (trajectory_lines : Trajectory.trajectory_line list)
  : Trajectory.trajectory_line list
  =
  let internal_lines = read_internal_history_lines ~config ~trace_id in
  dedupe_thinking_lines (trajectory_lines @ internal_lines)
  |> List.sort (fun left right ->
    let cmp = Float.compare (line_ts left) (line_ts right) in
    if cmp <> 0
    then cmp
    else
      match left, right with
      | Trajectory.Thinking _, Trajectory.Tool_call _ -> -1
      | Trajectory.Tool_call _, Trajectory.Thinking _ -> 1
      | _ -> 0)
;;
