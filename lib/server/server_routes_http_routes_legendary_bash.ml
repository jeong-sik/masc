(** Legendary Bash dark-launch observer HTTP surface.

    Exposes the in-process [Legendary_counters] snapshot and the
    [Bg_task.list] per-keeper task roster as public-read JSON endpoints
    for dashboards and flip-decision tooling.  The counters themselves
    are incremented only while the matching observer env flag is
    enabled (see [LEGENDARY-BASH-RUNBOOK.md]); this endpoint is a
    zero-cost read.

      GET /api/v1/legendary_bash/shadow_counters
      GET /api/v1/legendary_bash/bg_tasks/<keeper>

    Response (200) for shadow_counters: JSON shape mirrors
    [Legendary_counters.snapshot] field-for-field. See
    [legendary_counters.mli] for the stable contract.

    Response (200) for bg_tasks: JSON of shape
      { "keeper": "<name>", "count": N, "tasks": [ "<task_id>", … ] }
    where [tasks] is the list returned by [Bg_task.list ~keeper] at
    the moment of the call.  Unknown / quiet keepers legitimately
    return [count = 0, tasks = []] — the endpoint does not validate
    keeper existence, mirroring [shadow_counters]' "zero-cost read"
    posture. *)

open Server_utils
open Server_auth

module Http = Http_server_eio

let snapshot_response () : Yojson.Safe.t =
  let snap = Legendary_counters.snapshot () in
  Legendary_counters.snapshot_to_json snap

let bg_tasks_response ~keeper : Yojson.Safe.t =
  let ids = Bg_task.list ~keeper in
  let as_strings = List.map Bg_task.task_id_to_string ids in
  `Assoc [
    ("keeper", `String keeper);
    ("count", `Int (List.length ids));
    ("tasks", `List (List.map (fun s -> `String s) as_strings));
  ]

let add_routes router =
  router
  |> Http.Router.get "/api/v1/legendary_bash/shadow_counters"
       (fun request reqd ->
         with_public_read
           (fun _state _req reqd ->
             let json = snapshot_response () in
             respond_public_read_json ~status:`OK request reqd
               (Yojson.Safe.to_string json))
           request reqd)
  |> Http.Router.prefix_get "/api/v1/legendary_bash/bg_tasks/"
       (fun request reqd ->
         with_public_read
           (fun _state _req reqd ->
             let path = Http.Request.path request in
             match
               extract_path_param
                 ~prefix:"/api/v1/legendary_bash/bg_tasks/" path
             with
             | None | Some "" ->
                 Http.Response.json
                   (Yojson.Safe.to_string
                      (`Assoc [
                         ("error", `String "keeper name is required");
                       ]))
                   ~status:`Bad_request reqd
             | Some keeper ->
                 let json = bg_tasks_response ~keeper in
                 respond_public_read_json ~status:`OK request reqd
                   (Yojson.Safe.to_string json))
           request reqd)
