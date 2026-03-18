(** Tool_async_spawn — MCP tool schemas and dispatch for async agent spawning.

    Provides 3 MCP tools:
    - masc_async_spawn  — Start a background agent, return job_id immediately
    - masc_job_status   — Query a job by id
    - masc_job_list     — List all tracked jobs

    @since 2.112.0 *)

(* ================================================================ *)
(* Global registry — single instance per server process             *)
(* ================================================================ *)

let global_registry = Async_spawn.create_registry ()

(* ================================================================ *)
(* Tool Schemas                                                     *)
(* ================================================================ *)

let schemas : Types.tool_schema list = [
  {
    name = "masc_async_spawn";
    description = "Start an agent in the background and return a job_id immediately. \
The agent runs as an Eio fiber; use masc_job_status to poll for completion. \
Accepts the same agent_name and prompt as masc_spawn but does not block.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent CLI to run (claude, gemini, codex, llama, glm)");
        ]);
        ("prompt", `Assoc [
          ("type", `String "string");
          ("description", `String "Task prompt for the agent");
        ]);
        ("timeout_seconds", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max execution time in seconds (default: from config)");
        ]);
        ("working_dir", `Assoc [
          ("type", `String "string");
          ("description", `String "Working directory for the agent (optional)");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "prompt"]);
    ];
  };

  {
    name = "masc_job_status";
    description = "Get the current status of an async job by its job_id. \
Returns running/completed/failed/cancelled with details.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("job_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Job ID returned by masc_async_spawn");
        ]);
      ]);
      ("required", `List [`String "job_id"]);
    ];
  };

  {
    name = "masc_job_list";
    description = "List all tracked async jobs with their current status. \
Optionally filter by status and clean up old completed jobs.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("status_filter", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by status: running, completed, failed, cancelled (optional, shows all if omitted)");
        ]);
        ("cleanup_age_seconds", `Assoc [
          ("type", `String "number");
          ("description", `String "Remove completed/failed/cancelled jobs older than this many seconds (optional)");
        ]);
      ]);
    ];
  };
]

(* ================================================================ *)
(* Context                                                          *)
(* ================================================================ *)

type context = {
  config : Room_utils.config;
  agent_name : string;
  sw : Eio.Switch.t;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
}

(* ================================================================ *)
(* Handlers                                                         *)
(* ================================================================ *)

let handle_async_spawn (ctx : context) args : bool * string =
  let agent_target = Safe_ops.json_string ~default:"claude" "agent_name" args in
  let prompt = Safe_ops.json_string ~default:"" "prompt" args in
  if prompt = "" then
    (false, "prompt is required")
  else
    match ctx.proc_mgr with
    | None ->
        (false, "proc_mgr unavailable (server not in Eio mode)")
    | Some _proc_mgr ->
        let timeout_seconds = Safe_ops.json_int_opt "timeout_seconds" args in
        let working_dir = Safe_ops.json_string_opt "working_dir" args in
        let room_config = Some ctx.config in
        let run_fn () =
          Spawn_eio.spawn
            ~sw:ctx.sw
            ~agent_name:agent_target
            ~prompt
            ?timeout_seconds
            ?working_dir
            ?room_config
            ()
        in
        let job = Async_spawn.submit_job global_registry
            ~sw:ctx.sw ~agent_name:agent_target ~prompt run_fn in
        let response = `Assoc [
          ("job_id", `String job.job_id);
          ("agent_name", `String job.agent_name);
          ("status", `String "running");
          ("prompt_preview", `String job.prompt_preview);
          ("started_at", `Float job.started_at);
        ] in
        (true, Yojson.Safe.to_string response)

let handle_job_status _ctx args : bool * string =
  let job_id = Safe_ops.json_string ~default:"" "job_id" args in
  if job_id = "" then
    (false, "job_id is required")
  else
    match Async_spawn.get_job global_registry job_id with
    | None ->
        (false, Printf.sprintf "Job not found: %s" job_id)
    | Some job ->
        (true, Yojson.Safe.to_string (Async_spawn.job_to_json job))

let handle_job_list _ctx args : bool * string =
  (* Optional cleanup *)
  let cleanup_age = Safe_ops.json_float_opt "cleanup_age_seconds" args in
  let cleaned = match cleanup_age with
    | Some age when age > 0.0 ->
        Async_spawn.cleanup_completed global_registry ~max_age_s:age
    | _ -> 0
  in
  let status_filter = Safe_ops.json_string_opt "status_filter" args in
  let all_jobs = Async_spawn.list_jobs global_registry in
  let filtered = match status_filter with
    | None -> all_jobs
    | Some f ->
        List.filter (fun (j : Async_spawn.job) ->
          Async_spawn.status_to_string j.status = f
        ) all_jobs
  in
  (* Sort by started_at descending *)
  let sorted = List.sort (fun (a : Async_spawn.job) (b : Async_spawn.job) ->
    compare b.started_at a.started_at
  ) filtered in
  let jobs_json = `List (List.map Async_spawn.job_to_json sorted) in
  let response = `Assoc [
    ("total", `Int (List.length all_jobs));
    ("shown", `Int (List.length sorted));
    ("cleaned_up", `Int cleaned);
    ("jobs", jobs_json);
  ] in
  (true, Yojson.Safe.to_string response)

(* ================================================================ *)
(* Dispatch                                                         *)
(* ================================================================ *)

let dispatch (ctx : context) ~name ~args : (bool * string) option =
  match name with
  | "masc_async_spawn" -> Some (handle_async_spawn ctx args)
  | "masc_job_status" -> Some (handle_job_status ctx args)
  | "masc_job_list" -> Some (handle_job_list ctx args)
  | _ -> None
