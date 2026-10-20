module Protocol = Lane_addon_worker_protocol
type command = { executable : string; arguments : string list }
type release = {
  instance_id : string;
  pid : int;
  started : string option;
  exit_status : Eio.Process.exit_status;
}
type error = Invalid_specification of string | Start_failed of string
  | Protocol of Protocol.error | Cleanup_unconfirmed of string | Stopped
type t = {
  protocol : Protocol.t;
  request_stop : unit Eio.Promise.u;
  completion : (release, error) result Eio.Promise.t;
}
let ( let* ) = Result.bind
let request_stop t =
  Protocol.revoke t.protocol;
  ignore (Eio.Promise.try_resolve t.request_stop ())
let confirm = function
  | Error error -> Error error
  | Ok receipt ->
      (try
        if Posix_spawn_detached.group_id_has_members receipt.pid then
          Error (Cleanup_unconfirmed "native worker exited but its process group still has live members")
        else Ok receipt
      with (Unix.Unix_error _ | Sys_error _) as exn ->
        Error (Cleanup_unconfirmed (Printexc.to_string exn)))
let release t = Option.map confirm (Eio.Promise.peek t.completion)
let stop t =
  request_stop t;
  Eio.Promise.await t.completion |> confirm
let protocol_result result = Result.map_error (fun error -> Protocol error) result
let exported_tools t = Protocol.exported_tools t.protocol
let call t work =
  try work () |> protocol_result with Eio.Cancel.Cancelled _ as exn ->
    request_stop t;
    raise exn
let observe t ~binding ~sources = call t (fun () -> Protocol.observe t.protocol ~binding ~sources)
let act t ~arguments = call t (fun () -> Protocol.act t.protocol ~arguments)
let call_exported_tool ?on_result ?authorize ?principal t ~name ~arguments =
  call t (fun () ->
    Protocol.call_exported_tool ?on_result ?authorize ?principal t.protocol ~name ~arguments)

let start ~sw ~clock ~grace_seconds ~instance_id ~contract ~command ?cwd ?env
    ?artifact_store ?(on_created = fun _ -> Ok ()) () =
  let* () = if String.trim instance_id = "" then
      Error (Invalid_specification "instance_id must be non-blank") else Ok () in
  let* () = if Float.is_finite grace_seconds && grace_seconds >= 0. then Ok ()
    else Error (Invalid_specification "grace_seconds must be finite and non-negative") in
  let* () = if String.trim command.executable = "" then
      Error (Invalid_specification "executable must be non-blank") else Ok () in
  let* () = if List.exists (fun text -> String.contains text '\000')
      (command.executable :: command.arguments) then
      Error (Invalid_specification "command arguments cannot contain NUL") else Ok () in
  let* () = match env with
    | Some values when Array.exists (fun text -> String.contains text '\000') values ->
        Error (Invalid_specification "environment entries cannot contain NUL")
    | None | Some _ -> Ok () in
  let ready, set_ready = Eio.Promise.create () in
  let completion, set_completion = Eio.Promise.create () in
  let stop_requested, set_stop = Eio.Promise.create () in
  let protocol = Protocol.create ~instance_id ~contract ?artifact_store () in
  let worker = {protocol;request_stop=set_stop;completion} in
  Eio.Switch.check sw;
  Eio.Fiber.fork ~sw (fun () ->
    let client = ref None in
    let identity = ref None in
    let failure = ref None in
    let cleanup_completed = ref false in
    let finish () = Eio.Cancel.protect (fun () ->
      Protocol.revoke protocol;
      let terminal = if not !cleanup_completed then
          Error (Cleanup_unconfirmed "native worker owner cleanup did not complete")
        else match !client, !identity with
          | Some client, Some (pid, started) ->
              (try Ok {instance_id;pid;started;exit_status=Agent_core.Mcp.await_exit client}
               with (Eio.Io _ | Unix.Unix_error _ | Sys_error _ | Failure _) as exn ->
                 Error (Cleanup_unconfirmed (Printexc.to_string exn)))
          | None, None | Some _, None | None, Some _ ->
              Error (match !failure with Some error -> error | None -> Stopped) in
      ignore (Eio.Promise.try_resolve set_completion terminal);
      let start_error = match terminal with
        | Error (Cleanup_unconfirmed _ as error) -> error
        | Ok _ | Error (Invalid_specification _ | Start_failed _ | Protocol _ | Stopped) ->
            (match !failure with Some error -> error | None -> Stopped) in
      ignore (Eio.Promise.try_resolve set_ready (Error start_error))) in
    Fun.protect ~finally:finish (fun () ->
      try
        Eio.Switch.run (fun process_sw ->
          if Eio.Promise.is_resolved stop_requested then failure := Some Stopped
          else
            let mgr = Posix_spawn_process_mgr.foreground_mgr ~clock ~grace_seconds in
            match Agent_core.Mcp.connect ~sw:process_sw ~mgr ~command:command.executable
              ~args:command.arguments ?cwd ?env ~max_response_bytes:contract.max_reply_bytes () with
            | Error error -> failure := Some (Start_failed (Agent_core.Error.to_string error))
            | Ok connected ->
                client := Some connected;
                let pid = Agent_core.Mcp.process_id connected in
                identity := Some (pid, Posix_spawn_detached.process_start pid);
                Eio.Switch.on_release process_sw (fun () -> Protocol.close protocol);
                (match on_created worker with
                 | Error detail -> failure := Some (Start_failed detail)
                 | Ok () ->
                     let initialized = Eio.Fiber.first
                       (fun () -> `Initialized (Protocol.initialize protocol connected))
                       (fun () -> Eio.Promise.await stop_requested; `Stopped) in
                     match initialized with
                     | `Stopped -> failure := Some Stopped
                     | `Initialized (Error error) -> failure := Some (Protocol error)
                     | `Initialized (Ok ()) ->
                         Eio.Promise.resolve set_ready (Ok worker);
                         Eio.Fiber.first
                           (fun () -> Eio.Promise.await stop_requested)
                           (fun () -> ignore (Agent_core.Mcp.await_exit connected : Eio.Process.exit_status));
                         Protocol.revoke protocol));
        cleanup_completed := true
      with
      | Eio.Cancel.Cancelled _ as exn -> failure := Some Stopped; raise exn
      | (Eio.Io _ | Unix.Unix_error _ | Sys_error _ | End_of_file | Failure _ | Invalid_argument _) as exn ->
          failure := Some (Start_failed (Printexc.to_string exn))));
  try Eio.Promise.await ready with Eio.Cancel.Cancelled _ as exn ->
    request_stop worker;
    raise exn
