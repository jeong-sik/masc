(** Room_walph -- Walph control system (sync implementation).

    Thread-safe state machine for iterative task processing.

    @see Room_walph_eio for the Eio-native async variant.
    @see Room_task for claim/transition primitives used here. *)

open Types
include Room_utils
include Room_state

(* ======== Walph Control System ======== *)

(** Walph loop state *)
(** Walph state machine for iterative task processing
    Thread-safe implementation using stdlib Mutex for production use.

    Design notes:
    - Uses Mutex for thread-safe state access (stdlib, not Eio)
    - Condition variable for pause/resume (no busy-wait)
    - Fun.protect for exception safety (no zombie states)
    - Atomic check-and-set pattern to prevent double-start race
*)
type walph_state = {
  mutable running : bool;
  mutable paused : bool;
  mutable stop_requested : bool;
  mutable current_preset : string;
  mutable iterations : int;
  mutable completed : int;
  mutex : Eio.Mutex.t;
  cond : Eio.Condition.t;
}

let walph_states : (string, walph_state) Hashtbl.t = Hashtbl.create 16
let walph_states_mutex = Eio.Mutex.create ()

let get_walph_state config =
  let key = config.base_path in
  Eio.Mutex.use_rw ~protect:true walph_states_mutex (fun () ->
    match Hashtbl.find_opt walph_states key with
    | Some s -> s
    | None ->
        let s = {
          running = false; paused = false; stop_requested = false;
          current_preset = ""; iterations = 0; completed = 0;
          mutex = Eio.Mutex.create ();
          cond = Eio.Condition.create ();
        } in
        Hashtbl.replace walph_states key s;
        s
  )

let remove_walph_state config =
  let key = config.base_path in
  Eio.Mutex.use_rw ~protect:true walph_states_mutex (fun () ->
    Hashtbl.remove walph_states key
  )

let with_walph_lock state f =
  Eio.Mutex.use_rw ~protect:true state.mutex f

(** Parse @walph command from broadcast message
    Returns: (command, args) or None if not a walph command *)
let parse_walph_command content =
  (* Match @walph COMMAND [args] pattern *)
  if not (try ignore (Str.search_forward (Str.regexp_case_fold "@walph") content 0); true
          with Not_found -> false) then
    None
  else begin
    (* Extract command after @walph *)
    (* Match @walph followed by command word (any non-whitespace, excluding newlines) *)
    let re = Str.regexp_case_fold "@walph[ \t]+\\([^ \t\n\r]+\\)\\(.*\\)" in
    if Str.string_match re content 0 then
      let cmd = String.uppercase_ascii (Str.matched_group 1 content) in
      let args = String.trim (try Str.matched_group 2 content with Not_found -> "") in
      Some (cmd, args)
    (* Only bare @walph (nothing after except optional whitespace) = STATUS *)
    else if Str.string_match (Str.regexp_case_fold "@walph[ \t]*$") content 0 then
      Some ("STATUS", "")
    else
      None
  end

(** Handle @walph control command (thread-safe)
    @param config Room configuration
    @param from_agent Agent sending the command
    @param command Command (STOP, PAUSE, RESUME, STATUS)
    @param args Command arguments
    @return Response message *)
let walph_control config ~from_agent ~command ~args =
  let state = get_walph_state config in
  let response = with_walph_lock state (fun () ->
    match command with
    | "STOP" ->
        if state.running then begin
          state.stop_requested <- true;
          Eio.Condition.broadcast state.cond;  (* Wake up pause wait *)
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
          Eio.Condition.broadcast state.cond;  (* Wake up pause wait *)
          Printf.sprintf "▶️ @walph RESUMED by %s" from_agent
        end else if state.running then
          "ℹ️ @walph is already running"
        else
          "ℹ️ @walph is not currently running"
    | "STATUS" ->
        if state.running then
          Printf.sprintf "📊 @walph STATUS: %s (iter: %d, done: %d, paused: %b)"
            state.current_preset state.iterations state.completed state.paused
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
  let _ = broadcast config ~from_agent:"walph" ~content:response in
  response

(** Check if Walph should continue looping (thread-safe, no busy-wait)
    Uses Condition.wait for proper pause synchronization.
    @return true if should continue, false if should stop *)
let walph_should_continue config =
  let state = get_walph_state config in
  with_walph_lock state (fun () ->
    if state.stop_requested then false
    else if state.paused then begin
      (* Wait on condition variable - no busy-wait! *)
      (* Condition.wait atomically releases mutex and waits *)
      while state.paused && not state.stop_requested do
        Eio.Condition.await state.cond state.mutex
      done;
      not state.stop_requested
    end else true
  )

(** Map Walph preset to task type (native-only)
    @param preset The loop preset (coverage, refactor, docs, review, figma, drain)
    @return Some chain_id for presets with corresponding chains, None for drain *)
let get_chain_id_for_preset = function
  | "coverage" -> Some "walph-coverage"
  | "refactor" -> Some "walph-refactor"
  | "docs" -> Some "walph-docs"
  | "review" -> Some "pr-review-pipeline"  (* PR self-review *)
  | "figma" -> Some "walph-figma"  (* Vision-first Figma loop *)
  | "drain" -> None  (* No chain for simple drain *)
  | _ -> None

(** Walph pattern: Keep claiming tasks until stop condition
    Thread-safe with atomic check-and-set and exception safety.

    @param preset Loop preset (drain, coverage, refactor, docs)
    @param max_iterations Maximum iterations before forced stop
    @param target Target file/directory for preset
    @return Status string with loop results *)
let walph_loop config ~agent_name ?(preset="drain") ?(max_iterations=10) ?target () =
  ensure_initialized config;

  (* Get Walph state *)
  let walph_state = get_walph_state config in

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
      Ok ()
    end
  ) in

  match start_result with
  | Error msg ->
      let _ = broadcast config ~from_agent:"walph" ~content:msg in
      msg
  | Ok () ->
      (* Use Fun.protect to ensure running <- false even on exceptions (zombie prevention) *)
      let stop_reason = ref "" in

      Common.protect ~module_name:"room" ~finally_label:"finalizer"
        ~finally:(fun () ->
          (* Always reset running state, even on exception *)
          with_walph_lock walph_state (fun () ->
            walph_state.running <- false
          ))
        (fun () ->
          let _ = broadcast config ~from_agent:agent_name
            ~content:(Printf.sprintf "🔄 @walph START %s%s (max: %d)"
              preset
              (match target with Some t -> " --target " ^ t | None -> "")
              max_iterations) in

	          let failed_task_ids : (string, unit) Hashtbl.t = Hashtbl.create 16 in
	          let failed_task_id_list () =
	            Hashtbl.fold (fun task_id () acc -> task_id :: acc) failed_task_ids []
	          in
	          let mark_failed task_id =
	            Hashtbl.replace failed_task_ids task_id ()
	          in
	          let release_on_error ~task_id ~error =
	            let release_result =
	              Room_task.transition_task_r config ~agent_name ~task_id ~action:"release" ()
	            in
	            let release_status =
	              match release_result with
	              | Ok _ -> "ok"
	              | Error e ->
	                  Log.Misc.error "walph release failed: %s"
	                    (Types.masc_error_to_string e);
	                  "error"
	            in
	            log_event config
	              (Printf.sprintf
	                 "{\"type\":\"walph_task_released\",\"agent\":\"%s\",\"task\":\"%s\",\"error\":%s,\"release\":\"%s\",\"ts\":\"%s\"}"
	                 agent_name task_id
	                 (Yojson.Safe.to_string (`String error))
	                 release_status
	                 (now_iso ()))
	          in

	          (* Run the loop *)
	          let rec loop () =
	            (* Check control state before each iteration *)
	            if not (walph_should_continue config) then begin
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
	                  Room_task.claim_next_r config ~agent_name
	                    ~exclude_task_ids:(failed_task_id_list ()) ()
	                in
	                match claim_result with
	                | Room_task.Claim_next_no_unclaimed ->
	                    stop_reason := "backlog drained"
	                | Room_task.Claim_next_no_eligible _ ->
	                    stop_reason := "no eligible tasks (failed_this_run)"
	                | Room_task.Claim_next_error err ->
	                    stop_reason := Printf.sprintf "claim error: %s" err
	                | Room_task.Claim_next_claimed { task_id; message = claim_message; _ } ->
	                    if preset = "drain" then begin
	                      let done_result =
	                        Room_task.transition_task_r config ~agent_name ~task_id ~action:"done"
	                          ~notes:"walph drain mode auto-complete" ()
	                      in
	                      match done_result with
	                      | Ok _ ->
	                          with_walph_lock walph_state (fun () ->
	                            walph_state.completed <- walph_state.completed + 1
	                          );
	                          log_event config
	                            (Printf.sprintf
	                               "{\"type\":\"walph_task_done\",\"agent\":\"%s\",\"task\":\"%s\",\"preset\":\"%s\",\"ts\":\"%s\"}"
	                               agent_name task_id preset (now_iso ()));
	                          let _ = broadcast config ~from_agent:agent_name
	                            ~content:(Printf.sprintf "📊 @walph Iteration %d: %s ✅" walph_state.iterations claim_message) in
	                          loop ()
	                      | Error err ->
	                          let err_msg = Types.masc_error_to_string err in
	                          mark_failed task_id;
	                          release_on_error ~task_id ~error:err_msg;
	                          let _ = broadcast config ~from_agent:agent_name
	                            ~content:(Printf.sprintf "⚠️ @walph done error on %s: %s (released)" task_id err_msg) in
	                          loop ()
	                    end else begin
	                      (* Sync walph does not execute MODEL chains; release safely instead of leaving claim stuck. *)
	                      let err_msg =
	                        Printf.sprintf "preset %s requires eio walph runner" preset
	                      in
	                      mark_failed task_id;
	                      release_on_error ~task_id ~error:err_msg;
	                      let _ = broadcast config ~from_agent:agent_name
	                        ~content:(Printf.sprintf "⚠️ @walph unsupported preset in sync loop for %s: %s (released)" task_id err_msg) in
	                      loop ()
	                    end
	              end
	            end
	          in

          loop ();

          (* Final broadcast and log *)
          let result = Printf.sprintf
            "🛑 @walph STOPPED. Preset: %s, Iterations: %d, Tasks completed: %d, Reason: %s"
            preset walph_state.iterations walph_state.completed !stop_reason in

          let _ = broadcast config ~from_agent:agent_name ~content:result in

          log_event config (Printf.sprintf
            "{\"type\":\"walph_loop_complete\",\"agent\":\"%s\",\"preset\":\"%s\",\"iterations\":%d,\"completed\":%d,\"reason\":\"%s\",\"ts\":\"%s\"}"
            agent_name preset walph_state.iterations walph_state.completed !stop_reason (now_iso ()));

          result
        )
