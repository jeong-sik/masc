(** Tool_fire_task — Fire-and-forget background task execution.

    Single MCP call: create task, optionally provision worktree,
    spawn agent in background fiber. Caller gets task_id immediately.

    Background fiber lifecycle:
    1. join room (if not joined)
    2. claim the created task
    3. spawn agent subprocess with the goal as prompt
    4. on completion: transition task to done + leave room
    5. on failure: log error, transition task to cancelled *)

open Tool_args

type context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t;
}

(** Extract task_id from Room.add_task result string.
    Expected format: "... task-NNN: ..." *)
let extract_task_id result_str =
  let re = Re.Pcre.re {|task-[0-9]+|} |> Re.compile in
  match Re.exec_opt re result_str with
  | Some g -> Some (Re.Group.get g 0)
  | None -> None

(** Build the prompt that the spawned agent will receive. *)
let build_agent_prompt ~goal ~task_id ~worktree_path =
  let wt_section = match worktree_path with
    | Some p ->
      Printf.sprintf "\n\nWorking directory: %s\nAll file changes should be made in this worktree." p
    | None -> ""
  in
  Printf.sprintf
    "You are executing MASC task %s.\n\n\
     Goal: %s%s\n\n\
     After completing the goal, call masc_done with task_id=%s and a summary of what you did."
    task_id goal wt_section task_id

(** Run the background agent lifecycle in a forked fiber.
    This function is called inside [Eio.Fiber.fork_daemon].
    When [sandbox] is provided, uses sandbox worktree and cleans up on completion. *)
let run_background_agent config ~agent_cli ~agent_name ~task_id ~goal
    ~worktree_path ~sandbox =
  (* Step 1: ensure the spawned agent identity joins the room *)
  let _join_result =
    Room.join config ~agent_name ~capabilities:["fire_task"] ()
  in

  (* Step 2: claim the task *)
  let claim_msg = Room.claim_task config ~agent_name ~task_id in
  Log.Misc.info "[fire_task] claim %s by %s: %s" task_id agent_name claim_msg;

  (* Step 3: transition to in_progress *)
  let _start = Room.transition_task_r config ~agent_name ~task_id ~action:Types.Start () in

  (* Step 4: spawn the agent subprocess *)
  let prompt = build_agent_prompt ~goal ~task_id ~worktree_path in
  let working_dir = worktree_path in
  let result = Spawn.spawn ~agent_name:agent_cli ~prompt ?working_dir () in

  (* Step 5: complete or cancel based on result *)
  if result.success then begin
    (* Collect changed files from sandbox before cleanup *)
    let changed_note = match sandbox with
      | Some sb ->
        let files = Task_sandbox.changed_files sb in
        if files = [] then ""
        else Printf.sprintf "\nChanged files: %s" (String.concat ", " files)
      | None -> ""
    in
    let truncated_output =
      let s = result.output in
      if String.length s > 500 then String.sub s 0 500 ^ "..." else s
    in
    let notes = Printf.sprintf "Agent output: %s%s" truncated_output changed_note in
    let _done_msg = Room.complete_task config ~agent_name ~task_id ~notes in
    Log.Misc.info "[fire_task] %s completed %s (exit=%d, %dms)"
      agent_name task_id result.exit_code result.elapsed_ms
  end else begin
    let truncated_err =
      let s = result.output in
      if String.length s > 300 then String.sub s 0 300 ^ "..." else s
    in
    let reason = Printf.sprintf "Agent failed (exit %d): %s"
      result.exit_code truncated_err in
    let _cancel = Room.cancel_task_r config ~agent_name ~task_id ~reason in
    Log.Misc.warn "[fire_task] %s failed %s: %s" agent_name task_id reason
  end;

  (* Step 6: sandbox cleanup *)
  (match sandbox with
   | Some sb ->
     (match Task_sandbox.cleanup ~config ~agent_name sb with
      | Ok files ->
        Log.Misc.info "[fire_task] sandbox cleanup for %s: %d changed files"
          task_id (List.length files)
      | Error e ->
        Log.Misc.warn "[fire_task] sandbox cleanup failed for %s: %s" task_id e)
   | None -> ());

  (* Step 7: leave *)
  let _leave = Room.leave config ~agent_name in
  ()

let handle_fire_task ctx args =
  let ( let*! ) = ( let*! ) in
  let*! goal = get_string_required args "goal" in
  let agent_cli = get_string args "agent" (Provider_adapter.default_cli_agent_name ()) in
  let priority = get_int args "priority" 3 in
  let use_worktree = get_bool args "use_worktree" false in

  (* Derive a spawn-agent name distinct from the caller *)
  let spawn_agent_name = Printf.sprintf "%s-fire" agent_cli in

  (* Step 1: create the task in the backlog *)
  let add_result = Room.add_task ctx.config
    ~title:goal ~priority ~description:"Fire-and-forget task" in

  match extract_task_id add_result with
  | None ->
    error_result (Printf.sprintf "Failed to create task: %s" add_result)
  | Some task_id ->

  (* Step 2: optionally create sandbox (worktree + .masc symlink + scope) *)
  let sandbox, worktree_path =
    if use_worktree then
      match Task_sandbox.create ~config:ctx.config ~task_id
              ~agent_name:spawn_agent_name () with
      | Ok sb ->
        Log.Misc.info "[fire_task] sandbox created for %s at %s"
          task_id sb.worktree_path;
        (Some sb, Some sb.worktree_path)
      | Error e ->
        Log.Misc.warn "[fire_task] sandbox creation failed: %s" e;
        (None, None)
    else (None, None)
  in

  (* Step 3: fork background fiber -- returns immediately *)
  Eio.Fiber.fork_daemon ~sw:ctx.sw (fun () ->
    (try
       run_background_agent ctx.config
         ~agent_cli ~agent_name:spawn_agent_name
         ~task_id ~goal ~worktree_path ~sandbox
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.Misc.error "[fire_task] background fiber crashed for %s: %s"
         task_id (Printexc.to_string exn);
       (* Best-effort sandbox cleanup *)
       (match sandbox with
        | Some sb ->
          let _ = Task_sandbox.cleanup ~config:ctx.config
                    ~agent_name:spawn_agent_name sb in ()
        | None -> ());
       (* Best-effort cancel *)
       let _cancel = Room.cancel_task_r ctx.config
         ~agent_name:spawn_agent_name ~task_id
         ~reason:(Printf.sprintf "fiber crash: %s" (Printexc.to_string exn)) in
       ());
    `Stop_daemon
  );

  (* Step 4: return immediately *)
  ok_result [
    ("task_id", `String task_id);
    ("agent", `String spawn_agent_name);
    ("worktree_path", match worktree_path with
      | Some p -> `String p
      | None -> `Null);
    ("sandbox", match sandbox with
      | Some _ -> `Bool true
      | None -> `Bool false);
    ("status", `String "spawned");
    ("message", `String (Printf.sprintf
      "Task %s spawned to %s. Check progress with masc_status." task_id agent_cli));
  ]

(** Dispatch function — returns None if tool not handled. *)
let dispatch ctx ~name ~args =
  match name with
  | "masc_fire_task" -> Some (handle_fire_task ctx args)
  | _ -> None

let schemas = Tool_schemas_fire_task.schemas

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_fire_task
           ~input_schema:s.input_schema
           ()))
    schemas
