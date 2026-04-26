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
    [Legendary_counters.snapshot] field-for-field, plus a [ratios]
    sibling object carrying the three derived flip-decision ratios
    ([disagree_ratio], [shadow_parse_coverage],
    [auto_bg_promotion_rate]) so consumers do not have to re-derive
    them client-side.  See [legendary_counters.mli] for the stable
    contract and the [Derived ratios (SSOT)] runbook section for the
    operator interpretation.

    Response (200) for bg_tasks: JSON of shape
      { "keeper": "<name>",
        "count": N,
        "tasks": [ "<task_id>", … ],
        "task_details": [
          { "task_id": "<id>",
            "started_at_unix": 1.73e9,
            "elapsed_ms": 1234 }, … ] }
    where [tasks] is the list returned by [Bg_task.list ~keeper] at
    the moment of the call; [task_details] attaches [started_at] and
    a server-computed [elapsed_ms] for observers that want wall-clock
    age without a second round-trip.  Both arrays share the same
    order, so [tasks.[i]] and [task_details.[i].task_id] agree.
    Unknown / quiet keepers legitimately return [count = 0,
    tasks = [], task_details = []] — the endpoint does not validate
    keeper existence, mirroring [shadow_counters]' "zero-cost read"
    posture. *)

open Server_utils
open Server_auth
module Http = Http_server_eio

let snapshot_response () : Yojson.Safe.t =
  let snap = Legendary_counters.snapshot () in
  Legendary_counters.snapshot_to_json_with_ratios snap
;;

let task_detail_json ~now (tid, started_at) : Yojson.Safe.t =
  let elapsed_ms =
    let seconds = max 0.0 (now -. started_at) in
    int_of_float (seconds *. 1000.0)
  in
  `Assoc
    [ "task_id", `String (Bg_task.task_id_to_string tid)
    ; "started_at_unix", `Float started_at
    ; "elapsed_ms", `Int elapsed_ms
    ]
;;

let bg_tasks_response ~keeper : Yojson.Safe.t =
  let rows = Bg_task.list_with_started_at ~keeper in
  let now = Unix.gettimeofday () in
  let ids_as_strings = List.map (fun (tid, _) -> Bg_task.task_id_to_string tid) rows in
  `Assoc
    [ "keeper", `String keeper
    ; "count", `Int (List.length rows)
    ; "tasks", `List (List.map (fun s -> `String s) ids_as_strings)
    ; "task_details", `List (List.map (task_detail_json ~now) rows)
    ]
;;

let add_routes router =
  router
  |> Http.Router.get "/api/v1/legendary_bash/shadow_counters" (fun request reqd ->
    with_public_read
      (fun _state _req reqd ->
         let json = snapshot_response () in
         respond_public_read_json ~status:`OK request reqd (Yojson.Safe.to_string json))
      request
      reqd)
  |> Http.Router.prefix_get "/api/v1/legendary_bash/bg_tasks/" (fun request reqd ->
    with_public_read
      (fun _state _req reqd ->
         let path = Http.Request.path request in
         match extract_path_param ~prefix:"/api/v1/legendary_bash/bg_tasks/" path with
         | None | Some "" ->
           Http.Response.json
             (Yojson.Safe.to_string
                (`Assoc [ "error", `String "keeper name is required" ]))
             ~status:`Bad_request
             reqd
         | Some keeper ->
           let json = bg_tasks_response ~keeper in
           respond_public_read_json ~status:`OK request reqd (Yojson.Safe.to_string json))
      request
      reqd)
;;
