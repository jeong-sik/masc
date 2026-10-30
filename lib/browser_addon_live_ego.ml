module B = Browser_lane
module Peer = Browser_ego_peer
module Live = Browser_live_peer
open Result.Syntax

let arguments (configuration : Browser_configuration.live_ego) =
  ["--live-ego-command";configuration.command] @ match configuration.space with
  | Browser_configuration.Named_space name -> ["--live-ego-space";name]
  | Existing_space id -> ["--live-ego-space-id";string_of_int id]

(* A stopped run gets TERM, then KILL after this long, with its process
   group. The foreground manager waits this long even when the run ends at
   once, so stopping a run costs it. *)
let stop_grace_s = 2.
(* ego-browser --version answers without starting the browser. *)
let version_timeout_s = 10.
let read_chunk_bytes = 65_536

let run_command ~env ~timeout_s ~stdin ~command arguments =
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run (fun sw ->
    let manager = Posix_spawn_process_mgr.foreground_mgr ~clock ~grace_seconds:stop_grace_s in
    let input_read, input_write = Eio_unix.pipe sw in
    let output_read, output_write = Eio_unix.pipe sw in
    match Eio.Process.spawn ~sw manager ~stdin:input_read ~stdout:output_write ~stderr:output_write
            (command :: arguments) with
    | exception (Eio.Io _ as exn) -> Error (Peer.Unstarted (Printexc.to_string exn))
    | exception Unix.Unix_error (code, _, _) -> Error (Peer.Unstarted (Unix.error_message code))
    | process ->
      Eio.Flow.close input_read; Eio.Flow.close output_write;
      let output = Buffer.create read_chunk_bytes and chunk = Cstruct.create read_chunk_bytes in
      let rec drain () = match Eio.Flow.single_read output_read chunk with
        | read when Buffer.length output + read > Peer.output_limit_bytes -> `Exceeded
        | read -> Buffer.add_string output (Cstruct.to_string ~len:read chunk); drain ()
        | exception End_of_file -> `Drained in
      (* A run that exits before it read its whole script is answered by
         its exit status. Once the script is written the output decides, so
         a run past the output limit is stopped even while it does not read. *)
      let feed () =
        (try Eio.Flow.copy_string stdin input_write with Eio.Io _ -> ());
        Eio.Flow.close input_write;
        Eio.Fiber.await_cancel () in
      (* Leaving the switch stops a run that is still going, with its group. *)
      match Eio.Time.with_timeout clock timeout_s (fun () ->
        Eio.Fiber.first feed (fun () -> match drain () with
          | `Exceeded -> Ok None
          | `Drained -> Ok (Some (Eio.Process.await process)))) with
      | exception (Eio.Io _ | Unix.Unix_error _ as exn) -> Error (Peer.Unobserved (Printexc.to_string exn))
      | Error `Timeout -> Error Peer.Timed_out
      | Ok None -> Error Peer.Output_exceeded
      | Ok (Some (`Exited 0)) -> Ok (Buffer.contents output)
      | Ok (Some (`Exited code)) -> Error (Peer.Exited {code; output = Buffer.contents output})
      | Ok (Some (`Signaled signal)) -> Error (Peer.Signaled signal))

(* One ego-browser nodejs process serves every command of a connection.
   ego's SDK keeps a page's dialog and event state in the process, and a
   page blocked on a dialog is not readable from a different SDK process.
   Installed .20 reproduces that asymmetry even while the opener stays alive;
   see docs/evidence/ego-native-session-gap/. The SDK's own dialog requirement
   documents the process-local state. ego hands
   back a process's own output only once it exits, and its console.log is
   read-only, so the process connects back to a Unix socket in the
   connection's private directory, runs each script it receives as an async
   function whose console keeps the lines it writes, and answers them over
   the socket. A command that does not answer within its window, writes past
   the output limit or is cancelled stops the process with its group, as a
   one-run command was stopped; the next command starts another. *)
(* sun_path is 104 bytes on macOS, NUL included; Linux allows 108. The
   directory is the system's temporary one, 49 bytes on macOS, so the name
   is one byte. *)
let socket_name = "s"
let socket_path_limit_bytes = 103

(* The owner socket is also the SDK process's lifetime authority. A worker
   can disappear while an async SDK call is pending, before the surrounding
   process manager gets to kill its separate foreground group. Merely waking
   the receive loop neither interrupts that call nor drops buffered scripts.
   On owner loss exit this Node session, without finishing a task space or
   closing Ego's user browser. Already dispatched effects remain unknown.
   Socket events require a responsive Node event loop; this is not a promise
   to interrupt arbitrary synchronous CPU work. *)
let session_loop ~socket = String.concat "\n" [
  "const net = await import(\"node:net\");";
  "const AsyncFunction = (async () => {}).constructor;";
  "const socket = net.createConnection(" ^ Yojson.Safe.to_string (`String socket) ^ ");";
  "socket.setEncoding(\"utf8\");";
  "const received = [];";
  "let pending = \"\", closed = false, wake = () => {};";
  "socket.on(\"data\", chunk => { pending += chunk; let end; while ((end = pending.indexOf(\"\\n\")) >= 0) { received.push(pending.slice(0, end)); pending = pending.slice(end + 1); } wake(); });";
  "const ownerGone = () => { if (closed) return; closed = true; socket.destroy(); process.exit(0); };";
  "socket.once(\"end\", ownerGone);";
  "socket.once(\"close\", ownerGone);";
  "socket.once(\"error\", ownerGone);";
  "while (true) {";
  "  while (received.length === 0 && !closed) await new Promise(resolve => { wake = resolve; });";
  "  if (closed) break;";
  "  const command = JSON.parse(received.shift());";
  "  const lines = [];";
  "  const log = (...parts) => { lines.push(parts.map(String).join(\" \")); };";
  "  try { await new AsyncFunction(\"console\", command.script)({log}); }";
  "  catch (error) { lines.push(\"the script threw outside its frame: \" + String(error && error.message || error)); }";
  "  socket.write(JSON.stringify({id: command.id, lines}) + \"\\n\");";
  "}";
  "socket.destroy();" ]

(* A started process: [ask] sends one script and reads its answer, and
   stops the process with its group when it does not answer; [close] closes
   its socket, so a process that leaves its loop exits by itself, then stops
   what is left. Both return once the process has ended. *)
type session_process = {
  ask : timeout_s:float option -> id:int -> string -> (string, Peer.run_failure) result;
  close : unit -> unit }
type session = { sw : Eio.Switch.t; env : Eio_unix.Stdenv.base; command : string; socket : string;
  mutable current : session_process option; mutable next_id : int }

let session ~sw ~env ~command ~directory =
  { sw; env; command; socket = Filename.concat directory socket_name; current = None; next_id = 0 }

let remove_socket path = match Unix.unlink path with
  | () | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let answer_of ~id line = match Yojson.Safe.from_string line with
  | exception Yojson.Json_error _ -> Error (Peer.Unobserved "the ego session answered unreadable JSON")
  | `Assoc fields ->
    (match List.assoc_opt "id" fields, List.assoc_opt "lines" fields with
     | Some (`Int answered), Some (`List lines) when answered = id ->
       let rec texts acc = function
         | [] -> Ok (String.concat "" (List.rev acc))
         | `String line :: rest -> texts ((line ^ "\n") :: acc) rest
         | _ :: _ -> Error (Peer.Unobserved "the ego session answered a line that is not text") in
       texts [] lines
     | Some (`Int _), Some (`List _) -> Error (Peer.Unobserved "the ego session answered another command")
     | _ -> Error (Peer.Unobserved "the ego session answered outside its frame"))
  | _ -> Error (Peer.Unobserved "the ego session answered outside its frame")

(* The process runs under its own switch in a fiber of the connection's
   switch, so it outlives each command and ends with the connection. *)
let start_session t ~timeout_s =
  let clock = Eio.Stdenv.clock t.env in
  if String.length t.socket > socket_path_limit_bytes then
    Error (Peer.Unstarted (Printf.sprintf "the ego session socket path %s is longer than %d bytes" t.socket socket_path_limit_bytes))
  else
    let ready, set_ready = Eio.Promise.create () in
    let stop_requested, request_stop = Eio.Promise.create () in
    let ended, set_ended = Eio.Promise.create () in
    let stop () = ignore (Eio.Promise.try_resolve request_stop ()); Eio.Promise.await ended in
    (* A fork on a cancelled switch never runs its fiber, so nothing would
       resolve [ended] for the stop below; the check raises the
       cancellation before anything starts. *)
    Eio.Switch.check t.sw;
    Eio.Fiber.fork ~sw:t.sw (fun () ->
      Fun.protect ~finally:(fun () ->
          ignore (Eio.Promise.try_resolve set_ready (Error (Peer.Unstarted "the ego session ended before it connected")));
          Eio.Promise.resolve set_ended ()) (fun () ->
        match Eio.Switch.run (fun process_sw ->
          (* Eio owns the listening socket's path until its switch ends.
             End that scope once the handshake answers; the accepted flow
             and process belong to the outer switch and keep serving. *)
          let written = Buffer.create read_chunk_bytes and chunk = Cstruct.create read_chunk_bytes in
          let drained, set_drained = Eio.Promise.create () in
          let ended_early status = match status with
            | `Exited code -> Peer.Exited {code; output = Buffer.contents written}
            | `Signaled signal -> Peer.Signaled signal in
          let connected = Eio.Switch.run (fun listener_sw ->
            remove_socket t.socket;
            let listening = Eio.Net.listen ~sw:listener_sw ~backlog:1 (Eio.Stdenv.net t.env) (`Unix t.socket) in
            let manager = Posix_spawn_process_mgr.foreground_mgr ~clock ~grace_seconds:stop_grace_s in
            let input_read, input_write = Eio_unix.pipe process_sw in
            let output_read, output_write = Eio_unix.pipe process_sw in
            match Eio.Process.spawn ~sw:process_sw manager ~stdin:input_read ~stdout:output_write ~stderr:output_write
                    [t.command; "nodejs"; "-e"; session_loop ~socket:t.socket] with
            | exception (Eio.Io _ as exn) -> Error (Peer.Unstarted (Printexc.to_string exn))
            | exception Unix.Unix_error (code, _, _) -> Error (Peer.Unstarted (Unix.error_message code))
            | process ->
              Eio.Flow.close input_read; Eio.Flow.close input_write; Eio.Flow.close output_write;
              (* What the process writes reaches ego only when it exits; the
                 start of it says why a process ended early. *)
              (* A daemon, so a switch that is leaving stops the process
                 instead of waiting for its output to end. *)
              Eio.Fiber.fork_daemon ~sw:process_sw (fun () ->
                let rec drain () = match Eio.Flow.single_read output_read chunk with
                  | read ->
                    if Buffer.length written + read <= Peer.output_limit_bytes then
                      Buffer.add_string written (Cstruct.to_string ~len:read chunk);
                    drain ()
                  | exception (End_of_file | Eio.Io _) -> Eio.Promise.resolve set_drained (); `Stop_daemon in
                drain ());
              (* A stop asked for while the process has not connected, by a
                 start that was cancelled, ends the wait as well. *)
              match Eio.Time.with_timeout clock timeout_s (fun () ->
                Eio.Fiber.any [
                  (fun () -> Ok (`Connected (fst (Eio.Net.accept ~sw:process_sw listening))));
                  (fun () -> Ok (`Ended (Eio.Process.await process)));
                  (fun () -> Eio.Promise.await stop_requested; Ok `Stopped) ]) with
              | Error `Timeout -> Error Peer.Timed_out
              | Ok (`Ended status) -> Error (ended_early status)
              | Ok `Stopped -> Error (Peer.Unstarted "the ego session was stopped before it connected")
              | Ok (`Connected flow) -> Ok (process, flow)) in
          match connected with
          | Error failure -> ignore (Eio.Promise.try_resolve set_ready (Error failure))
          | Ok (process, flow) ->
              let reader = Eio.Buf_read.of_flow flow ~initial_size:read_chunk_bytes ~max_size:Peer.output_limit_bytes in
              let ended_now () =
                (* The socket closed: the process is ending, and its status says how. *)
                match Eio.Time.with_timeout clock stop_grace_s (fun () ->
                  let status = Eio.Process.await process in Eio.Promise.await drained; Ok status) with
                | Ok status -> ended_early status
                | Error `Timeout -> Peer.Unobserved "the ego session closed its socket and did not exit" in
              let ask ~timeout_s ~id script =
                let failed failure = Eio.Cancel.protect stop; Error failure in
                let exchange () =
                  Eio.Flow.copy_string (Yojson.Safe.to_string (`Assoc ["id",`Int id;"script",`String script]) ^ "\n") flow;
                  Ok (Eio.Buf_read.line reader) in
                match (match timeout_s with None -> exchange ()
                  | Some seconds -> Eio.Time.with_timeout clock seconds exchange) with
                | Ok line -> (match answer_of ~id line with Ok output -> Ok output | Error failure -> failed failure)
                | Error `Timeout -> failed Peer.Timed_out
                | exception Eio.Buf_read.Buffer_limit_exceeded -> failed Peer.Output_exceeded
                | exception End_of_file -> let failure = ended_now () in failed failure
                | exception (Eio.Io _ as exn) -> failed (Peer.Unobserved (Printexc.to_string exn))
                | exception (Eio.Cancel.Cancelled _ as exn) -> Eio.Cancel.protect stop; raise exn in
              let close () =
                (try Eio.Flow.shutdown flow `All with Eio.Io _ -> ());
                ignore (Eio.Time.with_timeout clock stop_grace_s (fun () -> Ok (Eio.Process.await process)));
                stop () in
              ignore (Eio.Promise.try_resolve set_ready (Ok {ask; close}));
              Eio.Promise.await stop_requested) with
        | () -> ()
        | exception (Eio.Io _ as exn) ->
          ignore (Eio.Promise.try_resolve set_ready (Error (Peer.Unstarted (Printexc.to_string exn))))));
    (* A start that failed has stopped its process by the time it answers.
       A start that is cancelled stops it too, so no process connects
       later to a caller that is gone and holds the connection open. *)
    match Eio.Promise.await ready with
    | Ok process -> Ok process
    | Error failure -> Eio.Promise.await ended; Error failure
    | exception (Eio.Cancel.Cancelled _ as exn) -> Eio.Cancel.protect stop; raise exn

(* Stopping a run spends the stop grace, so it is taken out of the window
   the peer gives. Commands come one at a time: the connection's fiber
   answers one before it takes the next. *)
let run_session t ~window_s script =
  let clock = Eio.Stdenv.clock t.env in
  let timeout_s = Option.map (fun window -> window -. stop_grace_s) window_s in
  match timeout_s with
  | Some seconds when seconds <= 0. -> Error (Peer.Unstarted "the reply window has no time left to stop its SDK process")
  | None | Some _ ->
    let deadline = Option.map (fun seconds -> Eio.Time.now clock +. seconds) timeout_s in
    let startup_window = match timeout_s with Some seconds -> seconds
      | None -> B.reply_timeout_sec B.Tabs_list -. stop_grace_s in
    let started = match t.current with
      | Some process -> Ok process
      | None -> start_session t ~timeout_s:startup_window in
    match started with
    | Error failure -> Error failure
    | Ok process ->
      t.current <- Some process;
      t.next_id <- t.next_id + 1;
      let timeout_s = Option.map (fun deadline -> Float.max 0. (deadline -. Eio.Time.now clock)) deadline in
      match process.ask ~timeout_s ~id:t.next_id script with
      | Ok _ as answered -> answered
      | Error _ as failed -> t.current <- None; failed
      | exception (Eio.Cancel.Cancelled _ as exn) -> t.current <- None; raise exn
let runner t : Peer.runner = fun ~window_s script -> run_session t ~window_s:(Some window_s) script
let native_runner t script = run_session t ~window_s:None script

(* The connection's end: the process leaves its loop once its socket closes. *)
let end_session t = match t.current with
  | None -> ()
  | Some process -> t.current <- None; process.close ()

let version ~env ~command =
  let* output = run_command ~env ~timeout_s:version_timeout_s ~stdin:"" ~command ["--version"]
    |> Result.map_error Peer.run_failure_message in
  Browser_runtime_dependencies.ego_versions output

let capture_directory () = Eio_unix.run_in_systhread (fun () ->
  match Filename.temp_dir ~perms:0o700 "masc-ego-" "" with
  | directory -> Ok directory
  | exception Sys_error detail -> Error detail)

(* Only ego writes into this run's directory, and only screenshots, which the
   peer removes once read; a stopped capture leaves its file behind. The
   session's socket is there only until its process connects. *)
let remove_capture_directory directory = Eio_unix.run_in_systhread (fun () ->
  let unix_error path code = Error (path ^ ": " ^ Unix.error_message code) in
  match Sys.readdir directory with
  | exception Sys_error detail -> Error detail
  | names ->
    let* () = Array.fold_left (fun removed name ->
      let* () = removed in
      let path = Filename.concat directory name in
      match Unix.lstat path with
      | {Unix.st_kind = Unix.S_REG; _} ->
        (match Unix.unlink path with () -> Ok () | exception Unix.Unix_error (code, _, _) -> unix_error path code)
      | {Unix.st_kind = (Unix.S_DIR | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK); _} ->
        Error (path ^ " is not a screenshot file")
      | exception Unix.Unix_error (code, _, _) -> unix_error path code) (Ok ()) names in
    match Unix.rmdir directory with
    | () -> Ok ()
    | exception Unix.Unix_error (code, _, _) -> unix_error directory code)

(* The ego connection's downloads sit beside the owned Gecko's, in the
   worker's download folder the broker publishes from. *)
let downloads_folder = "ego"
type connection_end = Connected | User_owned_name of { space : string; observed_at : float }

let run ~env ~owner ~downloads (configuration : Browser_configuration.live_ego) work =
  let command = configuration.command in
  let downloads = {Peer.root = Filename.concat downloads downloads_folder;
    publish = (fun path -> Eio_unix.run_in_systhread (fun () -> Browser_addon_owner.publish_download owner path))} in
  let startup, started = Eio.Promise.create () and stopping, stop = Eio.Promise.create ()
  and stopped, finish = Eio.Promise.create () in
  let serve_space directory ~version ~engine_version = Eio.Switch.run (fun sw ->
    let session = session ~sw ~env ~command ~directory in
    let ended outcome = Eio.Cancel.protect (fun () -> end_session session); outcome in
    (* Only opening by name can meet a user-owned space of that name; an
       existing Space ID is attached exactly or refused by open_space. *)
    let observation = match configuration.space with
      | Browser_configuration.Named_space space ->
        Some (space, Peer.observe_space_name ~run:(runner session) ~space)
      | Existing_space _ -> None in
    (match observation with
     | Some (space, Peer.Space_names_unavailable detail) ->
       Log.Server.warn "browser Add-on could not inspect ego task space %S: %s" space detail
     | Some (_, (Peer.No_user_owned_match | Peer.User_owned_matches _)) | None -> ());
    ended @@ match observation with
    | Some (space, Peer.User_owned_matches _) ->
      Ok (User_owned_name {space; observed_at=Eio.Time.now (Eio.Stdenv.clock env)})
    | Some (_, (Peer.No_user_owned_match | Peer.Space_names_unavailable _)) | None ->
    let* peer = Peer.open_space ~space:configuration.space ~version ~capture_directory:directory ~downloads
        ~now:(fun () -> Eio.Time.now (Eio.Stdenv.clock env))
        ~run:(runner session) ~run_native:(native_runner session) in
    let client_id = Uuidm.v4_gen (Random.State.make_self_init ()) () in
    let client = {B.client_id; browser = B.Ego_lite; version; engine_version; transport = B.Ego_task_space;
      space=Some (Peer.space peer)} in
    let poll window_sec = Browser_addon_owner.poll_live owner ~client ~window_sec in
    let attached =
      let* first = poll 0. in
      let* () = if Option.is_none first then Ok () else Error "the ego connection received input before attachment" in
      Browser_addon_owner.attach_live ~ego_input:{Browser_ego_operator.status=(fun () -> Peer.input_status peer);
        busy=(fun () -> Peer.input_busy peer);assert_reset=(fun ~generation -> Peer.assert_input_reset peer ~generation);
        space_observation=(fun () -> Peer.space_observation peer)}
        owner ~client_id ~cleanup:(fun () ->
        ignore (Eio.Promise.try_resolve stop ());
        let* () = Eio.Promise.await stopped in
        Peer.retirement_settlement peer) in
    let served = match attached with
      | Error detail -> Error detail
      | Ok () ->
        ignore (Eio.Promise.try_resolve started (Ok Connected));
        let rec serve () =
          let* command = poll B.default_timeout_sec in
          let* () = match command with
            | None -> Ok ()
            | Some (command : B.issued) ->
              let result =
                let* verb, args, actor = Live.decode command |> Result.map_error (fun detail -> Live.Before_effect detail) in
                Peer.dispatch ~command_id:command.id peer ?actor ~verb args in
              (* A refused delivery loses this one result. The server stopped
                 waiting for it, and its caller was told the outcome is
                 unknown; a connection that is gone fails the next poll. *)
              (match Browser_addon_owner.deliver_live owner ~client_id ~id:command.id ~payload:(Live.payload result) with
               | Ok () -> ()
               | Error detail ->
                 Log.Server.warn "browser Add-on ego result of command %s was not delivered: %s" command.id detail);
              Ok () in
          if Browser_addon_owner.is_retired owner then Ok () else serve () in
        Eio.Fiber.first serve (fun () -> Eio.Promise.await stopping; Ok ()) in
    Browser_addon_owner.disconnect_live owner client_id;
    Result.map (fun () -> Connected) served) in
  let connect () =
    let* version, engine_version = version ~env ~command in
    let* directory = capture_directory () in
    let removed () = Eio.Cancel.protect (fun () -> remove_capture_directory directory)
      |> Result.map_error (fun detail -> "the ego screenshot directory was not removed: " ^ detail) in
    match serve_space directory ~version ~engine_version with
    | exception exn ->
      (match removed () with Ok () -> () | Error detail -> Log.Server.warn "browser Add-on %s" detail);
      raise exn
    | served ->
      match served, removed () with
      | Error detail, Error removal -> Error (detail ^ "; " ^ removal)
      | Error detail, Ok () | Ok _, Error detail -> Error detail
      | Ok outcome, Ok () -> Ok outcome in
  Eio.Switch.run (fun lifetime ->
    Eio.Fiber.fork ~sw:lifetime (fun () ->
      let outcome = match connect () with
        | outcome -> outcome
        | exception (Eio.Cancel.Cancelled _ as exn) ->
          Eio.Cancel.protect (fun () ->
            Browser_addon_owner.revoke owner;
            ignore (Eio.Promise.try_resolve started (Error "the ego connection was cancelled"));
            ignore (Eio.Promise.try_resolve finish (Error "the ego connection was cancelled")));
          raise exn
        | exception exn -> Error (Printexc.to_string exn) in
      Eio.Cancel.protect (fun () ->
        let outcome = match outcome with
          | Ok (User_owned_name {space; observed_at} as unavailable) ->
            (match Browser_addon_owner.mark_ego_user_owned_name owner ~space ~observed_at with
             | Error detail -> Error detail
             | Ok () ->
               Log.Server.warn "browser Add-on ego unavailable: task space %S is user-owned; resolve the conflict and restart the worker to recheck"
                 space;
               Ok unavailable)
          | Ok Connected -> Ok Connected
          | Error detail -> Error detail in
        (match outcome with Ok _ -> () | Error _ -> Browser_addon_owner.revoke owner);
        ignore (Eio.Promise.try_resolve started outcome);
        ignore (Eio.Promise.try_resolve finish (Result.map (fun _ -> ()) outcome))));
    match Eio.Promise.await startup with
    | Error detail -> invalid_arg ("ego connection: " ^ detail)
    | Ok (User_owned_name _) -> work ()
    | Ok Connected -> Eio.Switch.run (fun scope ->
      Eio.Switch.on_release scope (fun () ->
        Browser_addon_owner.revoke owner;
        ignore (Eio.Promise.try_resolve stop ());
        ignore (Eio.Promise.await stopped));
      Eio.Fiber.first work (fun () -> match Eio.Promise.await stopped with
        | Ok () -> Eio.Fiber.await_cancel ()
        | Error detail -> raise (Sys_error ("ego connection ended: " ^ detail)))))
