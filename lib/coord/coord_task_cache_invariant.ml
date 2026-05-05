(** Guard task-state cache emissions against terminal backlog truth. *)

open Masc_domain

type stale_terminal_task = {
  task_id : string;
  status : string;
  actor : string;
}

type cache_signal_check =
  | No_cache_signal
  | No_terminal_task
  | Backlog_unavailable of {
      task_ids : string list;
      error : string;
    }
  | Terminal_tasks of stale_terminal_task list

let task_ref_re = lazy (Re.Pcre.re "\\btask-[0-9]+\\b" |> Re.compile)
let invalidation_memory_ttl_s = 3600.0
let invalidation_memory : (string, float) Hashtbl.t = Hashtbl.create 64
let invalidation_memory_lock = Mutex.create ()

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

let trusted_cache_signal_sender from_agent =
  String.lowercase_ascii from_agent |> fun value ->
  string_contains value "taskmaster"
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
      "active-claim";
      "cache desync";
      "stale claim";
      "current_task_id";
      "still claimed";
      "still lists";
      "please release";
      "task-state cache";
    ]
;;

let check_cache_signal ~config ~content =
  let task_ids = extract_task_ids content in
  if task_ids = [] || not (active_cache_language_present content)
  then No_cache_signal
  else
    match Coord_state.read_backlog_r config with
    | Error msg ->
      Log.Misc.warn "task cache invariant: backlog read failed before broadcast: %s" msg;
      Backlog_unavailable { task_ids; error = msg }
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
      let stale_tasks =
        List.sort
          (fun left right -> String.compare left.task_id right.task_id)
          task_by_id
      in
      if stale_tasks = [] then No_terminal_task else Terminal_tasks stale_tasks
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
     terminal in backlog; original cached-claim message was not emitted."
    from_agent
    task_summary
;;

let backlog_unavailable_message ~from_agent task_ids =
  Printf.sprintf
    "[cache_invalidated] skipped unverifiable task-state broadcast from %s: \
     backlog read failed while checking %s; original active-claim message was \
     not emitted."
    from_agent
    (String.concat ", " task_ids)
;;

let remember_invalidation ~module_name ~task_id ~status =
  let key = String.concat "\x00" [ module_name; task_id; status ] in
  let now = Time_compat.now () in
  Mutex.lock invalidation_memory_lock;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock invalidation_memory_lock)
    (fun () ->
       Hashtbl.filter_map_inplace
         (fun _ ts ->
            if now -. ts > invalidation_memory_ttl_s then None else Some ts)
         invalidation_memory;
       let first_seen = not (Hashtbl.mem invalidation_memory key) in
       Hashtbl.replace invalidation_memory key now;
       first_seen)
;;

let record_cache_desync_cleared ~module_name stale_tasks =
  List.iter
    (fun task ->
       if remember_invalidation ~module_name ~task_id:task.task_id ~status:task.status
       then
         (Atomic.get Coord_hooks.cache_desync_cleared_fn)
           ~module_name
           ~task_id:task.task_id
           ~status:task.status)
    stale_tasks
;;

let record_backlog_unavailable ~module_name task_ids =
  List.iter
    (fun task_id ->
       if
         remember_invalidation
           ~module_name
           ~task_id
           ~status:"backlog_unavailable"
       then
         (Atomic.get Coord_hooks.cache_desync_cleared_fn)
           ~module_name
           ~task_id
           ~status:"backlog_unavailable")
    task_ids
;;

let stale_active_task_signal_present ~config ~from_agent ~module_name ~content =
  if string_starts_with ~prefix:"[cache_invalidated]" (String.trim content)
     || not (trusted_cache_signal_sender from_agent)
  then false
  else match check_cache_signal ~config ~content with
  | No_cache_signal | No_terminal_task -> false
  | stale_tasks ->
    (match stale_tasks with
     | Terminal_tasks stale_tasks ->
       record_cache_desync_cleared ~module_name stale_tasks
     | Backlog_unavailable { task_ids; _ } ->
       record_backlog_unavailable ~module_name task_ids
     | No_cache_signal | No_terminal_task -> ());
    true
;;

let rewrite_broadcast_content ~config ~from_agent ~module_name ~content =
  if string_starts_with ~prefix:"[cache_invalidated]" (String.trim content)
     || not (trusted_cache_signal_sender from_agent)
  then content
  else
    match check_cache_signal ~config ~content with
    | No_cache_signal | No_terminal_task -> content
    | Backlog_unavailable { task_ids; error = _ } ->
      record_backlog_unavailable ~module_name task_ids;
      backlog_unavailable_message ~from_agent task_ids
    | Terminal_tasks stale_tasks ->
      record_cache_desync_cleared ~module_name stale_tasks;
      invalidation_message ~from_agent stale_tasks
;;
