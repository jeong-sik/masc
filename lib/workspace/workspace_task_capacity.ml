(** RFC-0034.v2: per-goal task creation cap.

    Moved verbatim from the keeper task tool runtime helper introduced by
    #13981 so all 5 task creation entrypoints can wire the same guard
    via [Workspace_task.add_task ~reject_if].

    The [check] function now uses a pre-built reverse index from
    [Workspace_goal_index] to avoid O(n) linear scans. The legacy
    [open_task_count_for_goal] is retained as a compatibility wrapper. *)

type capacity_error = {
  goal_id : string;
  open_task_count : int;
  limit : int;
  message : string;
}

let default_goal_open_limit = 3
let goal_task_links_read_failed_prefix =
  Workspace_goal_index.goal_task_links_read_failed_prefix
;;

let goal_task_links_read_failed_message =
  Workspace_goal_index.goal_task_links_read_failed_message

(** Compatibility wrapper — O(k) lookup via a pre-built index.
    Retained for existing callers that have an index available. *)
let open_task_count_for_goal ~goal_id index =
  Workspace_goal_index.open_task_count_for_goal_indexed index ~goal_id
;;

(** [check ?goal_id backlog] returns [None] when [add_task] may proceed,
    [Some err] when adding another open task linked to [goal_id] would
    exceed [default_goal_open_limit].

    When [goal_id = None] the check is a no-op (returns [None]) — orphan
    tasks bypass the per-goal cap.

    Note: after the task↔goal boundary refactor, goal-task links are no
    longer stored on task records. The capacity check relies on an
    external [goal_task_links] registry. Until that registry is wired,
    passing [goal_id] without supplying links will always yield [None]. *)
let check ?goal_id ?(goal_task_links = []) (backlog : Masc_domain.backlog) =
  match goal_id with
  | None -> None
  | Some goal_id ->
    let index =
      Workspace_goal_index.build_goal_task_index backlog.tasks ~goal_task_links
    in
    let open_task_count =
      Workspace_goal_index.open_task_count_for_goal_indexed index ~goal_id
    in
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

let check_for_config_result config ?goal_id backlog =
  match goal_id with
  | None -> Ok None
  | Some _ ->
    (match Workspace_goal_index.read_goal_task_links_r config with
     | Ok goal_task_links -> Ok (check ?goal_id ~goal_task_links backlog)
     | Error msg -> Error (goal_task_links_read_failed_message msg))
;;

let check_for_config config ?goal_id backlog =
  match check_for_config_result config ?goal_id backlog with
  | Ok result -> result
  | Error msg -> raise (Sys_error msg)
;;

(* Field order matches the pre-RFC-0034.v2 shape produced by
   [Keeper_tool_shared_runtime.error_json ~fields message], which prepends
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

let rejection_for_add_task_for_config config ?goal_id backlog =
  match check_for_config_result config ?goal_id backlog with
  | Ok result -> Option.map (fun err -> err.message) result
  | Error msg -> Some msg
;;
