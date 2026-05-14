(** RFC-0034.v2: per-goal task creation cap.

    Moved verbatim from [lib/keeper/keeper_exec_task.ml] (introduced by
    #13981) so all 5 task creation entrypoints can wire the same guard
    via [Coord_task.add_task ~reject_if]. *)

type capacity_error = {
  goal_id : string;
  open_task_count : int;
  limit : int;
  message : string;
}

let default_goal_open_limit = 3

(* [task_matches_goal] is duplicated from [lib/goal/convergence.ml] because
   that module is part of the [masc_mcp] library, which depends on
   [masc_coord] — we cannot pull it in here without a dependency cycle.
   The logic is pure (no external state) and trivially mirrors the
   upstream definition: structured [goal_id] match, falling back to the
   legacy [[goal:<id>]] title marker. Keep both in sync. *)
let goal_title_marker goal_id = Printf.sprintf "[goal:%s]" goal_id

let title_has_goal_marker ~goal_id title =
  let tag = goal_title_marker goal_id in
  let title_lower = String.lowercase_ascii title in
  let tag_lower = String.lowercase_ascii tag in
  let tag_len = String.length tag_lower in
  let title_len = String.length title_lower in
  if tag_len > title_len then false
  else
    let found = ref false in
    for i = 0 to title_len - tag_len do
      if not !found && String.sub title_lower i tag_len = tag_lower
      then found := true
    done;
    !found
;;

let task_matches_goal ~goal_id (task : Masc_domain.task) =
  match task.goal_id with
  | Some linked_goal_id -> String.equal linked_goal_id goal_id
  | None -> title_has_goal_marker ~goal_id task.title
;;

let open_task_count_for_goal (backlog : Masc_domain.backlog) ~goal_id =
  List.fold_left
    (fun count (task : Masc_domain.task) ->
       if
         (not (Masc_domain.task_status_is_terminal task.task_status))
         && task_matches_goal ~goal_id task
       then count + 1
       else count)
    0
    backlog.tasks
;;

let check ?goal_id (backlog : Masc_domain.backlog) =
  match goal_id with
  | None -> None
  | Some goal_id ->
    let open_task_count = open_task_count_for_goal backlog ~goal_id in
    let limit = default_goal_open_limit in
    if open_task_count < limit
    then None
    else
      let message =
        Printf.sprintf
          "goal_task_limit_exceeded: goal_id=%s already has %d open linked tasks \
           (limit=%d). ACTION: claim or finish existing tasks for this goal before \
           creating more."
          goal_id
          open_task_count
          limit
      in
      Some { goal_id; open_task_count; limit; message }
;;

(* Field order matches the pre-RFC-0034.v2 shape produced by
   [Keeper_exec_shared.error_json ~fields message], which prepends
   ("error", message) before the supplied [fields]. Preserved verbatim
   so [keeper_task_create] / [masc_add_task] / etc. clients see the
   exact same JSON. *)
let error_to_json_string error =
  Yojson.Safe.to_string
    (`Assoc
        [
          "error", `String error.message;
          "ok", `Bool false;
          "error_kind", `String "goal_task_limit_exceeded";
          "goal_id", `String error.goal_id;
          "open_task_count", `Int error.open_task_count;
          "limit", `Int error.limit;
          ( "action",
            `String "claim_or_finish_existing_goal_tasks_before_creating_more" );
        ])
;;

let rejection_for_add_task ?goal_id backlog =
  check ?goal_id backlog |> Option.map (fun err -> err.message)
;;
