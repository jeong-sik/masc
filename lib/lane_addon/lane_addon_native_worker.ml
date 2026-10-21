module Protocol = Lane_addon_worker_protocol
type command = { executable : string; arguments : string list }
type release = {
  instance_id : string;
  pid : int;
  started : string option;
  exit_status : Eio.Process.exit_status;
}
type error = Invalid_specification of string | Start_failed of string
  | Admission of Native_addon_lease.error
  | Protocol of Protocol.error | Cleanup_unconfirmed of string | Stopped
let error_to_string = function
  | Invalid_specification detail | Start_failed detail | Cleanup_unconfirmed detail -> detail
  | Admission error -> Native_addon_lease.error_to_string error
  | Protocol (Protocol.Invalid_contract detail | Protocol.Protocol_failed detail | Protocol.Invalid_observation detail) -> detail
  | Protocol (Protocol.Host_refusal (Lane_addon_call_context.Rejected detail | Unavailable detail | Activity_disabled detail | Activity_unobserved detail)) -> detail
  | Protocol Protocol.Stopped | Stopped -> "native Add-on is stopped"
type phase = Initializing | Validating_owner | Serving | Retired
type t = {
  protocol : Protocol.t;
  admission : Native_addon_lease.t;
  mutable phase : phase;
  mutable process_identity : Lane_addon_lifecycle.resource option;
  mutable confirmed : release option;
  request_stop : unit Eio.Promise.u;
  request_retirement : unit Eio.Promise.u;
  completion : (release, error) result Eio.Promise.t;
}
let ( let* ) = Result.bind
let phase t = t.phase
let process_identity t = t.process_identity
let request_stop t =
  t.phase <- Retired;
  Protocol.revoke t.protocol;
  ignore (Eio.Promise.try_resolve t.request_retirement ());
  ignore (Eio.Promise.try_resolve t.request_stop ())
let admission_status admission = Eio_unix.run_in_systhread (fun () -> Native_addon_lease.status admission)
let confirm t result = match t.confirmed with
  | Some receipt -> Ok receipt
  | None -> match result with
    | Error error -> Error error
    | Ok receipt ->
        (* Process completion is immutable; durable retirement can fail
           transiently. Retry only this original claim, never its payload. *)
        let* () = Eio_unix.run_in_systhread (fun () -> Native_addon_lease.retire t.admission)
          |> Result.map_error (fun error -> Cleanup_unconfirmed (Native_addon_lease.error_to_string error)) in
        match admission_status t.admission with
        | Ok Native_addon_lease.Settled -> t.confirmed <- Some receipt;Ok receipt
        | Ok (Native_addon_lease.Awaiting_exec | Live _ | Cleanup_pending _) ->
            Error (Cleanup_unconfirmed "native admission has not settled")
        | Error error -> Error (Cleanup_unconfirmed (Native_addon_lease.error_to_string error))
let release t = Option.map (confirm t) (Eio.Promise.peek t.completion)
let stop t =
  request_stop t;
  Eio.Promise.await t.completion |> confirm t
let protocol_result result = Result.map_error (fun error -> Protocol error) result
let exported_tools t = match t.phase with
  | Serving -> Protocol.exported_tools t.protocol | Initializing | Validating_owner | Retired -> []
let action_schema t = match t.phase with
  | Serving -> Protocol.action_schema t.protocol | Initializing | Validating_owner | Retired -> None
let call t work =
  match t.phase with
  | Initializing | Validating_owner | Retired -> Error (Protocol Protocol.Stopped)
  | Serving ->
      try work () |> protocol_result with Eio.Cancel.Cancelled _ as exn ->
        request_stop t;
        raise exn
let observe t ~binding ~sources = call t (fun () -> Protocol.observe t.protocol ~binding ~sources)
let act t ~arguments = call t (fun () -> Protocol.act t.protocol ~arguments)
let host_requests t = call t (fun () -> Protocol.host_requests t.protocol)
let host_result t ~arguments = call t (fun () -> Protocol.host_result t.protocol ~arguments)
let call_exported_tool ?on_result ?authorize ?principal t ~name ~arguments =
  call t (fun () ->
    Protocol.call_exported_tool ?on_result ?authorize ?principal t.protocol ~name ~arguments)

let start ~sw ~clock ~grace_seconds ~admission ~launcher ~contract ~command ?cwd ?env
    ?artifact_store ?(on_created = fun _ -> Ok ()) () =
  let instance_id = Native_addon_lease.instance_id admission in
  let* () = if String.trim launcher="" || String.contains launcher '\000' then
      Error (Invalid_specification "launcher must be nonblank without NUL") else Ok () in
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
  Eio.Switch.check sw;
  let* state = admission_status admission |> Result.map_error (fun error -> Admission error) in
  let* () = match state with
    | Native_addon_lease.Awaiting_exec -> Ok ()
    | Live _ | Cleanup_pending _ | Settled -> Error (Admission Native_addon_lease.Stale_claim) in
  let arguments = ["--instance";instance_id] @
    List.concat_map (fun directory -> ["--slot";directory]) (Native_addon_lease.directories admission) @
    ["--";command.executable] @ command.arguments in
  let ready, set_ready = Eio.Promise.create () in
  let completion, set_completion = Eio.Promise.create () in
  let stop_requested, set_stop = Eio.Promise.create () in
  let retirement_requested, set_retirement = Eio.Promise.create () in
  let protocol = Protocol.create ~instance_id ~contract ?artifact_store () in
  let worker = {protocol;admission;phase=Initializing;process_identity=None;confirmed=None;
    request_stop=set_stop;request_retirement=set_retirement;completion} in
  Eio.Switch.check sw;
  Eio.Fiber.fork ~sw (fun () ->
    let client = ref None in
    let identity = ref None in
    let failure = ref None in
    let retirement_failure = ref None in
    let cleanup_completed = ref false in
    let finish () = Eio.Cancel.protect (fun () ->
      worker.phase <- Retired;
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
      let start_error = match !retirement_failure with
        | Some error -> Cleanup_unconfirmed (Native_addon_lease.error_to_string error)
        | None -> match terminal with
          | Error (Cleanup_unconfirmed _ as error) -> error
          | Ok _ | Error (Invalid_specification _ | Start_failed _ | Admission _ | Protocol _ | Stopped) ->
              (match !failure with Some error -> error | None -> Stopped) in
      ignore (Eio.Promise.try_resolve set_ready (Error start_error))) in
    Fun.protect ~finally:finish (fun () ->
      try
        let run_process () = Fun.protect ~finally:(fun () ->
          ignore (Eio.Promise.try_resolve set_retirement ())) (fun () ->
        try Eio.Switch.run (fun process_sw ->
          if Eio.Promise.is_resolved stop_requested then failure := Some Stopped
          else
            let mgr = Posix_spawn_process_mgr.foreground_mgr ~clock ~grace_seconds in
            match Agent_core.Mcp.connect ~sw:process_sw ~mgr ~command:launcher
              ~args:arguments ?cwd ?env ~max_response_bytes:contract.max_reply_bytes () with
            | Error error -> failure := Some (Start_failed (Agent_core.Error.to_string error))
            | Ok connected ->
                client := Some connected;
                let pid = Agent_core.Mcp.process_id connected in
                let started = Posix_spawn_detached.process_start pid in
                identity := Some (pid, started);
                worker.process_identity <- Some (Lane_addon_lifecycle.Native_resource
                  {pid;started});
                Eio.Switch.on_release process_sw (fun () -> Protocol.close protocol);
                (* Kernel gate I/O cannot be cancelled once its systhread runs.
                   This sibling can still stop the exact owned process while
                   validation is waiting. Switch cancellation also runs finally. *)
                Eio.Switch.check process_sw;
                Eio.Fiber.fork_daemon ~sw:process_sw (fun () ->
                  Fun.protect ~finally:(fun () ->
                    request_stop worker;
                    Agent_core.Mcp.request_stop connected)
                    (fun () -> Eio.Promise.await stop_requested; `Stop_daemon));
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
                         (match worker.phase with
                          | Retired | Serving | Validating_owner -> failure := Some Stopped
                          | Initializing ->
                              worker.phase <- Validating_owner;
                              (match admission_status admission with
                               | Ok (Native_addon_lease.Live owner) when owner.pid=pid ->
                                   identity := Some (pid,Some owner.started);
                                   worker.process_identity <- Some (Lane_addon_lifecycle.Native_resource
                                     {pid;started=Some owner.started});
                                   (match worker.phase with
                                    | Retired | Serving | Initializing -> failure := Some Stopped
                                    | Validating_owner when Protocol.revoked protocol -> failure := Some Stopped
                                    | Validating_owner ->
                                        worker.phase <- Serving;
                                        Eio.Promise.resolve set_ready (Ok worker);
                                        Eio.Fiber.first
                                          (fun () -> Eio.Promise.await stop_requested)
                                          (fun () -> ignore (Agent_core.Mcp.await_exit connected : Eio.Process.exit_status));
                                        Protocol.revoke protocol)
                               | Ok (Awaiting_exec | Live _ | Cleanup_pending _ | Settled) ->
                                   failure := Some (Admission Native_addon_lease.Stale_claim)
                               | Error error -> failure := Some (Admission error)))));
        cleanup_completed := true
        with Eio.Cancel.Cancelled _ as exn -> cleanup_completed := true;raise exn) in
        let retire () = Eio.Cancel.protect (fun () ->
          Eio.Promise.await retirement_requested;
          match Eio_unix.run_in_systhread (fun () -> Native_addon_lease.retire admission) with
          | Ok () -> () | Error error -> retirement_failure := Some error) in
        Eio.Fiber.both run_process retire
      with
      | Eio.Cancel.Cancelled _ as exn -> failure := Some Stopped; raise exn
      | (Eio.Io _ | Unix.Unix_error _ | Sys_error _ | End_of_file | Failure _ | Invalid_argument _) as exn ->
          failure := Some (Start_failed (Printexc.to_string exn))));
  try Eio.Promise.await ready with Eio.Cancel.Cancelled _ as exn ->
    request_stop worker;
    raise exn
