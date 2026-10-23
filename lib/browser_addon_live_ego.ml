module B = Browser_lane
module Peer = Browser_ego_peer
module Live = Browser_live_peer
let ( let* ) = Result.bind

let arguments (configuration : Browser_configuration.live_ego) =
  ["--live-ego-command";configuration.command;"--live-ego-space";configuration.space]

(* A stopped run gets TERM, then KILL after this long, with its process
   group. The foreground manager waits this long even when the run ends at
   once, so stopping a run costs it. *)
let stop_grace_s = 2.
(* ego-browser --version answers without starting the browser. *)
let version_timeout_s = 10.
(* Every command this connection serves is a read, which the server waits
   Browser_lane.default_timeout_sec for, counted from when it was issued. A
   run is given that less the stop grace and this margin, so a stopped run's
   failure usually still arrives in time. One that does not is refused:
   see [serve]. *)
let delivery_margin_s = 2.
let command_timeout_s = B.default_timeout_sec -. stop_grace_s -. delivery_margin_s
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

let version ~env ~command =
  let* output = run_command ~env ~timeout_s:version_timeout_s ~stdin:"" ~command ["--version"]
    |> Result.map_error Peer.run_failure_message in
  Peer.version_of_output output

let capture_directory () = Eio_unix.run_in_systhread (fun () ->
  match Filename.temp_dir ~perms:0o700 "masc-ego-" "" with
  | directory -> Ok directory
  | exception Sys_error detail -> Error detail)

(* Only ego writes into this run's directory, and only screenshots, which the
   peer removes once read; a stopped capture leaves its file behind. *)
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

let run ~env ~owner (configuration : Browser_configuration.live_ego) work =
  let command = configuration.command in
  let startup, started = Eio.Promise.create () and stopping, stop = Eio.Promise.create ()
  and stopped, finish = Eio.Promise.create () in
  let serve_space directory ~version ~engine_version =
    let* peer = Peer.open_space ~space:configuration.space ~version ~capture_directory:directory
        ~run:(fun script -> run_command ~env ~timeout_s:command_timeout_s ~stdin:script ~command ["nodejs"]) in
    let client_id = Uuidm.v4_gen (Random.State.make_self_init ()) () in
    let client = {B.client_id; browser = B.Ego_lite; version; engine_version; transport = B.Ego_task_space} in
    let poll window_sec = Browser_addon_owner.poll_live owner ~client ~window_sec in
    let attached =
      let* first = poll 0. in
      let* () = if Option.is_none first then Ok () else Error "the ego connection received input before attachment" in
      Browser_addon_owner.attach_live owner ~client_id ~cleanup:(fun () ->
        ignore (Eio.Promise.try_resolve stop ());
        Eio.Promise.await stopped) in
    let served = match attached with
      | Error detail -> Error detail
      | Ok () ->
        ignore (Eio.Promise.try_resolve started (Ok ()));
        let rec serve () =
          let* command = poll B.default_timeout_sec in
          let* () = match command with
            | None -> Ok ()
            | Some (command : B.issued) ->
              let result =
                let* verb, args, _actor = Live.decode command |> Result.map_error (fun detail -> Live.Before_effect detail) in
                Peer.dispatch peer ~verb args in
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
    let finished = Peer.finish peer in
    match served, finished with
    | Error detail, (Ok () | Error _) -> Error detail
    | Ok (), Error detail -> Error ("the ego task space did not end: " ^ detail)
    | Ok (), Ok () -> Ok () in
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
      | Error detail, Ok () | Ok (), Error detail -> Error detail
      | Ok (), Ok () -> Ok () in
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
        (match outcome with Ok () -> () | Error _ -> Browser_addon_owner.revoke owner);
        ignore (Eio.Promise.try_resolve started outcome);
        ignore (Eio.Promise.try_resolve finish outcome)));
    match Eio.Promise.await startup with
    | Error detail -> invalid_arg ("ego connection: " ^ detail)
    | Ok () -> Eio.Switch.run (fun scope ->
      Eio.Switch.on_release scope (fun () ->
        Browser_addon_owner.revoke owner;
        ignore (Eio.Promise.try_resolve stop ());
        ignore (Eio.Promise.await stopped));
      Eio.Fiber.first work (fun () -> match Eio.Promise.await stopped with
        | Ok () -> Eio.Fiber.await_cancel ()
        | Error detail -> raise (Sys_error ("ego connection ended: " ^ detail)))))
