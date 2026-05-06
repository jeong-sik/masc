(** Shutdown Hooks - Centralized graceful shutdown management

    Provides a registry for cleanup functions that should be called
    during graceful shutdown.

    @since 0.5.0
*)

(** Registered cancel function for orchestrator — WORM Atomic. *)
let cancel_orchestrator_ref : (unit -> unit) option Atomic.t = Atomic.make None

(** Register the orchestrator cancel function *)
let register_cancel_orchestrator (f : unit -> unit) =
  Atomic.set cancel_orchestrator_ref (Some f)

(** Call all registered shutdown hooks with per-hook timing. *)
let run_all () =
  let t0 = Unix.gettimeofday () in
  (* Cancel orchestrator first *)
  (match Atomic.get cancel_orchestrator_ref with
   | Some cancel ->
     let t_start = Unix.gettimeofday () in
     Log.Server.info "Cancelling orchestrator...";
     cancel ();
     Log.Server.info "[Shutdown] orchestrator cancelled (%.2fs)"
       (Unix.gettimeofday () -. t_start)
   | None ->
     Log.Server.info "[Shutdown] no orchestrator registered, skipping");
  (* Close all SSE clients *)
  let t_sse = Unix.gettimeofday () in
  let sse_count = Sse.close_all_clients () in
  Log.Server.info "Closed %d SSE clients (%.2fs) [remaining conn: %d]"
    sse_count (Unix.gettimeofday () -. t_sse)
    (Server_mcp_transport_http_sse.active_session_count ());
  (* Close WebSocket sessions *)
  let t_ws = Unix.gettimeofday () in
  let ws_count = Server_mcp_transport_ws.close_all () in
  Log.Server.info "Closed %d WebSocket sessions (%.2fs) [remaining ws: %d]"
    ws_count (Unix.gettimeofday () -. t_ws)
    (Server_mcp_transport_ws.session_count ());
  (* Flush metric/stress buffers to prevent data loss *)
  (try Heuristic_metrics.flush ()
   with Eio.Cancel.Cancelled _ as e ->
     let bt = Printexc.get_raw_backtrace () in
     Printexc.raise_with_backtrace e bt
      | _ -> Log.Server.warn "[Shutdown] heuristic_metrics flush failed");
  (try Agent_stress.flush ()
   with Eio.Cancel.Cancelled _ as e ->
     let bt = Printexc.get_raw_backtrace () in
     Printexc.raise_with_backtrace e bt
      | _ -> Log.Server.warn "[Shutdown] agent_stress flush failed");
  (* Clear transient A2A state to free memory *)
  (* Clear session identity caches *)
  Agent_registry_eio.clear_session_caches ();
  (* Best-effort cleanup of transient files under <base>/.masc/tmp/.
     Durable JSONL state and lock files outside of the tmp/ directory are
     never touched. Dir missing or symlinked → noop. Per-file errors are
     logged and ignored so a single permission error cannot block the rest
     of shutdown. Cleanup is explicitly bounded because this hook runs in a
     synchronous shutdown path that Eio timeouts cannot preempt. *)
  let t_tmp = Unix.gettimeofday () in
  let tmp_cleanup_file_budget = 500 in
  let tmp_cleanup_wall_budget_s = 0.25 in
  let inspected = ref 0 in
  let removed = ref 0 in
  let bytes_freed = ref 0 in
  let budget_exhausted = ref false in
  let tmp_budget_exceeded () =
    !inspected >= tmp_cleanup_file_budget
    || Unix.gettimeofday () -. t_tmp >= tmp_cleanup_wall_budget_s
  in
  let cleanup_dir dir =
    (* Stream entries via [Unix.opendir]/[readdir] instead of
       [Sys.readdir], which materializes the whole directory into an
       OCaml array up-front. A [.masc/tmp] with millions of files would
       otherwise allocate a million-string array even when the loop
       trips the file/wall budget after the first 500 entries. *)
    match Unix.opendir dir with
    | exception Unix.Unix_error _ -> ()
    | dh ->
      let stop = ref false in
      let count_after_budget = ref 0 in
      Fun.protect
        ~finally:(fun () -> try Unix.closedir dh with _ -> ())
        (fun () ->
          while not !stop do
            match Unix.readdir dh with
            | exception End_of_file -> stop := true
            | name when name = "." || name = ".." -> ()
            | _ when tmp_budget_exceeded () ->
              budget_exhausted := true;
              incr count_after_budget;
              stop := true
            | name ->
              incr inspected;
              let path = Filename.concat dir name in
              (match Unix.lstat path with
               | exception Unix.Unix_error (e, _, _) ->
                 Log.Server.debug "[Shutdown] tmp lstat skipped %s: %s"
                   path (Unix.error_message e)
               | st when st.Unix.st_kind = Unix.S_REG ->
                 (try
                    Unix.unlink path;
                    incr removed;
                    bytes_freed := !bytes_freed + st.Unix.st_size
                  with Unix.Unix_error (e, _, _) ->
                    Log.Server.warn "[Shutdown] tmp unlink failed %s: %s"
                      path (Unix.error_message e))
               | _ -> () (* skip dirs / symlinks / fifos *))
          done);
      ignore count_after_budget
  in
  (* Treat empty/whitespace-only [MASC_BASE_PATH] as unset. The repo
     convention sets env vars to "" via [Unix.putenv name ""] when
     "unset" is the intended semantic (see test_board_vote_quarantine
     comment), and a non-trimmed empty string here would resolve
     [tmp_dir] to ".masc/tmp" relative to the cwd and start unlinking
     unrelated files. *)
  (match Sys.getenv_opt "MASC_BASE_PATH" |> Option.map String.trim with
   | None | Some "" -> ()
   | Some base_path ->
     let tmp_dir = Filename.concat base_path ".masc/tmp" in
     (match Unix.lstat tmp_dir with
      | exception Unix.Unix_error _ -> ()
      | st when st.Unix.st_kind = Unix.S_DIR -> cleanup_dir tmp_dir
      | _ ->
        Log.Server.debug
          "[Shutdown] tmp cleanup skipped non-directory path %s" tmp_dir));
  if !budget_exhausted then
    Log.Server.warn
      "[Shutdown] basepath tmp cleanup budget reached (inspected=%d, max_files=%d, budget=%.0fms)"
      !inspected tmp_cleanup_file_budget (tmp_cleanup_wall_budget_s *. 1000.);
  if !removed > 0 then
    Log.Server.info
      "[Shutdown] basepath tmp: inspected %d, removed %d files (%d bytes, %.2fs)"
      !inspected !removed !bytes_freed (Unix.gettimeofday () -. t_tmp);
  Log.Server.info "[Shutdown] hooks total: %.2fs"
    (Unix.gettimeofday () -. t0)
