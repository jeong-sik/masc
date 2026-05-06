(** Legendary Bash dark-launch observer HTTP surface.

    Exposes the in-process [Legendary_counters] snapshot and the
    [Bg_task.list] per-keeper task roster as public-read JSON endpoints
    for dashboards and flip-decision tooling.  The counters themselves
    are incremented only while the matching observer env flag is
    enabled (see [LEGENDARY-BASH-RUNBOOK.md]); this endpoint is a
    zero-cost read.

      GET /api/v1/legendary_bash/shadow_counters
      GET /api/v1/legendary_bash/bg_tasks/<keeper>
      GET /api/dashboard/keeper-shell/<keeper>

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
    posture.

    [keeper-shell] is a read-only SSE bridge over the same
    [Bg_task.read] buffer.  It follows the newest live task by default
    or a fixed [task_id] query parameter when supplied. *)

open Server_utils
open Server_auth

module Http = Http_server_eio

type keeper_shell_snapshot = {
  json : Yojson.Safe.t;
  task_id : string option;
  next_stdout : int;
  next_stderr : int;
  closed : bool;
}

let snapshot_response () : Yojson.Safe.t =
  let snap = Legendary_counters.snapshot () in
  Legendary_counters.snapshot_to_json_with_ratios snap

let task_detail_json ~now (tid, started_at) : Yojson.Safe.t =
  let elapsed_ms =
    let seconds = max 0.0 (now -. started_at) in
    int_of_float (seconds *. 1000.0)
  in
  `Assoc [
    ("task_id", `String (Bg_task.task_id_to_string tid));
    ("started_at_unix", `Float started_at);
    ("elapsed_ms", `Int elapsed_ms);
  ]

let bg_tasks_response ~keeper : Yojson.Safe.t =
  let rows = Bg_task.list_with_started_at ~keeper in
  let now = Unix.gettimeofday () in
  let ids_as_strings =
    List.map (fun (tid, _) -> Bg_task.task_id_to_string tid) rows
  in
  `Assoc [
    ("keeper", `String keeper);
    ("count", `Int (List.length rows));
    ("tasks", `List (List.map (fun s -> `String s) ids_as_strings));
    ("task_details",
     `List (List.map (task_detail_json ~now) rows));
  ]

let status_to_json_opt = function
  | None -> `Null
  | Some status -> Keeper_alerting_path.process_status_to_json status

let newest_task_id_for_keeper ~keeper =
  Bg_task.list_with_started_at ~keeper
  |> List.sort (fun (_, left) (_, right) -> Float.compare right left)
  |> function
  | [] -> None
  | (tid, _) :: _ -> Some (Bg_task.task_id_to_string tid)

let keeper_shell_no_task_snapshot ~keeper ~since_stdout ~since_stderr =
  {
    json =
      `Assoc
        [
          ("type", `String "no_task");
          ("keeper", `String keeper);
          ("task_id", `Null);
          ("task_count", `Int 0);
          ("since_stdout", `Int since_stdout);
          ("since_stderr", `Int since_stderr);
          ("stdout_since", `String "");
          ("stderr_since", `String "");
          ("closed", `Bool true);
          ("status", `Null);
          ("bytes_dropped_stdout", `Int 0);
          ("bytes_dropped_stderr", `Int 0);
          ("generated_at", `Float (Unix.gettimeofday ()));
        ];
    task_id = None;
    next_stdout = since_stdout;
    next_stderr = since_stderr;
    closed = true;
  }

let keeper_shell_error_snapshot ~keeper ~task_id ~message ~since_stdout
    ~since_stderr =
  {
    json =
      `Assoc
        [
          ("type", `String "error");
          ("keeper", `String keeper);
          ("task_id", `String task_id);
          ("message", `String message);
          ("since_stdout", `Int since_stdout);
          ("since_stderr", `Int since_stderr);
          ("stdout_since", `String "");
          ("stderr_since", `String "");
          ("closed", `Bool true);
          ("status", `Null);
          ("bytes_dropped_stdout", `Int 0);
          ("bytes_dropped_stderr", `Int 0);
          ("generated_at", `Float (Unix.gettimeofday ()));
        ];
    task_id = Some task_id;
    next_stdout = since_stdout;
    next_stderr = since_stderr;
    closed = true;
  }

let keeper_shell_snapshot_response ?task_id ~keeper ~since_stdout
    ~since_stderr () : keeper_shell_snapshot =
  let chosen_task_id =
    match task_id with
    | Some raw when String.trim raw <> "" -> Some (String.trim raw)
    | _ -> newest_task_id_for_keeper ~keeper
  in
  match chosen_task_id with
  | None ->
      keeper_shell_no_task_snapshot ~keeper ~since_stdout ~since_stderr
  | Some task_id -> (
      match Bg_task.task_id_of_string task_id with
      | Error message ->
          keeper_shell_error_snapshot ~keeper ~task_id ~message ~since_stdout
            ~since_stderr
      | Ok tid -> (
          match Bg_task.read tid ~since_stdout ~since_stderr with
          | Error (Bg_task.Unknown_task _) ->
              keeper_shell_error_snapshot ~keeper ~task_id
                ~message:
                  (Printf.sprintf
                     "no background task with id=%s (already reaped or never spawned)"
                     task_id)
                ~since_stdout ~since_stderr
          | Error (Bg_task.Read_failed message) ->
              keeper_shell_error_snapshot ~keeper ~task_id
                ~message:("bash_output read failed: " ^ message)
                ~since_stdout ~since_stderr
          | Ok snap ->
              let next_stdout =
                since_stdout + snap.bytes_dropped_stdout
                + String.length snap.stdout_since
              in
              let next_stderr =
                since_stderr + snap.bytes_dropped_stderr
                + String.length snap.stderr_since
              in
              let task_count =
                List.length (Bg_task.list_with_started_at ~keeper)
              in
              {
                json =
                  `Assoc
                    [
                      ("type", `String "snapshot");
                      ("keeper", `String keeper);
                      ("task_id", `String task_id);
                      ("task_count", `Int task_count);
                      ("since_stdout", `Int next_stdout);
                      ("since_stderr", `Int next_stderr);
                      ("stdout_since", `String snap.stdout_since);
                      ("stderr_since", `String snap.stderr_since);
                      ("closed", `Bool snap.closed);
                      ("status", status_to_json_opt snap.status);
                      ( "bytes_dropped_stdout",
                        `Int snap.bytes_dropped_stdout );
                      ( "bytes_dropped_stderr",
                        `Int snap.bytes_dropped_stderr );
                      ("generated_at", `Float (Unix.gettimeofday ()));
                    ];
                task_id = Some task_id;
                next_stdout;
                next_stderr;
                closed = snap.closed;
              }))

let keeper_shell_sse_frame json =
  "event: shell\ndata: " ^ Yojson.Safe.to_string json ^ "\n\n"

let send_raw writer mutex closed data =
  if !closed || Httpun.Body.Writer.is_closed writer then begin
    closed := true;
    false
  end else
    try
      Eio.Mutex.use_rw ~protect:true mutex (fun () ->
          Httpun.Body.Writer.write_string writer data;
          Httpun.Body.Writer.flush writer (fun _ -> ()));
      true
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Log.Keeper.warn "keeper_shell_stream write failed: %s"
          (Printexc.to_string exn);
        closed := true;
        false

let handle_keeper_shell_stream ~sw ~clock request reqd ~keeper =
  let task_id = query_param request "task_id" in
  let since_stdout = ref (max 0 (int_query_param request "since_stdout" ~default:0)) in
  let since_stderr = ref (max 0 (int_query_param request "since_stderr" ~default:0)) in
  let fixed_task_id =
    match task_id with
    | Some raw when String.trim raw <> "" -> Some (String.trim raw)
    | _ -> None
  in
  let headers =
    Httpun.Headers.of_list
      ([
         ("content-type", "text/event-stream");
         ("cache-control", "no-cache");
         ("connection", "keep-alive");
         ("x-accel-buffering", "no");
       ]
      @ public_read_cors_headers request)
  in
  let response = Httpun.Response.create ~headers `OK in
  let writer = Httpun.Reqd.respond_with_streaming reqd response in
  let mutex = Eio.Mutex.create () in
  let closed = ref false in
  let close_stream () =
    if not !closed then begin
      closed := true;
      try Httpun.Body.Writer.close writer
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          Log.Keeper.warn "keeper_shell_stream close failed: %s"
            (Printexc.to_string exn)
    end
  in
  ignore (send_raw writer mutex closed "retry: 1500\n\n");
  Eio.Fiber.fork ~sw (fun () ->
      ignore
        (Eio.Switch.run @@ fun stream_sw ->
         Eio.Switch.on_release stream_sw close_stream;
         let active_task_id = ref fixed_task_id in
         let rec loop emitted =
           if !closed then ()
           else begin
             let snapshot =
               keeper_shell_snapshot_response ?task_id:!active_task_id
                 ~keeper ~since_stdout:!since_stdout
                 ~since_stderr:!since_stderr ()
             in
             active_task_id := snapshot.task_id;
             let has_output =
               match snapshot.json with
               | `Assoc fields ->
                   (match List.assoc_opt "stdout_since" fields with
                    | Some (`String s) -> s <> ""
                    | _ -> false)
                   ||
                   (match List.assoc_opt "stderr_since" fields with
                    | Some (`String s) -> s <> ""
                    | _ -> false)
               | _ -> false
             in
             let should_emit =
               (not emitted)
               || has_output
               || snapshot.closed
             in
             if should_emit then begin
               ignore
                 (send_raw writer mutex closed
                    (keeper_shell_sse_frame snapshot.json));
               since_stdout := snapshot.next_stdout;
               since_stderr := snapshot.next_stderr
             end;
             if snapshot.closed then close_stream ()
             else begin
               Eio.Time.sleep clock 0.5;
               loop (emitted || should_emit)
             end
           end
         in
         loop false))

let add_routes ~sw ~clock router =
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
  |> Http.Router.prefix_get "/api/dashboard/keeper-shell/"
       (fun request reqd ->
         with_public_read
           (fun _state _req reqd ->
             let path = Http.Request.path request in
             match
               extract_path_param
                 ~prefix:"/api/dashboard/keeper-shell/" path
             with
             | None | Some "" ->
                 respond_public_read_json ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string
                      (`Assoc [ ("error", `String "keeper name is required") ]))
             | Some keeper ->
                 handle_keeper_shell_stream ~sw ~clock request reqd ~keeper)
           request reqd)
