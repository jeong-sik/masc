(** Runtime trace trajectory helpers for keeper dashboard API. *)

let line_ts = function
  | Trajectory.Tool_call entry -> entry.ts
  | Trajectory.Thinking entry -> entry.ts
;;

let dedupe_thinking_lines (lines : Trajectory.trajectory_line list)
  : Trajectory.trajectory_line list
  =
  let seen = Hashtbl.create 32 in
  List.filter
    (function
      | Trajectory.Tool_call _ -> true
      | Trajectory.Thinking entry ->
        let key =
          Printf.sprintf
            "%.6f\x1f%b\x1f%s"
            entry.ts
            entry.redacted
            entry.content
        in
        if Hashtbl.mem seen key
        then false
        else (
          Hashtbl.add seen key ();
          true))
    lines
;;

let read_internal_history_lines ~(config : Coord.config) ~(trace_id : string)
  : Trajectory.trajectory_line list
  =
  let path = Keeper_types.keeper_internal_history_path config trace_id in
  (* Streaming filter: avoid materialising the full JSONL list when only a
     subset of lines decode to [trajectory_line]. *)
  Fs_compat.fold_jsonl_lines
    ~init:[]
    ~f:(fun acc ~line_no:_ json ->
       match
         Server_dashboard_http_keeper_api_types
         .internal_history_json_to_trajectory_line
           json
       with
       | Some line -> line :: acc
       | None -> acc)
    path
  |> List.rev
;;

let merge_keeper_trace_lines ~(config : Coord.config) ~(trace_id : string)
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
