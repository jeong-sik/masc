type failure =
  | Raised of string
  | Died of Unix.process_status
  | Never_ran

let signal_name signal =
  if signal = Sys.sigkill then "SIGKILL"
  else if signal = Sys.sigterm then "SIGTERM"
  else if signal = Sys.sigint then "SIGINT"
  else if signal = Sys.sigsegv then "SIGSEGV"
  else if signal = Sys.sigabrt then "SIGABRT"
  else if signal = Sys.sigbus then "SIGBUS"
  else Printf.sprintf "signal %d" signal

let failure_to_string = function
  | Raised detail -> detail
  | Died (Unix.WEXITED code) ->
    Printf.sprintf "the process exited with status %d without a result" code
  | Died (Unix.WSIGNALED signal) ->
    Printf.sprintf "the process was ended by %s without a result" (signal_name signal)
  | Died (Unix.WSTOPPED signal) ->
    Printf.sprintf "the process was stopped by %s without a result" (signal_name signal)
  | Never_ran -> "no result was recorded for the job"

(* How long the caller sleeps between looks at its children. A scan takes
   seconds to minutes, so this is far below anything the caller can notice. *)
let poll_interval_s = 0.02

let run_job thunk =
  match thunk () with
  | value -> Ok value
  | exception exn -> Error (Raised (Printexc.to_string exn))

(* What a child leaves behind is one file, written under another name and moved
   into place when complete, so a child that dies while writing leaves nothing
   a reader could mistake for a result. *)
let read_result path status =
  match open_in_bin path with
  | exception Sys_error _ -> Error (Died status)
  | channel ->
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () ->
         match (Marshal.from_channel channel : ('a, failure) result) with
         | result -> result
         | exception End_of_file -> Error (Died status)
         | exception Failure _ -> Error (Died status))

(* Ends the child without returning into the caller's code or running the
   at-exit handlers it inherited. *)
let run_child ~path thunk =
  let exit_code =
    match
      let result = run_job thunk in
      let partial = path ^ ".partial" in
      let channel = open_out_bin partial in
      Marshal.to_channel channel result [];
      close_out channel;
      Unix.rename partial path
    with
    | () -> 0
    | exception _ -> 1
  in
  Unix._exit exit_code

let remove_directory directory =
  (match Sys.readdir directory with
   | names ->
     Array.iter
       (fun name ->
          try Sys.remove (Filename.concat directory name) with
          | Sys_error _ -> ())
       names
   | exception Sys_error _ -> ());
  try Unix.rmdir directory with
  | Unix.Unix_error _ -> ()

let kill_and_reap pid =
  (try Unix.kill pid Sys.sigkill with
   | Unix.Unix_error _ -> ());
  try ignore (Unix.waitpid [] pid) with
  | Unix.Unix_error _ -> ()

let interrupting_signals = [ Sys.sigint; Sys.sigterm ]

let map ~jobs ?(on_start = fun _ -> ()) ?(on_result = fun _ _ -> ()) thunks =
  let thunks = Array.of_list thunks in
  let count = Array.length thunks in
  let results = Array.make count None in
  let delivered = ref 0 in
  let rec deliver () =
    if !delivered < count then
      match results.(!delivered) with
      | None -> ()
      | Some result ->
        on_result !delivered result;
        incr delivered;
        deliver ()
  in
  let run_here () =
    Array.iteri
      (fun index thunk ->
         on_start index;
         results.(index) <- Some (run_job thunk);
         deliver ())
      thunks
  in
  let run_in_processes directory =
    let path index = Filename.concat directory (string_of_int index) in
    let running = ref [] in
    let next = ref 0 in
    let cleanup () =
      List.iter (fun (pid, _) -> kill_and_reap pid) !running;
      running := [];
      remove_directory directory
    in
    let ended_by signal =
      cleanup ();
      Sys.set_signal signal Sys.Signal_default;
      Unix.kill (Unix.getpid ()) signal
    in
    let previous =
      List.map
        (fun signal -> signal, Sys.signal signal (Sys.Signal_handle ended_by))
        interrupting_signals
    in
    let restore_signals () =
      List.iter (fun (signal, behavior) -> Sys.set_signal signal behavior) previous
    in
    (* A signal that lands between the fork and the child resetting its
       handlers would run the caller's handler in the child. *)
    let launch index =
      on_start index;
      flush_all ();
      let mask = Unix.sigprocmask Unix.SIG_BLOCK interrupting_signals in
      match Unix.fork () with
      | 0 ->
        List.iter (fun signal -> Sys.set_signal signal Sys.Signal_default) interrupting_signals;
        ignore (Unix.sigprocmask Unix.SIG_SETMASK mask);
        run_child ~path:(path index) thunks.(index)
      | pid ->
        ignore (Unix.sigprocmask Unix.SIG_SETMASK mask);
        running := (pid, index) :: !running
      | exception exn ->
        ignore (Unix.sigprocmask Unix.SIG_SETMASK mask);
        results.(index) <-
          Some (Error (Raised ("fork failed: " ^ Printexc.to_string exn)))
    in
    let ended_status pid =
      match Unix.waitpid [ Unix.WNOHANG ] pid with
      | 0, _ -> None
      | _, status -> Some status
      | exception Unix.Unix_error (error, _, _) ->
        if error = Unix.EINTR then None else Some (Unix.WEXITED 255)
    in
    (* True when a child ended. *)
    let reap () =
      let ended, alive =
        List.partition_map
          (fun (pid, index) ->
             match ended_status pid with
             | None -> Either.Right (pid, index)
             | Some status -> Either.Left (index, status))
          !running
      in
      running := alive;
      List.iter
        (fun (index, status) -> results.(index) <- Some (read_result (path index) status))
        ended;
      ended <> []
    in
    let fill () =
      while !next < count && List.length !running < jobs do
        let index = !next in
        incr next;
        launch index
      done
    in
    Fun.protect
      ~finally:(fun () ->
        restore_signals ();
        cleanup ())
      (fun () ->
         fill ();
         deliver ();
         while !running <> [] do
           if not (reap ()) then Unix.sleepf poll_interval_s;
           deliver ();
           fill ()
         done;
         deliver ())
  in
  (if jobs <= 1 || count <= 1 then run_here ()
   else
     match Filename.temp_dir "forked-map-" "" with
     | directory -> run_in_processes directory
     | exception Sys_error detail ->
       (* No child could hand a result back, so no job runs. Each one says why,
          and the caller can still run them with [jobs = 1]. *)
       Array.iteri
         (fun index _ ->
            results.(index) <-
              Some (Error (Raised ("cannot create the directory for results: " ^ detail))))
         thunks;
       deliver ());
  Array.to_list
    (Array.map
       (function
         | Some result -> result
         | None -> Error Never_ran)
       results)
