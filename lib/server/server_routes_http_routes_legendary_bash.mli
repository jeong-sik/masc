(** Server_routes_http_routes_legendary_bash — HTTP routes for the
    legendary-bash background-task dashboard.

    Internal serialization helpers ([snapshot_response],
    [task_detail_json]) are hidden. {!bg_tasks_response} is exposed as
    a pure function so [test_legendary_bash_bg_tasks_route] can lock
    its JSON contract independently of the route pipeline. *)

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t

val bg_tasks_response : keeper:string -> Yojson.Safe.t
(** Build the [GET /api/v1/legendary_bash/bg_tasks] response payload
    for [keeper]. Returns
    [{ "keeper": ..., "count": N, "tasks": \[...\], "task_details": \[...\] }].
    Pure: reads the in-process [Bg_task] state. *)
