(** Async_spawn — non-blocking agent execution with job tracking.

    Wraps Spawn_eio.spawn in an Eio fiber so the caller gets a job_id
    immediately and can poll for completion later. Inspired by Deep Agents
    AsyncSubAgentMiddleware.

    The registry is protected by Eio.Mutex (not Stdlib.Mutex) to avoid
    EDEADLK under Eio cooperative scheduling.

    @since 2.112.0 *)

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type job_status =
  | Running
  | Completed of Spawn_eio.spawn_result
  | Failed of string
  | Cancelled

type job = {
  job_id : string;
  agent_name : string;
  prompt_preview : string;
  started_at : float;
  mutable status : job_status;
  mutable finished_at : float option;
}

type registry = {
  jobs : (string, job) Hashtbl.t;
  mu : Eio.Mutex.t;
}

(* ================================================================ *)
(* Registry lifecycle                                               *)
(* ================================================================ *)

let create_registry () : registry =
  { jobs = Hashtbl.create 16; mu = Eio.Mutex.create () }

(** Generate a short unique job id: "job-<8-hex-chars>" *)
let generate_job_id () =
  let uuid = Uuidm.v4_gen (Random.State.make_self_init ()) () in
  let hex = Uuidm.to_string uuid |> String.split_on_char '-' |> String.concat "" in
  Printf.sprintf "job-%s" (String.sub hex 0 8)

(** Truncate prompt to first [n] characters for preview. *)
let truncate_prompt ?(n = 100) prompt =
  if String.length prompt <= n then prompt
  else String.sub prompt 0 n ^ "..."

(* ================================================================ *)
(* Core operations                                                  *)
(* ================================================================ *)

(** Submit a job that runs [run_fn] in a background Eio fiber.

    [run_fn] is the function that performs the actual work (typically
    [Spawn_eio.spawn] partially applied with all spawn arguments).
    This indirection enables mock injection in tests.

    Returns the job record immediately. The fiber updates [job.status]
    and [job.finished_at] when it completes, fails, or is cancelled. *)
let submit_job (reg : registry) ~sw ~agent_name ~prompt
    (run_fn : unit -> Spawn_eio.spawn_result) : job =
  let job_id = generate_job_id () in
  let job = {
    job_id;
    agent_name;
    prompt_preview = truncate_prompt prompt;
    started_at = Time_compat.now ();
    status = Running;
    finished_at = None;
  } in
  Eio.Mutex.use_rw ~protect:true reg.mu (fun () ->
    Hashtbl.replace reg.jobs job_id job);
  (* Fork a fiber that runs the spawn function and records the result. *)
  Eio.Fiber.fork ~sw (fun () ->
    let finish status =
      Eio.Mutex.use_rw ~protect:true reg.mu (fun () ->
        job.status <- status;
        job.finished_at <- Some (Time_compat.now ()))
    in
    match run_fn () with
    | result -> finish (Completed result)
    | exception exn ->
        let msg = Printexc.to_string exn in
        finish (Failed msg));
  job

let get_job (reg : registry) job_id : job option =
  Eio.Mutex.use_rw ~protect:false reg.mu (fun () ->
    Hashtbl.find_opt reg.jobs job_id)

let cancel_job (reg : registry) job_id : bool =
  Eio.Mutex.use_rw ~protect:true reg.mu (fun () ->
    match Hashtbl.find_opt reg.jobs job_id with
    | Some job when (match job.status with Running -> true | _ -> false) ->
        job.status <- Cancelled;
        job.finished_at <- Some (Time_compat.now ());
        true
    | _ -> false)

let list_jobs (reg : registry) : job list =
  Eio.Mutex.use_rw ~protect:false reg.mu (fun () ->
    Hashtbl.fold (fun _k v acc -> v :: acc) reg.jobs [])

(** Remove completed/failed/cancelled jobs older than [max_age_s] seconds.
    Returns the number of removed entries. *)
let cleanup_completed (reg : registry) ~max_age_s : int =
  let now = Time_compat.now () in
  Eio.Mutex.use_rw ~protect:true reg.mu (fun () ->
    let to_remove = Hashtbl.fold (fun k (j : job) acc ->
      match j.status with
      | Running -> acc
      | _ ->
          let age = match j.finished_at with
            | Some t -> now -. t
            | None -> now -. j.started_at
          in
          if age > max_age_s then k :: acc else acc
    ) reg.jobs [] in
    List.iter (Hashtbl.remove reg.jobs) to_remove;
    List.length to_remove)

(* ================================================================ *)
(* JSON serialization helpers                                       *)
(* ================================================================ *)

let status_to_string = function
  | Running -> "running"
  | Completed _ -> "completed"
  | Failed _ -> "failed"
  | Cancelled -> "cancelled"

let job_to_json (j : job) : Yojson.Safe.t =
  let base = [
    ("job_id", `String j.job_id);
    ("agent_name", `String j.agent_name);
    ("prompt_preview", `String j.prompt_preview);
    ("started_at", `Float j.started_at);
    ("status", `String (status_to_string j.status));
  ] in
  let with_finished = match j.finished_at with
    | Some t -> base @ [("finished_at", `Float t)]
    | None -> base
  in
  let with_result = match j.status with
    | Completed r ->
        with_finished @ [
          ("success", `Bool r.success);
          ("exit_code", `Int r.exit_code);
          ("elapsed_ms", `Int r.elapsed_ms);
          ("output_preview", `String (truncate_prompt ~n:500 r.output));
        ]
    | Failed msg ->
        with_finished @ [("error", `String msg)]
    | _ -> with_finished
  in
  `Assoc with_result
