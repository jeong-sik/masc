(** RFC-0034.v2: per-goal task creation cap.

    Moved verbatim from the keeper task tool runtime helper introduced by
    #13981 so all 5 task creation entrypoints can wire the same guard
    via [Coord_task.add_task ~reject_if]. *)

type capacity_error = {
  goal_id : string;
  open_task_count : int;
  limit : int;
  message : string;
}

let default_goal_open_limit = 3

let task_matches_goal ~goal_id (task : Masc_domain.task) =
  match task.goal_id with
  | Some linked_goal_id -> String.equal linked_goal_id goal_id
  | None -> false
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
