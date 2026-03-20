(** Room_walph_eio: Eio-native Walph (Walph Wiggum variant) implementation

    Inspired by Geoffrey Huntley's Walph (Walph Wiggum variant) technique:
    @see https://ghuntley.com/ralph/

    Production-ready implementation using Eio concurrency primitives:
    - Eio.Mutex for thread-safe state access (fiber-friendly, non-blocking)
    - Eio.Condition for pause/resume (no busy-wait, proper fiber scheduling)
    - Fun.protect for exception safety (no zombie states)

    This module is designed to run inside Eio fiber context.
    For pure sync/testing, use Room.walph_* functions instead.

    @see Room for sync implementation (testing)
    @see mcp_server_eio for production usage
*)

(** {1 Types} *)

(** Walph (Walph Wiggum variant) state with Eio concurrency primitives *)
type walph_state = {
  mutable running : bool;
  mutable paused : bool;
  mutable stop_requested : bool;
  mutable current_preset : string;
  mutable iterations : int;
  mutable completed : int;
  mutable claimed : int;
  mutable released_on_error : int;
  mutable errors : int;
  mutable consecutive_errors : int;
  mutable max_consecutive_errors : int;
  mutable error_backoff_sec : int;
  mutable last_error : string option;
  mutable last_task_id : string option;
  mutable started_at : string option;
  mutable last_stop_reason : string option;
  mutex : Eio.Mutex.t;        (** Eio-native mutex (fiber-friendly) *)
  cond : Eio.Condition.t;     (** Eio-native condition variable *)
}

(** {1 State Management} *)

(** Global Walph state table with Eio mutex for thread-safe access *)
let walph_states : (string, walph_state) Hashtbl.t = Hashtbl.create 16
let walph_states_mutex = Eio.Mutex.create ()

(** Escape colon in agent_name to prevent key collision.
    "agent:foo" -> "agent::foo" (double colon as escape)
    Key format: "room||agent" using || as separator (unlikely in paths/names) *)
let escape_agent_name name =
  (* Replace | with || to escape, then use | as separator *)
  let buf = Buffer.create (String.length name) in
  String.iter (fun c ->
    if c = '|' then Buffer.add_string buf "||"
    else Buffer.add_char buf c
  ) name;
  Buffer.contents buf

(** Generate state key: room||agent for independent Walph per agent
    Uses || separator to avoid collision with : in paths *)
let make_walph_key config ~agent_name =
  if agent_name = "" then
    Error "Walph: agent_name cannot be empty"
  else
    Ok (Printf.sprintf "%s||%s" config.Room_utils.base_path (escape_agent_name agent_name))

(** Get or create Walph state for a specific agent (thread-safe)
    Each agent has independent Walph state, enabling parallel loops *)
let get_walph_state config ~agent_name =
  match make_walph_key config ~agent_name with
  | Error msg -> Error msg
  | Ok key ->
      Ok (Eio.Mutex.use_rw ~protect:true walph_states_mutex (fun () ->
        match Hashtbl.find_opt walph_states key with
        | Some s -> s
        | None ->
            let s = {
              running = false; paused = false; stop_requested = false;
              current_preset = ""; iterations = 0; completed = 0;
              claimed = 0; released_on_error = 0; errors = 0; consecutive_errors = 0;
              max_consecutive_errors = 5; error_backoff_sec = 2;
              last_error = None; last_task_id = None; started_at = None; last_stop_reason = None;
              mutex = Eio.Mutex.create ();
              cond = Eio.Condition.create ();
            } in
            Hashtbl.replace walph_states key s;
            s
      ))

(** Get or create Walph state, raising on error. For test convenience.
    @raise Invalid_argument if agent_name is empty *)
let get_walph_state_exn config ~agent_name =
  match get_walph_state config ~agent_name with
  | Ok s -> s
  | Error msg -> invalid_arg msg

(** Remove Walph state for an agent (cleanup to prevent memory leak)
    @return Error if Walph is still running (zombie prevention), Ok () otherwise *)
let remove_walph_state config ~agent_name =
  match make_walph_key config ~agent_name with
  | Error msg -> Error msg
  | Ok key ->
      Eio.Mutex.use_rw ~protect:true walph_states_mutex (fun () ->
        match Hashtbl.find_opt walph_states key with
        | None -> Ok ()  (* Already removed, no-op *)
        | Some state ->
            if state.running then
              Error (Printf.sprintf "Walph: cannot remove state for %s while running. Call STOP first." agent_name)
            else begin
              Hashtbl.remove walph_states key;
              Ok ()
            end
      )

(** List all active Walph states in a room (for swarm coordination)
    Uses || as separator to match make_walph_key *)
let list_walph_states config =
  let prefix = config.Room_utils.base_path ^ "||" in
  let prefix_len = String.length prefix in
  Eio.Mutex.use_rw ~protect:true walph_states_mutex (fun () ->
    Hashtbl.fold (fun key state acc ->
      if String.length key > prefix_len &&
         String.sub key 0 prefix_len = prefix then
        (* Extract agent name (still escaped, but usable as identifier) *)
        let agent = String.sub key prefix_len (String.length key - prefix_len) in
        (agent, state) :: acc
      else acc
    ) walph_states []
  )

(** Run function with Walph state mutex locked (Eio-native) *)
let with_walph_lock state f =
  Eio.Mutex.use_rw ~protect:true state.mutex f

(** JSON status payload for a single walph agent. *)
let walph_status_json config ~agent_name =
  match get_walph_state config ~agent_name with
  | Error msg ->
      `Assoc [
        ("ok", `Bool false);
        ("agent", `String agent_name);
        ("error", `String msg);
      ]
  | Ok state ->
      with_walph_lock state (fun () ->
        `Assoc [
          ("ok", `Bool true);
          ("agent", `String agent_name);
          ("running", `Bool state.running);
          ("paused", `Bool state.paused);
          ("stop_requested", `Bool state.stop_requested);
          ("preset", `String state.current_preset);
          ("iterations", `Int state.iterations);
          ("claimed", `Int state.claimed);
          ("completed", `Int state.completed);
          ("released_on_error", `Int state.released_on_error);
          ("errors", `Int state.errors);
          ("consecutive_errors", `Int state.consecutive_errors);
          ("max_consecutive_errors", `Int state.max_consecutive_errors);
          ("error_backoff_sec", `Int state.error_backoff_sec);
          ("last_task_id", Option.fold ~none:`Null ~some:(fun s -> `String s) state.last_task_id);
          ("last_error", Option.fold ~none:`Null ~some:(fun s -> `String s) state.last_error);
          ("started_at", Option.fold ~none:`Null ~some:(fun s -> `String s) state.started_at);
          ("last_stop_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) state.last_stop_reason);
        ]
      )

(** {1 Control Commands} *)

(** Handle @walph control command (Eio-native, fiber-safe)
    @param config Room configuration
    @param from_agent Agent sending the command (controls own Walph)
    @param command Command (STOP, PAUSE, RESUME, STATUS)
    @param args Command arguments
    @param target_agent Optional: control another agent's Walph (default: self)
    @return Response message *)
let walph_control config ~from_agent ~command ~args ?(target_agent=None) () =
  let agent_name = match target_agent with Some a -> a | None -> from_agent in
  match get_walph_state config ~agent_name with
  | Error msg -> msg
  | Ok state ->
  let response = with_walph_lock state (fun () ->
    match command with
    | "STOP" ->
        if state.running then begin
          state.stop_requested <- true;
          Eio.Condition.broadcast state.cond;  (* Wake up paused fibers *)
          Printf.sprintf "🛑 @walph STOP requested by %s (will stop after current iteration)" from_agent
        end else
          "ℹ️ @walph is not currently running"
    | "PAUSE" ->
        if state.running && not state.paused then begin
          state.paused <- true;
          Printf.sprintf "⏸️ @walph PAUSED by %s (use @walph RESUME to continue)" from_agent
        end else if state.paused then
          "ℹ️ @walph is already paused"
        else
          "ℹ️ @walph is not currently running"
    | "RESUME" ->
        if state.paused then begin
          state.paused <- false;
          Eio.Condition.broadcast state.cond;  (* Wake up paused fibers *)
          Printf.sprintf "▶️ @walph RESUMED by %s" from_agent
        end else if state.running then
          "ℹ️ @walph is already running"
        else
          "ℹ️ @walph is not currently running"
    | "STATUS" ->
        if state.running then
          Printf.sprintf
            "📊 @walph STATUS: %s (iter: %d, claimed: %d, done: %d, released: %d, errs: %d/%d, paused: %b)"
            state.current_preset state.iterations state.claimed state.completed
            state.released_on_error state.consecutive_errors state.max_consecutive_errors state.paused
        else
          "ℹ️ @walph is idle (use @walph START <preset> to begin)"
    | "START" ->
        (* START is handled by walph_loop, just acknowledge here *)
        if state.running then
          Printf.sprintf "⚠️ @walph is already running %s. Use @walph STOP first." state.current_preset
        else
          Printf.sprintf "✨ @walph START acknowledged. Args: %s" args
    | _ ->
        Printf.sprintf "❓ Unknown @walph command: %s. Valid: START, STOP, PAUSE, RESUME, STATUS" command
  ) in
  (* Broadcast the response *)
  let _ = Room.broadcast config ~from_agent:"walph" ~content:response in
  response

(** Check if Walph should continue looping (Eio-native, no busy-wait)
    Uses Eio.Condition for proper fiber scheduling.
    @param agent_name The agent whose Walph state to check
    @return true if should continue, false if should stop or state error *)
let walph_should_continue config ~agent_name =
  match get_walph_state config ~agent_name with
  | Error _ -> false  (* Cannot continue if state is invalid *)
  | Ok state ->
  (* Note: Eio.Condition.await requires mutex to be held, and atomically
     releases it while waiting, then reacquires before returning *)
  Eio.Mutex.use_rw ~protect:true state.mutex (fun () ->
    if state.stop_requested then false
    else if state.paused then begin
      (* Wait on condition variable - Eio-native, no busy-wait!
         This yields to other fibers while waiting *)
      while state.paused && not state.stop_requested do
        Eio.Condition.await_no_mutex state.cond
      done;
      not state.stop_requested
    end else true
  )

(** {1 Preset Mapping} *)

(** Map Walph preset to task type description.
    Previously mapped to legacy chain IDs, now used for direct LLM prompting.
    @param preset The loop preset (coverage, refactor, docs, drain)
    @return Some chain_id for presets with corresponding prompts, None for drain *)
let get_chain_id_for_preset = function
  | "coverage" -> Some "walph-coverage"
  | "refactor" -> Some "walph-refactor"
  | "docs" -> Some "walph-docs"
  | "review" -> Some "pr-review-pipeline"  (* PR self-review *)
  | "drain" -> None  (* No chain for simple drain *)
  | "figma" -> Some "walph-figma"
  | _ -> None

let walph_response_is_valid (resp : Llm_provider.Types.api_response) =
  let content = String.trim (Cascade.text_of_response resp) in
  let lower = String.lowercase_ascii content in
  let len = String.length content in
  len > 0
  && not (len >= 5 && String.sub lower 0 5 = "error")
  && not (len >= 14 && String.sub content 0 14 = "Empty response")
  && not (len >= 9 && String.sub content 0 9 = "{\"error\":")

let default_llm_dispatch ~tool_name:_ ~model:_ ~prompt ~timeout_sec ~max_chars () =
  match
    Cascade.complete ~cascade_name:"walph"
      ~messages:[Cascade.user_msg prompt] ~timeout_sec
      ~max_tokens:max_chars ~accept:walph_response_is_valid ()
  with
  | Ok resp -> Cascade.text_of_response resp
  | Error err -> failwith err

(** {1 Main Loop} *)

(** Walph (Walph Wiggum variant) pattern: Keep claiming tasks until stop condition
    Eio-native implementation with fiber-safe concurrency.

    @param net Eio network capability (unused after legacy chain removal)
    @param clock Eio clock capability (for hard timeouts)
    @param preset Loop preset (drain, coverage, refactor, docs)
    @param max_iterations Maximum iterations before forced stop
    @param target Target file/directory for preset
    @return Status string with loop results *)
let walph_loop config ~net:_net ~clock ~agent_name
    ?(preset="drain") ?(max_iterations=10) ?target
    ?(max_consecutive_errors=5) ?(error_backoff_sec=2)
    ?(llm_dispatch=default_llm_dispatch) () =
  Room.ensure_initialized config;

  (* Get Walph state for this specific agent *)
  match get_walph_state config ~agent_name with
  | Error msg -> msg  (* Return error message directly *)
  | Ok walph_state ->

  (* Atomic check-and-set to prevent double-start race condition *)
  let start_result = with_walph_lock walph_state (fun () ->
    if walph_state.running then
      Error (Printf.sprintf "⚠️ @walph is already running %s. Use @walph STOP first." walph_state.current_preset)
    else begin
      (* Atomically set running=true under lock *)
      walph_state.running <- true;
      walph_state.paused <- false;
      walph_state.stop_requested <- false;
      walph_state.current_preset <- preset;
      walph_state.iterations <- 0;
      walph_state.completed <- 0;
      walph_state.claimed <- 0;
      walph_state.released_on_error <- 0;
      walph_state.errors <- 0;
      walph_state.consecutive_errors <- 0;
      walph_state.max_consecutive_errors <- max 1 max_consecutive_errors;
      walph_state.error_backoff_sec <- max 0 error_backoff_sec;
      walph_state.last_error <- None;
      walph_state.last_task_id <- None;
      walph_state.started_at <- Some (Types.now_iso ());
      walph_state.last_stop_reason <- None;
      Ok ()
    end
  ) in

  match start_result with
  | Error msg ->
      let _ = Room.broadcast config ~from_agent:"walph" ~content:msg in
      msg
	  | Ok () ->
	      (* Use Fun.protect to ensure running <- false even on exceptions (zombie prevention) *)
	      let stop_reason = ref "" in
	      let failed_task_ids : (string, unit) Hashtbl.t = Hashtbl.create 32 in
	      let failed_task_id_list () =
	        Hashtbl.fold (fun task_id () acc -> task_id :: acc) failed_task_ids []
	      in
	      let mark_failed task_id =
	        if task_id <> "" then Hashtbl.replace failed_task_ids task_id ()
	      in
	      let note_claim ~task_id =
	        with_walph_lock walph_state (fun () ->
	          walph_state.claimed <- walph_state.claimed + 1;
	          walph_state.last_task_id <- Some task_id
	        )
	      in
	      let note_success ~task_id =
	        with_walph_lock walph_state (fun () ->
	          walph_state.completed <- walph_state.completed + 1;
	          walph_state.consecutive_errors <- 0;
	          walph_state.last_task_id <- Some task_id
	        )
	      in
	      let note_error ?task_id err_msg =
	        with_walph_lock walph_state (fun () ->
	          walph_state.errors <- walph_state.errors + 1;
	          walph_state.consecutive_errors <- walph_state.consecutive_errors + 1;
	          walph_state.last_error <- Some err_msg;
	          walph_state.last_task_id <- task_id;
	          walph_state.consecutive_errors >= walph_state.max_consecutive_errors
	        )
	      in
	      let release_claim ~task_id =
	        match Room.transition_task_r config ~agent_name ~task_id ~action:"release" () with
	        | Ok _ ->
	            with_walph_lock walph_state (fun () ->
	              walph_state.released_on_error <- walph_state.released_on_error + 1
	            );
	            "ok"
	        | Error e ->
	            let release_err = Types.masc_error_to_string e in
	            Room.log_event config (Printf.sprintf
	              "{\"type\":\"walph_release_error\",\"agent\":\"%s\",\"task\":\"%s\",\"error\":%s,\"ts\":\"%s\"}"
	              agent_name task_id
	              (Yojson.Safe.to_string (`String release_err))
	              (Types.now_iso ()));
	            "error"
	      in
	      let log_loop_error ?task_id ~error ~release_status () =
	        Room.log_event config (Printf.sprintf
	          "{\"type\":\"walph_loop_error\",\"agent\":\"%s\",\"preset\":\"%s\",\"task\":%s,\"error\":%s,\"release\":\"%s\",\"ts\":\"%s\"}"
	          agent_name preset
	          (match task_id with Some tid -> Yojson.Safe.to_string (`String tid) | None -> "null")
	          (Yojson.Safe.to_string (`String error))
	          release_status
	          (Types.now_iso ()))
	      in
	      let maybe_backoff () =
	        if walph_state.error_backoff_sec > 0 then
	          Eio.Time.sleep clock (float_of_int walph_state.error_backoff_sec)
	      in

	      Common.protect ~module_name:"room_walph_eio" ~finally_label:"finalizer"
	        ~finally:(fun () ->
	          (* Always reset running state, even on exception *)
	          with_walph_lock walph_state (fun () ->
            walph_state.running <- false
          ))
        (fun () ->
          let _ = Room.broadcast config ~from_agent:agent_name
            ~content:(Printf.sprintf "🔄 @walph START %s%s (max: %d)"
              preset
              (match target with Some t -> " --target " ^ t | None -> "")
              max_iterations) in

	          (* Run the loop *)
	          let rec loop () =
	            (* Check control state before each iteration *)
	            if not (walph_should_continue config ~agent_name) then begin
	              stop_reason := if walph_state.stop_requested then "stop requested" else "paused indefinitely";
              ()
            end else begin
              (* Check max iterations with lock *)
              let should_stop = with_walph_lock walph_state (fun () ->
                if walph_state.iterations >= max_iterations then begin
                  stop_reason := Printf.sprintf "max_iterations reached (%d)" max_iterations;
                  true
                end else begin
                  walph_state.iterations <- walph_state.iterations + 1;
                  false
                end
	              ) in
	              if should_stop then ()
	              else begin
	                (* Try to claim next task *)
	                let claim_result =
	                  Room.claim_next_r config ~agent_name
	                    ~exclude_task_ids:(failed_task_id_list ()) ()
	                in
	                match claim_result with
	                | Room.Claim_next_no_unclaimed ->
	                    stop_reason := "backlog drained"
	                | Room.Claim_next_no_eligible _ ->
	                    stop_reason := "no eligible tasks (failed_this_run)"
	                | Room.Claim_next_error err_msg ->
	                    let cutoff = note_error err_msg in
	                    log_loop_error ~error:err_msg ~release_status:"n/a" ();
	                    let _ = Room.broadcast config ~from_agent:agent_name
	                      ~content:(Printf.sprintf "⚠️ @walph claim error: %s" err_msg) in
	                    if cutoff then
	                      stop_reason := Printf.sprintf "max_consecutive_errors reached (%d)" walph_state.max_consecutive_errors
	                    else begin
	                      maybe_backoff ();
	                      loop ()
	                    end
	                | Room.Claim_next_claimed { task_id; message = claim_message; title = task_title; _ } ->
	                    note_claim ~task_id;

	                    (* Execute chain if preset has one (not drain) *)
	                    let chain_id = get_chain_id_for_preset preset in
	                    let chain_result =
	                      match chain_id with
	                      | None ->
	                        (* Drain mode: no chain, just claim/done *)
	                        Ok "drain mode - no chain"
	                      | Some cid ->
	                        (* Build goal from task info and preset *)
	                        let task_desc =
	                          let tasks = Room.get_tasks_raw config in
	                          match List.find_opt (fun (t : Types.task) -> t.id = task_id) tasks with
	                          | Some t -> t.description
	                          | None -> ""
	                        in
	                        let goal = match preset with
	                          | "coverage" ->
	                              Printf.sprintf "Improve test coverage for: %s. %s. Add comprehensive tests with edge cases." task_title task_desc
	                          | "refactor" ->
	                              Printf.sprintf "Refactor the following: %s. %s. Improve code quality, reduce complexity, follow best practices." task_title task_desc
	                          | "docs" ->
	                              Printf.sprintf "Create or improve documentation for: %s. %s. Include examples and clear explanations." task_title task_desc
	                          | "review" ->
	                              Printf.sprintf "Review PR: %s. %s. Check code quality, security, test coverage." task_title task_desc
	                          | "figma" ->
	                              if String.length (String.trim task_desc) > 0 then task_desc
	                              else
	                                Printf.sprintf
	                                  "Vision-first Figma task: %s. Provide figma_dsl JSON in the task description."
	                                  task_title
	                          | _ ->
	                              Printf.sprintf "Complete this task: %s. %s" task_title task_desc
	                        in
	                        let _ = Room.broadcast config ~from_agent:agent_name
	                          ~content:(Printf.sprintf "🔗 @walph executing '%s' for '%s'..." cid task_title) in
	                        (* Direct LLM call — no legacy compat dependency *)
	                        try
	                          let response = llm_dispatch
	                            ~tool_name:"glm"
	                            ~model:Env_config.Llm.default_model
	                            ~prompt:goal
	                            ~timeout_sec:60
	                            ~max_chars:4000
	                            ()
	                          in
	                          if response = "" then Error "Empty LLM response"
	                          else Ok response
	                        with exn -> Error (Printexc.to_string exn)
	                    in

	                    (match chain_result with
	                     | Ok result ->
	                         let notes_str =
	                           Printf.sprintf "LLM result: %s"
	                             (String.sub result 0 (min 100 (String.length result)))
	                         in
	                         (match Room.transition_task_r config ~agent_name ~task_id ~action:"done" ~notes:notes_str () with
	                          | Ok _ ->
	                              note_success ~task_id;
	                              Room.log_event config (Printf.sprintf
	                                "{\"type\":\"walph_task_done\",\"agent\":\"%s\",\"task\":\"%s\",\"preset\":\"%s\",\"ts\":\"%s\"}"
	                                agent_name task_id preset (Types.now_iso ()));
	                              let _ = Room.broadcast config ~from_agent:agent_name
	                                ~content:(Printf.sprintf "📊 @walph Iteration %d: %s ✅" walph_state.iterations claim_message) in
	                              loop ()
	                          | Error err ->
	                              let err_msg = Types.masc_error_to_string err in
	                              mark_failed task_id;
	                              let release_status = release_claim ~task_id in
	                              let cutoff = note_error ~task_id err_msg in
	                              log_loop_error ~task_id ~error:err_msg ~release_status ();
	                              let _ = Room.broadcast config ~from_agent:agent_name
	                                ~content:(Printf.sprintf "⚠️ @walph done error on %s: %s (released)" task_id err_msg) in
	                              if cutoff then
	                                stop_reason := Printf.sprintf "max_consecutive_errors reached (%d)" walph_state.max_consecutive_errors
	                              else begin
	                                maybe_backoff ();
	                                loop ()
	                              end)
	                     | Error err_msg ->
	                         mark_failed task_id;
	                         let release_status = release_claim ~task_id in
	                         let cutoff = note_error ~task_id err_msg in
	                         log_loop_error ~task_id ~error:err_msg ~release_status ();
	                         let _ = Room.broadcast config ~from_agent:agent_name
	                           ~content:(Printf.sprintf "⚠️ @walph chain error on %s: %s (released)" task_id err_msg) in
	                         if cutoff then
	                           stop_reason := Printf.sprintf "max_consecutive_errors reached (%d)" walph_state.max_consecutive_errors
	                         else begin
	                           maybe_backoff ();
	                           loop ()
	                         end)
	              end
	            end
	          in

	          loop ();
	          with_walph_lock walph_state (fun () ->
	            walph_state.last_stop_reason <- Some !stop_reason
	          );

	          (* Final broadcast and log *)
	          let result = Printf.sprintf
	            "🛑 @walph STOPPED. Preset: %s, Iterations: %d, Tasks completed: %d, Reason: %s"
            preset walph_state.iterations walph_state.completed !stop_reason in

          let _ = Room.broadcast config ~from_agent:agent_name ~content:result in

          Room.log_event config (Printf.sprintf
            "{\"type\":\"walph_loop_complete\",\"agent\":\"%s\",\"preset\":\"%s\",\"iterations\":%d,\"completed\":%d,\"reason\":\"%s\",\"ts\":\"%s\"}"
            agent_name preset walph_state.iterations walph_state.completed !stop_reason (Types.now_iso ()));

          result
        )

(** {1 Swarm Walph - Multi-Agent Coordination} *)

(** Swarm status summary for all active Walph instances in a room *)
type swarm_status = {
  total_agents: int;
  running_count: int;
  paused_count: int;
  completed_tasks: int;
  total_iterations: int;
  agents: (string * walph_state) list;
}

(** Get comprehensive swarm status across all Walph instances
    @param config Room configuration
    @return Swarm status summary *)
let swarm_walph_status config =
  let agents = list_walph_states config in
  let running = List.filter (fun (_, s) -> s.running) agents in
  let paused = List.filter (fun (_, s) -> s.paused) agents in
  let total_completed = List.fold_left (fun acc (_, s) -> acc + s.completed) 0 agents in
  let total_iters = List.fold_left (fun acc (_, s) -> acc + s.iterations) 0 agents in
  {
    total_agents = List.length agents;
    running_count = List.length running;
    paused_count = List.length paused;
    completed_tasks = total_completed;
    total_iterations = total_iters;
    agents;
  }

(** Format swarm status for display *)
let format_swarm_status status =
  let agent_lines = List.map (fun (name, s) ->
    Printf.sprintf "  • %s: %s (iter: %d, done: %d)%s"
      name
      (if s.running then (if s.paused then "⏸️ PAUSED" else "🔄 RUNNING") else "⚪ IDLE")
      s.iterations s.completed
      (if s.running then " [" ^ s.current_preset ^ "]" else "")
  ) status.agents in
  Printf.sprintf
    "🐝 **Swarm Walph Status**\n\
     ├─ Agents: %d total, %d running, %d paused\n\
     ├─ Tasks completed: %d\n\
     ├─ Total iterations: %d\n\
     └─ Details:\n%s"
    status.total_agents status.running_count status.paused_count
    status.completed_tasks status.total_iterations
    (if agent_lines = [] then "  (no agents)" else String.concat "\n" agent_lines)

(** Stop all running Walph instances in a swarm
    @param config Room configuration
    @param from_agent Agent issuing the stop command
    @return Summary of stopped instances *)
let swarm_walph_stop config ~from_agent =
  let agents = list_walph_states config in
  let running_agents = List.filter (fun (_, s) -> s.running) agents in

  if running_agents = [] then
    "ℹ️ No running Walph instances to stop"
  else begin
    let stopped = List.map (fun (agent_name, state) ->
      with_walph_lock state (fun () ->
        if state.running then begin
          state.stop_requested <- true;
          Eio.Condition.broadcast state.cond;
          agent_name
        end else ""
      )
    ) running_agents in

    let stopped_list = List.filter ((<>) "") stopped in
    let _ = Room.broadcast config ~from_agent:"walph-swarm"
      ~content:(Printf.sprintf "🛑 SWARM STOP by %s: %d agents signaled" from_agent (List.length stopped_list)) in

    Printf.sprintf "🛑 Swarm stop requested for %d agents: %s"
      (List.length stopped_list)
      (String.concat ", " stopped_list)
  end

(** Pause all running Walph instances in a swarm
    @param config Room configuration
    @param from_agent Agent issuing the pause command
    @return Summary of paused instances *)
let swarm_walph_pause config ~from_agent =
  let agents = list_walph_states config in
  let running_agents = List.filter (fun (_, s) -> s.running && not s.paused) agents in

  if running_agents = [] then
    "ℹ️ No running (un-paused) Walph instances to pause"
  else begin
    let paused = List.map (fun (agent_name, state) ->
      with_walph_lock state (fun () ->
        if state.running && not state.paused then begin
          state.paused <- true;
          agent_name
        end else ""
      )
    ) running_agents in

    let paused_list = List.filter ((<>) "") paused in
    let _ = Room.broadcast config ~from_agent:"walph-swarm"
      ~content:(Printf.sprintf "⏸️ SWARM PAUSE by %s: %d agents paused" from_agent (List.length paused_list)) in

    Printf.sprintf "⏸️ Swarm pause applied to %d agents: %s"
      (List.length paused_list)
      (String.concat ", " paused_list)
  end

(** Resume all paused Walph instances in a swarm
    @param config Room configuration
    @param from_agent Agent issuing the resume command
    @return Summary of resumed instances *)
let swarm_walph_resume config ~from_agent =
  let agents = list_walph_states config in
  let paused_agents = List.filter (fun (_, s) -> s.paused) agents in

  if paused_agents = [] then
    "ℹ️ No paused Walph instances to resume"
  else begin
    let resumed = List.map (fun (agent_name, state) ->
      with_walph_lock state (fun () ->
        if state.paused then begin
          state.paused <- false;
          Eio.Condition.broadcast state.cond;
          agent_name
        end else ""
      )
    ) paused_agents in

    let resumed_list = List.filter ((<>) "") resumed in
    let _ = Room.broadcast config ~from_agent:"walph-swarm"
      ~content:(Printf.sprintf "▶️ SWARM RESUME by %s: %d agents resumed" from_agent (List.length resumed_list)) in

    Printf.sprintf "▶️ Swarm resume applied to %d agents: %s"
      (List.length resumed_list)
      (String.concat ", " resumed_list)
  end

(** Command pattern for swarm control *)
let swarm_walph_control config ~from_agent ~command () =
  match String.uppercase_ascii command with
  | "STATUS" ->
      let status = swarm_walph_status config in
      let formatted = format_swarm_status status in
      let _ = Room.broadcast config ~from_agent:"walph-swarm" ~content:formatted in
      formatted
  | "STOP" ->
      swarm_walph_stop config ~from_agent
  | "PAUSE" ->
      swarm_walph_pause config ~from_agent
  | "RESUME" ->
      swarm_walph_resume config ~from_agent
  | cmd ->
      Printf.sprintf "❓ Unknown swarm command: %s. Valid: STATUS, STOP, PAUSE, RESUME" cmd
