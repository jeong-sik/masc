module Q = Keeper_tasks_list_query
module C = Keeper_tasks_list_cursor
module U = Yojson.Safe.Util
let decode json = match Masc_domain.task_of_yojson json with
  | Ok task -> task | Error err -> failwith err
let select fields = match Q.of_args (`Assoc fields) with
  | Ok query -> query | Error err -> failwith err
let () =
  if Array.length Sys.argv <> 2 then failwith "usage: probe RAW_TRACE.jsonl";
  let rows = In_channel.with_open_text Sys.argv.(1) (fun input ->
    let rec loop acc = match In_channel.input_line input with
      | None -> List.rev acc
      | Some line -> loop (Yojson.Safe.from_string line :: acc)
    in loop []) in
  let pages = List.filter_map (fun row ->
    if U.member "record_type" row = `String "tool_execution_finished"
       && U.member "tool_name" row = `String "keeper_tasks_list"
    then Some (Yojson.Safe.from_string (U.member "tool_result" row |> U.to_string))
    else None) rows in
  let tasks = List.concat_map (fun page -> U.member "snapshot" page |> U.to_list |> List.map decode) pages in
  let ids = List.map (fun (task : Masc_domain.task) -> task.id) tasks in
  assert (List.length ids = List.length (List.sort_uniq String.compare ids));
  let wanted = List.filteri (fun index _ -> index < 2) tasks in
  let query = select ["task_ids", `List (List.map (fun (t : Masc_domain.task) -> `String t.id) wanted)] in
  let picked = List.filter (Q.matches query ~goal_task_ids:None) tasks in
  assert (List.map (fun (t : Masc_domain.task) -> t.id) wanted = List.map (fun (t : Masc_domain.task) -> t.id) picked);
  let seed = List.hd tasks in
  let fixture = {seed with title = "Other"; description = "Release contract";
    task_status = Masc_domain.InProgress {assignee="alice"; started_at="2026-10-01T18:00:00Z"}} in
  let combined = select ["assignee", `String "alice"; "goal_id", `String "g"; "query", `String "RELEASE"] in
  assert (Q.matches combined ~goal_task_ids:(Some [fixture.id]) fixture);
  assert (not (Q.matches combined ~goal_task_ids:(Some []) fixture));
  assert (not (Q.matches combined ~goal_task_ids:(Some [fixture.id]) {fixture with task_status=Masc_domain.Todo}));
  List.iter (fun field -> assert (Result.is_error (Q.of_args (`Assoc [field]))))
    ["task_ids", `List []; "task_ids", `List [`Int 1]; "query", `String " "; "assignee", `Int 1];
  let filter : C.filter = {status=None; include_done=false; projection="compact"; selection=query} in
  let cursor : C.t = {after={priority=seed.priority;created_at=seed.created_at;id=seed.id};filter} in
  let wire = C.to_string cursor in
  assert (Result.is_ok (C.of_string ~call:filter wire));
  assert (Result.is_error (C.of_string ~call:{filter with selection=combined} wire));
  let notes = String.make 4096 'x' in
  let done_task = {seed with task_status=Masc_domain.Done
    {assignee="alice";completed_at="2026-10-01T19:00:00Z";notes=Some notes}} in
  let compact = Masc_domain.task_compact_to_yojson done_task in
  let full = Masc_domain.task_to_yojson done_task in
  assert (not (List.mem "notes" (U.keys compact)));
  assert (U.member "notes" full = `String notes);
  assert (U.member "completed_at" compact = U.member "completed_at" full);
  let old_compact = match compact with `Assoc fields -> `Assoc (fields @ ["notes", `String notes]) | _ -> assert false in
  let bytes json = String.length (Yojson.Safe.to_string json) in
  Printf.printf "PASS actual query/cursor/compact production modules\nrecorded_tasks=%d selected_exact_ids=%d\ncompleted_row_old_compact_bytes=%d compact_bytes=%d full_bytes=%d\n"
    (List.length tasks) (List.length picked) (bytes old_compact) (bytes compact) (bytes full)
