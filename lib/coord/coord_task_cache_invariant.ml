(** Guard task-state cache emissions against terminal backlog truth. *)

open Masc_domain

type stale_terminal_task = {
  task_id : string;
  status : string;
  actor : string;
}

let task_ref_re = lazy (Re.Pcre.re "\\btask-[0-9]+\\b" |> Re.compile)

let string_contains s needle =
  let len_s = String.length s in
  let len_needle = String.length needle in
  if len_needle = 0 then true
  else if len_needle > len_s then false
  else
    let rec loop i =
      if i > len_s - len_needle then false
      else if String.sub s i len_needle = needle then true
      else loop (i + 1)
    in
    loop 0
;;

let string_starts_with ~prefix s =
  let len_s = String.length s in
  let len_prefix = String.length prefix in
  len_s >= len_prefix && String.sub s 0 len_prefix = prefix
;;

let extract_task_ids content =
  Re.all (Lazy.force task_ref_re) content
  |> List.map (fun group -> Re.Group.get group 0)
  |> List.sort_uniq String.compare
;;

let active_cache_language_present content =
  let lower = String.lowercase_ascii content in
  List.exists
    (string_contains lower)
    [
      "stale claim";
      "current_task_id";
      "still claimed";
      "still lists";
      "claimed by";
      "please release";
      "mark done";
      "blocking";
      "blocked by";
    ]
;;

let terminal_task_mentions ~config ~content =
  let task_ids = extract_task_ids content in
  if task_ids = [] || not (active_cache_language_present content) then []
  else
    match Coord_state.read_backlog_r config with
    | Error msg ->
      Log.Misc.warn "task cache invariant: backlog read failed before broadcast: %s" msg;
      []
    | Ok backlog ->
      let task_by_id =
        List.filter_map
          (fun (task : task) ->
             if List.mem task.id task_ids && task_status_is_terminal task.task_status
             then
               Some
                 {
                   task_id = task.id;
                   status = task_status_to_string task.task_status;
                   actor = task_display_assignee task.task_status;
                 }
             else None)
          backlog.tasks
      in
      List.sort
        (fun left right -> String.compare left.task_id right.task_id)
        task_by_id
;;

let invalidation_message ~from_agent stale_tasks =
  let task_summary =
    stale_tasks
    |> List.map (fun task ->
      Printf.sprintf "%s=%s by %s" task.task_id task.status task.actor)
    |> String.concat ", "
  in
  Printf.sprintf
    "[cache_invalidated] skipped stale task-state broadcast from %s: %s is \
     terminal in backlog; original active-claim message was not emitted."
    from_agent
    task_summary
;;

let record_cache_desync_cleared ~module_name stale_tasks =
  List.iter
    (fun task ->
       (Atomic.get Coord_hooks.cache_desync_cleared_fn)
         ~module_name
         ~task_id:task.task_id
         ~status:task.status)
    stale_tasks
;;

let stale_active_task_signal_present ~config ~module_name ~content =
  match terminal_task_mentions ~config ~content with
  | [] -> false
  | stale_tasks ->
    record_cache_desync_cleared ~module_name stale_tasks;
    true
;;

let rewrite_broadcast_content ~config ~from_agent ~module_name ~content =
  if string_starts_with ~prefix:"[cache_invalidated]" (String.trim content)
  then content
  else
    match terminal_task_mentions ~config ~content with
    | [] -> content
    | stale_tasks ->
      record_cache_desync_cleared ~module_name stale_tasks;
      invalidation_message ~from_agent stale_tasks
;;
