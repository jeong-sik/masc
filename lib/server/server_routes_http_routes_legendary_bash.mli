(** Server_routes_http_routes_legendary_bash — HTTP routes for the
    legendary-bash background-task dashboard.

    Internal serialization helpers ([snapshot_response],
    [task_detail_json]) are hidden. {!bg_tasks_response} is exposed as
    a pure function so [test_legendary_bash_bg_tasks_route] can lock
    its JSON contract independently of the route pipeline. *)

type keeper_shell_snapshot = {
  json : Yojson.Safe.t;
  task_id : string option;
  next_stdout : int;
  next_stderr : int;
  closed : bool;
}

val add_routes :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  Http_server_eio.Router.t ->
  Http_server_eio.Router.t

val bg_tasks_response : keeper:string -> Yojson.Safe.t
(** Build the [GET /api/v1/legendary_bash/bg_tasks] response payload
    for [keeper]. Returns
    [{ "keeper": ..., "count": N, "tasks": \[...\], "task_details": \[...\] }].
    Pure: reads the in-process [Bg_task] state. *)

val keeper_shell_snapshot_response :
  ?task_id:string ->
  keeper:string ->
  since_stdout:int ->
  since_stderr:int ->
  unit ->
  keeper_shell_snapshot
(** Build one [GET /api/dashboard/keeper-shell/<keeper>] SSE payload.
    With no [task_id], follows the newest task currently registered for
    [keeper].  [next_stdout] / [next_stderr] are the byte offsets a
    client should use for the next poll. *)
