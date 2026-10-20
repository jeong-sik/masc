open Lane_addon_types
module Engine = Lane_addon_engine
module Protocol = Lane_addon_worker_protocol

type error =
  | Invalid_package of string
  | Docker_failed of { operation : string; detail : string }
  | Engine_failed of { runtime : runtime; operation : string; detail : string }
  | Engine_fault of { runtime : runtime; fault : Lane_addon_lifecycle.engine_fault }
  | Lifecycle of Lane_addon_lifecycle.failure
  | Protocol_failed of string
  | Host_refusal of Lane_addon_call_context.host_refusal
  | Invalid_observation of string
  | Stopped

type mount = Engine.mount = { source : string; destination : string }

type t = {
  id : string;
  name : string;
  protocol : Lane_addon_worker_protocol.t;
  cleanup : unit -> (unit, error) result;
  mutable removed : bool;
}

let error_to_string = function
  | Invalid_package detail -> "invalid Add-on package: " ^ detail
  | Docker_failed { operation; detail } ->
      Printf.sprintf "Add-on Docker %s failed: %s" operation detail
  | Engine_failed { runtime; operation; detail } ->
      Printf.sprintf "Add-on %s %s failed: %s" (runtime_to_string runtime) operation detail
  | Engine_fault { runtime; fault = Lane_addon_lifecycle.Unreachable detail } ->
      Printf.sprintf "Add-on %s engine is unreachable: %s" (runtime_to_string runtime) detail
  | Engine_fault { runtime; fault = Lane_addon_lifecycle.Identity_unreadable detail } ->
      Printf.sprintf "Add-on %s engine identity is unreadable: %s" (runtime_to_string runtime) detail
  | Lifecycle failure -> "Add-on " ^ Lane_addon_lifecycle.failure_to_string failure
  | Host_refusal (Lane_addon_call_context.Rejected detail | Unavailable detail | Activity_disabled detail | Activity_unobserved detail) -> detail
  | Protocol_failed detail -> "Add-on MCP failure: " ^ detail
  | Invalid_observation detail -> "invalid Add-on observation: " ^ detail
  | Stopped -> "Add-on worker is stopped"

(* The runtime acts on typed failures, so the one place that turns a worker
   error into one lists every error. An engine that does not answer is a wait;
   everything else is the worker's own failure, or an unconfirmed cleanup. *)
let start_failure = function
  | Lifecycle failure -> failure
  | Engine_fault { fault = Lane_addon_lifecycle.Unreachable detail; _ } ->
      Lane_addon_lifecycle.Engine_unreachable detail
  | (Invalid_package _ | Docker_failed _ | Engine_failed _
    | Engine_fault { fault = Lane_addon_lifecycle.Identity_unreadable _; _ }
    | Protocol_failed _ | Host_refusal _ | Invalid_observation _ | Stopped) as error ->
      Lane_addon_lifecycle.Worker_failed (error_to_string error)

let cleanup_failure = function
  | Lifecycle failure -> failure
  | Engine_fault { fault = Lane_addon_lifecycle.Unreachable detail; _ } ->
      Lane_addon_lifecycle.Engine_unreachable detail
  | (Invalid_package _ | Docker_failed _ | Engine_failed _
    | Engine_fault { fault = Lane_addon_lifecycle.Identity_unreadable _; _ }
    | Protocol_failed _ | Host_refusal _ | Invalid_observation _ | Stopped) as error ->
      Lane_addon_lifecycle.Cleanup_unconfirmed (error_to_string error)

let ( let* ) = Result.bind
let container_id t = t.id
let container_name t = t.name
let action_schema t = Protocol.action_schema t.protocol
let exported_tools t = Protocol.exported_tools t.protocol
let protocol_result result = Result.map_error (function
  | Protocol.Invalid_contract detail -> Invalid_package detail
  | Protocol.Protocol_failed detail -> Protocol_failed detail
  | Protocol.Host_refusal refusal -> Host_refusal refusal
  | Protocol.Invalid_observation detail -> Invalid_observation detail
  | Protocol.Stopped -> Stopped) result
let engine_error runtime ~operation detail = match runtime with
  | Docker -> Docker_failed { operation; detail }
  | Apple_container -> Engine_failed { runtime; operation; detail }
let command_for runtime ~docker_command ~container_command = match runtime with
  | Docker -> docker_command | Apple_container -> container_command

exception Control_reply_too_large

(* Engine control output is host-run CLI output, not a package reply, so the
   manifest's reply bound does not apply. It is bounded like any other
   captured subprocess stream, because an image can add large labels to an
   inspect result. Package stdout goes through the MCP transport's own bound. *)
let control_output_max_bytes = Common.max_process_capture_head_bytes

(* This reader bounds both engine control streams before retaining their
   contents. *)
let read_control flow =
  let max_bytes = control_output_max_bytes in
  let buffer = Buffer.create 4096 in
  let chunk = Cstruct.create 4096 in
  let rec loop () =
    match Eio.Flow.single_read flow chunk with
    | count ->
        if count > max_bytes - Buffer.length buffer then
          raise Control_reply_too_large;
        Buffer.add_string buffer (Cstruct.to_string (Cstruct.sub chunk 0 count));
        loop ()
    | exception End_of_file -> Buffer.contents buffer
  in
  loop ()

let run_control ~clock ~timeout_sec ~mgr ~runtime ~command ~operation args =
  let error detail = Error (engine_error runtime ~operation detail) in
  let run () =
    try Eio.Switch.run (fun sw ->
      let stdout_r, stdout_w = Eio.Process.pipe ~sw mgr in
      let stderr_r, stderr_w = Eio.Process.pipe ~sw mgr in
      let child = Eio.Process.spawn ~sw mgr
          ~stdin:(Eio.Flow.string_source "")
          ~stdout:stdout_w ~stderr:stderr_w (command :: args) in
      Eio.Flow.close stdout_w;
      Eio.Flow.close stderr_w;
      let stdout, stderr = Eio.Fiber.pair
          (fun () -> read_control stdout_r)
          (fun () -> read_control stderr_r) in
      match Eio.Process.await child with
      | `Exited 0 -> Ok stdout
      | `Exited code ->
          error (Printf.sprintf "exit %d: %s" code (String.trim stderr))
      | `Signaled signal ->
          error (Printf.sprintf "signal %d: %s" signal (String.trim stderr)))
    with
    | Control_reply_too_large ->
        error "control response exceeds byte limit"
    | (Eio.Io _ | Unix.Unix_error _ | Sys_error _) as exn ->
        error (Printexc.to_string exn)
  in
  match Eio.Time.with_timeout clock timeout_sec (fun () -> Ok (run ())) with
  | Ok result -> result
  | Error `Timeout ->
      error (Printf.sprintf "timed out after %.3g seconds" timeout_sec)

(* The engine answers [info] or it does not. The exit status decides, so a
   daemon that is down is [Unreachable] without reading its error text. *)
let read_engine_with ~run runtime =
  match run ~operation:"engine identity" (Engine.info_arguments runtime) with
  | Error error -> Error (Lane_addon_lifecycle.Unreachable (error_to_string error))
  | Ok raw -> Engine.engine_of_info runtime raw

let read_engine ~clock ~control_timeout_sec ~mgr ~runtime
    ?(docker_command="docker") ?(container_command="container") () =
  if not (Float.is_finite control_timeout_sec) || control_timeout_sec <= 0. then
    Error (Invalid_package "control_timeout_sec must be finite and positive")
  else
    let command = command_for runtime ~docker_command ~container_command in
    let run = run_control ~clock ~timeout_sec:control_timeout_sec ~mgr ~runtime ~command in
    read_engine_with ~run runtime
    |> Result.map_error (fun fault -> Engine_fault { runtime; fault })

let inspect_image ~clock ~control_timeout_sec ~mgr ~(package : package)
    ?(docker_command="docker") ?(container_command="container") () =
  if not (Float.is_finite control_timeout_sec) || control_timeout_sec <= 0. then
    Error (Invalid_package "control_timeout_sec must be finite and positive")
  else
  let* container = Lane_addon_types.container package
    |> Result.map_error (fun detail -> Invalid_package detail) in
  let runtime = container.runtime in
  let command = command_for runtime ~docker_command ~container_command in
  let* raw = run_control ~clock ~timeout_sec:control_timeout_sec ~mgr ~runtime ~command
      ~operation:"image inspect" (Engine.image_arguments runtime container.image) in
  Engine.image_digest runtime raw |> Result.map_error (engine_error runtime ~operation:"image inspect")

let validate_package (package : package) =
  let* container = Lane_addon_types.container package
    |> Result.map_error (fun detail -> Invalid_package detail) in
  match Lane_addon_types.check_resources ~runtime:container.runtime container.resources with
  | Error detail -> Error (Invalid_package detail)
  | Ok () ->
  if String.trim container.image = "" || package.command = [] then
    Error (Invalid_package "image and command are required")
  else if Filename.is_relative package.directory then
    Error (Invalid_package "package directory must be absolute")
  else Ok container

let verify_absent ~runtime ~run id =
  (* Only a successful enumeration can establish absence. *)
  let* raw = run ~operation:"verify removal" (Engine.list_arguments runtime (Engine.Id id)) in
  let* visible = Engine.listed_id runtime (Engine.Id id) raw
    |> Result.map_error (engine_error runtime ~operation:"verify removal") in
  match visible with
  | None -> Ok ()
  | Some _ -> Error (engine_error runtime ~operation:"verify removal"
      ("container remains visible after removal: " ^ id))

let remove_container ~runtime ~run id =
  (* Exact deletion does not delete a persistent named state volume. *)
  let removal = run ~operation:"remove" (Engine.remove_arguments runtime id) in
  match verify_absent ~runtime ~run id with
  | Ok () -> Ok ()
  | Error verify_error ->
      (match removal with Error error -> Error error | Ok _ -> Error verify_error)

(* The slot procedures run over these four engine commands. Their errors are
   text for the operator; what an absence or a holder means is decided in
   [Lane_addon_slot]. *)
let slot_port ?scope ~run runtime : Lane_addon_slot.port =
  let text error = error_to_string error in
  { read_engine = (fun () -> read_engine_with ~run runtime);
    find = (fun lookup ->
      let* raw = run ~operation:"find container" (Engine.list_arguments runtime lookup)
        |> Result.map_error text in
      Engine.listed_id runtime lookup raw);
    inspect = (fun id ->
      let* raw = run ~operation:"inspect container" (Engine.inspect_arguments runtime id)
        |> Result.map_error text in
      Engine.held_of_inspect runtime raw);
    remove = (fun id -> remove_container ~runtime ~run id |> Result.map_error text);
    scoped = (fun () -> match scope with
      | None -> Error "no base-path scope was given"
      | Some scope ->
          let* raw = run ~operation:"list scoped containers" (Engine.scoped_list_arguments runtime scope)
            |> Result.map_error text in
          Engine.listed_scoped_ids runtime ~scope raw) }

let slot_name ~runtime ~instance_id = function
  | None -> Engine.owned_name runtime instance_id
  | Some owner -> Lane_addon_worker_state.container_name ~runtime owner

let recover_stop ~clock ~control_timeout_sec ~mgr ~instance_id ~container_id ~engine ?(runtime = Docker) ?state_owner
    ?(docker_command = "docker") ?(container_command = "container") () =
  if not (Float.is_finite control_timeout_sec) || control_timeout_sec <= 0. then
    Error (Invalid_package "control_timeout_sec must be finite and positive")
  else if String.trim instance_id = "" then Error (Invalid_package "instance_id must be non-blank")
  else if Option.exists (fun id -> not (Engine.valid_id id)) container_id then
    Error (engine_error runtime ~operation:"recover ownership" "invalid container ID")
  else
    let command = command_for runtime ~docker_command ~container_command in
    let run = run_control ~clock ~timeout_sec:control_timeout_sec ~mgr ~runtime ~command in
    let port = slot_port ~run runtime in
    let mine = Option.map Lane_addon_worker_state.identity state_owner in
    let lookup = match container_id with
      | Some id -> Engine.Id id
      | None -> Engine.Name (slot_name ~runtime ~instance_id state_owner) in
    (* "No such container" says nothing unless the engine that answered is the
       one that holds the container. *)
    Lane_addon_slot.proven port ~expected:engine ~lift:(fun failure -> Lifecycle failure) (fun () ->
      Lane_addon_slot.release port ~lookup ~instance_id ~mine
      |> Result.map_error (fun failure -> Lifecycle failure))

let sweep ~clock ~control_timeout_sec ~mgr ~runtime ~scope ~is_live_instance
    ?(docker_command = "docker") ?(container_command = "container") () =
  if not (Float.is_finite control_timeout_sec) || control_timeout_sec <= 0. then
    Error (Lane_addon_lifecycle.Worker_failed "control_timeout_sec must be finite and positive")
  else
    let command = command_for runtime ~docker_command ~container_command in
    let run = run_control ~clock ~timeout_sec:control_timeout_sec ~mgr ~runtime ~command in
    Lane_addon_slot.sweep (slot_port ~scope ~run runtime) ~runtime ~is_live_instance

let holder_changed ~clock ~control_timeout_sec ~mgr ~runtime
    ?(docker_command = "docker") ?(container_command = "container") holder =
  Float.is_finite control_timeout_sec && control_timeout_sec > 0.
  && (let command = command_for runtime ~docker_command ~container_command in
      let run = run_control ~clock ~timeout_sec:control_timeout_sec ~mgr ~runtime ~command in
      Lane_addon_slot.holder_changed (slot_port ~run runtime) holder)

let stop t =
  (* Never take the observation mutex: an unresponsive observation is a
     reason to stop, not a prerequisite for stopping. *)
  Protocol.revoke t.protocol;
  if t.removed then Ok ()
  else
    let* () = t.cleanup () in
    t.removed <- true;
    Protocol.close t.protocol;
    Ok ()

let start ~sw ~clock ~control_timeout_sec ~mgr ~instance_id ~(package : package) ?state_owner ?(mounts = [])
    ?(docker_command = "docker") ?(container_command = "container") ?(on_engine = fun _ -> Ok ()) ?(is_live_instance = fun _ -> true) ?scope ?(on_created = fun _ -> ()) ?artifact_store ?sampling_handler () =
  let* () = if String.trim instance_id = "" then Error (Invalid_package "instance_id must be non-blank")
    else Ok () in
  let* () = if Float.is_finite control_timeout_sec && control_timeout_sec > 0. then Ok ()
    else Error (Invalid_package "control_timeout_sec must be finite and positive") in
  let* container = validate_package package in
  let* () = match package.state_storage, state_owner with
    | Persistent, None -> Error (Invalid_package "persistent state requires a host-owned installation identity")
    | Ephemeral, Some _ -> Error (Invalid_package "package did not declare persistent state")
    | Persistent, Some _ | Ephemeral, None -> Ok () in
  let* contract = Protocol.contract_of_package package |> protocol_result in
  let sampling_broker = sampling_handler in
  let* sampling_handler = match package.model_access, sampling_handler with
    | Model_disabled, None -> Ok None
    | Host_sampling, Some broker ->
        Lane_addon_sampling.for_worker broker ~package ~instance_id
        |> Result.map Option.some |> Result.map_error (fun detail -> Invalid_package detail)
    | Host_sampling, None -> Error (Invalid_package "package requires host sampling; no host model handler is configured")
    | Model_disabled, Some _ -> Error (Invalid_package "package does not declare host sampling") in
  let* () = match package.action_tool, artifact_store with
    | Some _, None -> Error (Invalid_package "action worker requires its owned artifact store")
    | _ -> Ok () in
  let runtime = container.runtime in
  let command = command_for runtime ~docker_command ~container_command in
  let* package_mount = Engine.mount_argument runtime
      { source = package.directory; destination = "/addon" }
      |> Result.map_error (fun detail -> Invalid_package detail) in
  let* mounted = List.fold_left (fun acc mount ->
      let* paths = acc in
      let* path = Engine.mount_argument runtime mount
        |> Result.map_error (fun detail -> Invalid_package detail) in
      Ok (paths @ [ "--mount"; path ])) (Ok []) mounts in
  (* The binding is persisted before create. Its instance ID therefore also
     identifies a container when the process dies before receiving create's
     stdout or persisting [on_created]. Domain labels are checked before any
     recovered container is removed. *)
  let name = slot_name ~runtime ~instance_id state_owner in
  let run = run_control ~clock ~timeout_sec:control_timeout_sec ~mgr ~runtime ~command in
  (* No create is attempted against an engine that cannot name itself. *)
  let* engine = read_engine_with ~run runtime
    |> Result.map_error (fun fault -> Engine_fault { runtime; fault }) in
  (* Apple resolves local tags during create. Record the descriptor first and
     verify the created configuration before starting any package process. *)
  let* image_digest = match runtime with
    | Docker -> Ok None
    | Apple_container ->
        let* raw = run ~operation:"image inspect" (Engine.image_arguments runtime container.image) in
        Engine.image_digest runtime raw |> Result.map Option.some
        |> Result.map_error (engine_error runtime ~operation:"image inspect") in
  let* () = match state_owner with
    | Some owner when not (Lane_addon_worker_state.belongs_to owner ~package_id:package.id) ->
        Error (Invalid_package "persistent state owner names a different package")
    | Some _ | None -> Ok () in
  (* The engine is recorded before the first create. A create that lands but
     whose answer is lost can then only be on this engine, and a record that
     names no engine has never issued one. *)
  let* () = on_engine engine
    |> Result.map_error (fun detail ->
      Lifecycle (Lane_addon_lifecycle.Persistence_failed ("engine identity persistence: " ^ detail))) in
  let port = slot_port ~run runtime in
  let mine = Option.map Lane_addon_worker_state.identity state_owner in
  let identity = ref None in
  let cleanup_finished = ref false in
  let cleanup () =
    if !cleanup_finished then Ok ()
    else match !identity with
      | None ->
          (* create can take effect before its stdout is received. Verify the
             binding's deterministic name and label instead of removing an
             unverified name collision. An absence seen here is not final: a
             create whose outcome is unknown can still land after this check,
             so the cleanup stays open for the check made when the switch is
             released. *)
          recover_stop ~clock ~control_timeout_sec ~mgr ~instance_id ~container_id:None ~engine ~runtime ?state_owner
            ~docker_command ~container_command ()
      | Some id ->
          let* () = match runtime with
            | Docker ->
                Lane_addon_slot.proven port ~expected:engine
                  ~lift:(fun failure -> Lifecycle failure) (fun () -> remove_container ~runtime ~run id)
            | Apple_container ->
                (* Apple IDs are reusable names. An old handle cannot delete
                   the new incarnation now occupying its persistent slot. *)
                recover_stop ~clock ~control_timeout_sec ~mgr ~instance_id
                  ~container_id:(Some id) ~engine ~runtime ?state_owner
                  ~docker_command ~container_command () in
          cleanup_finished := true;
          Ok ()
  in
  Eio.Switch.on_release sw (fun () ->
    Eio.Cancel.protect (fun () ->
      match cleanup () with
      | Ok () -> ()
      | Error error -> Log.Misc.error "Lane Add-on worker cleanup failed: %s" (error_to_string error)));
  let fail_start error =
    match cleanup () with
    | Ok () -> Error error
    | Error cleanup_error ->
        Error (engine_error runtime ~operation:"failed attach cleanup"
          (error_to_string error ^ "; " ^ error_to_string cleanup_error))
  in
  (* Volume, create and the answer to it all come from the recorded engine,
     or the attempt is refused. *)
  let create_on_engine () =
    let* state_mount = match state_owner with
      | None -> Ok []
      | Some owner ->
          Lane_addon_worker_state.ensure ~runtime owner
            ~run:(fun ~operation args -> run ~operation args |> Result.map_error error_to_string)
          |> Result.map (fun mount -> ["--mount"; mount])
          |> Result.map_error (engine_error runtime ~operation:"persistent state") in
    (* The slot's name is the only thing a create can collide on. A dead
       predecessor of this installation is removed first; any other holder is
       refused by name and never touched. *)
    let* () = Lane_addon_slot.claim port ~name ~instance_id ~mine ~is_live_instance
      |> Result.map_error (fun failure -> Lifecycle failure) in
    run ~operation:"create"
      (Engine.create_arguments container ~command:package.command ~name ~instance_id ~state_owner:mine ~image:container.image
         ~scope ~package_mount ~mounts:mounted ~state_mounts:state_mount) in
  let* created = match Lane_addon_slot.proven port ~expected:engine
      ~lift:(fun failure -> Lifecycle failure) create_on_engine with
    | Ok value -> Ok value
    | Error error -> fail_start error
  in
  let id = String.trim created in
  if not (Engine.valid_id id) || (runtime = Apple_container && not (String.equal id name)) then
    fail_start (engine_error runtime ~operation:"create" "invalid container ID")
  else begin
    identity := Some id;
    let stderr_source = ref None in
    let worker_cleanup () =
      let* () = cleanup () in
      Option.iter (fun source ->
        try Eio.Flow.close source with Eio.Io _ | Unix.Unix_error _ -> ()) !stderr_source;
      stderr_source := None;
      Ok () in
    let protocol = Protocol.create ~instance_id ~contract
      ?artifact_store ?sampling_broker () in
    let worker = {id;name;protocol;cleanup=worker_cleanup;removed=false} in
    let result = try
      on_created worker;
      let* () = if Protocol.revoked protocol then Error Stopped else Ok () in
      let* inspected = run ~operation:"inspect" (Engine.inspect_arguments runtime id) in
      let* inspected_id = Engine.verify_container runtime ~name ~resources:container.resources ~image_digest inspected
        |> Result.map_error (engine_error runtime ~operation:"inspect") in
      if not (String.equal inspected_id id) then
        Error (engine_error runtime ~operation:"inspect" "container ID changed")
      else
        (* Package diagnostics have an OS-bounded pipe. They cannot flood the
           host log or allocate an unbounded buffer. A noisy package may block
           itself; the owner and other Add-ons do not share this pipe. *)
        let stderr_r, stderr_w = Eio.Process.pipe ~sw mgr in
        stderr_source := Some stderr_r;
        let protocol_error error = Protocol_failed (Agent_core.Error.to_string error) in
        let* client = Agent_core.Mcp.connect ~sw ~mgr ~command
            ~args:(Engine.start_arguments runtime id)
            ~stderr:(stderr_w :> Eio.Flow.sink_ty Eio.Resource.t)
            ~max_response_bytes:(Lane_addon_types.max_reply_bytes package) ?sampling_handler ()
          |> Result.map_error protocol_error in
        Eio.Flow.close stderr_w;
        let* () = Protocol.initialize protocol client |> protocol_result in
        Ok worker
      with
      | (Eio.Io _ | Unix.Unix_error _ | Sys_error _ | End_of_file | Failure _
        | Invalid_argument _) as exn -> Error (Protocol_failed (Printexc.to_string exn))
    in
    match result with
    | Ok _ -> result
    | Error error ->
        Protocol.close protocol;
        fail_start error
  end

let observe t ~binding ~sources =
  Protocol.observe t.protocol ~binding ~sources |> protocol_result
let act t ~arguments = Protocol.act t.protocol ~arguments |> protocol_result
let call_exported_tool ?on_result ?authorize ?principal t ~name ~arguments =
  Protocol.call_exported_tool ?on_result ?authorize ?principal t.protocol ~name ~arguments
  |> protocol_result

let host_requests t = Protocol.host_requests t.protocol |> protocol_result
let host_result t ~arguments = Protocol.host_result t.protocol ~arguments |> protocol_result
