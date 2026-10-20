open Lane_addon_types
module Engine = Lane_addon_engine

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
  instance_id : string;
  package : package;
  image : Engine.image_identity;
  artifact_store : Lane_addon_store.t option;
  input_history : Lane_addon_machine_history.t;
  sampling_broker : Lane_addon_sampling.t option;
  mutable exported_tools : Mcp_protocol.Mcp_types.tool list;
  mutable tool_hooks : (string * Lane_addon_tool_hooks.t) list;
  mutable action_schema : Yojson.Safe.t option;
  mutable client : Agent_core.Mcp.t option;
  cleanup : unit -> (unit, error) result;
  mutex : Eio.Mutex.t;
  mutable stopping : bool;
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
let image_identity t = t.image
let container_name t = t.name
let action_schema t = t.action_schema
let exported_tools t = if t.stopping then [] else t.exported_tools
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
  let runtime = package.runtime in
  let command = command_for runtime ~docker_command ~container_command in
  let* raw = run_control ~clock ~timeout_sec:control_timeout_sec ~mgr ~runtime ~command
      ~operation:"image inspect" (Engine.image_arguments runtime package.image) in
  Engine.image_of_inspect runtime raw |> Result.map_error (engine_error runtime ~operation:"image inspect")

let validate_package (package : package) =
  match Lane_addon_types.check_resources ~runtime:package.runtime package.resources with
  | Error detail -> Error (Invalid_package detail)
  | Ok () ->
  if String.trim package.image = "" || package.command = [] then
    Error (Invalid_package "image and command are required")
  else if Filename.is_relative package.directory then
    Error (Invalid_package "package directory must be absolute")
  else Ok ()

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
  t.stopping <- true;
  if t.removed then Ok ()
  else
    let* () = t.cleanup () in
    t.removed <- true;
    (try Option.iter Agent_core.Mcp.close t.client with
     | Eio.Io _ | Unix.Unix_error _ | Sys_error _ -> ());
    Ok ()

let start ~sw ~clock ~control_timeout_sec ~mgr ~instance_id ~(package : package) ?state_owner ?(mounts = [])
    ?(docker_command = "docker") ?(container_command = "container") ?(on_engine = fun _ -> Ok ()) ?(is_live_instance = fun _ -> true) ?scope ?(on_created = fun _ -> ()) ?artifact_store ?sampling_handler () =
  let* () = if String.trim instance_id = "" then Error (Invalid_package "instance_id must be non-blank")
    else Ok () in
  let* () = if Float.is_finite control_timeout_sec && control_timeout_sec > 0. then Ok ()
    else Error (Invalid_package "control_timeout_sec must be finite and positive") in
  let* () = validate_package package in
  let* () = match package.state_storage, state_owner with
    | Persistent, None -> Error (Invalid_package "persistent state requires a host-owned installation identity")
    | Ephemeral, Some _ -> Error (Invalid_package "package did not declare persistent state")
    | Persistent, Some _ | Ephemeral, None -> Ok () in
  let* _ = validate_exported_tools ~action_tool:package.action_tool package.exported_tools
    |> Result.map_error (fun detail -> Invalid_package detail) in
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
  let runtime = package.runtime in
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
  (* Resolve the image for this generation. Docker creates by this immutable
     ID; Apple verifies its resolved descriptor before starting the process. *)
  let* raw_image = run ~operation:"image inspect" (Engine.image_arguments runtime package.image) in
  let* image = Engine.image_of_inspect runtime raw_image
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
      (Engine.create_arguments package ~name ~instance_id ~state_owner:mine
         ~image:(Engine.image_create_reference image ~requested:package.image)
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
    let worker = { id; name; instance_id; package; image; artifact_store; input_history=Lane_addon_machine_history.create (); sampling_broker; action_schema = None; exported_tools = [];
                   tool_hooks = []; client = None; cleanup = worker_cleanup;
                   mutex = Eio.Mutex.create (); stopping = false; removed = false } in
    let result = try
      on_created worker;
      let* () = if worker.stopping then Error Stopped else Ok () in
      let* inspected = run ~operation:"inspect" (Engine.inspect_arguments runtime id) in
      let* inspected_id = Engine.verify_container runtime ~name ~resources:package.resources ~image inspected
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
            ~max_response_bytes:package.resources.max_reply_bytes ?sampling_handler ()
          |> Result.map_error protocol_error in
        Eio.Flow.close stderr_w;
        worker.client <- Some client;
        let* () = if worker.stopping then Error Stopped else Ok () in
        let* () = Agent_core.Mcp.initialize client |> Result.map_error protocol_error in
        let* tools = Agent_core.Mcp.list_tools_full client |> Result.map_error protocol_error in
        if not (List.exists (fun (tool : Mcp_protocol.Mcp_types.tool) ->
            String.equal tool.name "lane_observe") tools) then
          Error (Protocol_failed "package must advertise lane_observe in its initial tools/list page")
        else if worker.stopping then Error Stopped
        else
          let* () = match package.action_tool with
            | None -> Ok ()
            | Some name ->
                (match List.filter (fun (tool : Mcp_protocol.Mcp_types.tool) -> tool.name = name) tools with
                 | [tool] ->
                     let* () = Lane_addon_action.validate_schema tool.input_schema
                       |> Result.map_error (fun detail -> Protocol_failed detail) in
                     worker.action_schema <- Some tool.input_schema; Ok ()
                 | _ -> Error (Protocol_failed "package must advertise exactly one configured action tool")) in
          let* () = match package.tool_invocation with
            | Direct -> Ok ()
            | Host_context ->
                if package.action_tool = Some Lane_addon_call_context.tool_name then
                  Error (Invalid_package "caller-context control port cannot also be the action port")
                else match List.filter (fun (tool : Mcp_protocol.Mcp_types.tool) ->
                    String.equal tool.name Lane_addon_call_context.tool_name) tools with
                  | [_] -> Ok ()
                  | _ -> Error (Protocol_failed "package must advertise exactly one lane_call control tool") in
          let* () =
            if not (uses_host_requests package) then Ok ()
            else
              let advertised_once name =
                List.length (List.filter (fun (tool : Mcp_protocol.Mcp_types.tool) ->
                  String.equal tool.name name) tools) = 1 in
              if advertised_once host_requests_tool && advertised_once host_result_tool then Ok ()
              else Error (Protocol_failed
                "a package that declares exact outputs must advertise lane_host_requests and lane_host_result once each") in
          let* exported = List.fold_left (fun result name ->
            let* selected = result in
            match List.filter (fun (tool : Mcp_protocol.Mcp_types.tool) -> String.equal tool.name name) tools with
            | [tool] -> Ok (tool :: selected)
            | _ -> Error (Protocol_failed ("package must advertise exactly one exported tool: " ^ name)))
            (Ok []) package.exported_tools in
          let* tool_hooks = List.fold_left (fun result (tool : Mcp_protocol.Mcp_types.tool) ->
            let* checks = result in
            let* hooks = Lane_addon_tool_hooks.prepare ~hooks:package.tool_hooks tool
              |> Result.map_error (fun detail -> Protocol_failed detail) in
            Ok ((tool.name, hooks) :: checks)) (Ok []) exported in
          worker.tool_hooks <- tool_hooks;
          worker.exported_tools <- List.rev exported;
          Ok worker
      with
      | (Eio.Io _ | Unix.Unix_error _ | Sys_error _ | End_of_file | Failure _
        | Invalid_argument _) as exn -> Error (Protocol_failed (Printexc.to_string exn))
    in
    match result with
    | Ok _ -> result
    | Error error ->
        Option.iter Agent_core.Mcp.close worker.client;
        fail_start error
  end

let observe t ~binding ~sources =
  if t.stopping then Error Stopped
  (* Cancellation must remain possible during an unresponsive request. After
     cancellation this client is retired, so no future request can consume a
     response belonging to the cancelled call. *)
  else Eio.Mutex.use_ro t.mutex (fun () ->
    if t.stopping then Error Stopped
    else
      let read () =
      try
        let* client = match t.client with
          | Some client -> Ok client | None -> Error (Protocol_failed "worker initialization pending") in
        let* result = Agent_core.Mcp.call_tool_full client ~name:"lane_observe"
            ~arguments:(`Assoc ([ "binding", binding; "sources", sources ] @
              match t.package.action_tool with None -> []
              | Some _ -> ["context", Lane_addon_action.context t.instance_id]))
          |> Result.map_error (fun error -> Protocol_failed (Agent_core.Error.to_string error)) in
        if t.stopping then Error Stopped
        else match result.Mcp_protocol.Mcp_types.is_error with
          | Some true -> Error (Protocol_failed (Agent_core.Mcp.text_of_tool_result result))
          (* MCP permits omission of isError; only an explicit true reports
             tool failure. Structured observation validation remains required. *)
          | Some false | None ->
              match result.structured_content with
              | None -> Error (Invalid_observation "lane_observe must return structuredContent")
              | Some json ->
                  let* output = Eio_unix.run_in_systhread (fun () ->
                    Lane_addon_packet.decode ?store:t.artifact_store json)
                    |> Result.map_error (fun detail -> Invalid_observation detail) in
                  let has_history = List.exists (fun (row : row) -> List.mem_assoc "input_history" row.fields) output.rows in
                  if not has_history then Ok output else
                  let* store = match t.artifact_store with Some store -> Ok store
                    | None -> Error (Invalid_observation "machine history requires an owned artifact store") in
                  let* output = Lane_addon_machine_history.retain t.input_history ~store ~instance_id:t.instance_id
                    ~max_response_bytes:t.package.resources.max_reply_bytes
                    ~call:(fun ~name ~arguments ->
                      if t.stopping then Error "worker stopped during input history transfer"
                      else Agent_core.Mcp.call_tool_full client ~name ~arguments
                        |> Result.map_error Agent_core.Error.to_string) output
                    |> Result.map_error (fun detail -> Invalid_observation detail) in
                  if t.stopping then Error Stopped else Ok output
      with
      | Eio.Cancel.Cancelled _ as exn -> t.stopping <- true; raise exn
      | (Eio.Io _ | Unix.Unix_error _ | Sys_error _ | End_of_file | Failure _
        | Invalid_argument _) as exn ->
          if t.stopping then Error Stopped
          else Error (Protocol_failed (Printexc.to_string exn)) in
      match t.sampling_broker with
      | None -> read ()
      | Some broker -> Lane_addon_sampling.with_observation broker ~binding ~sources
          ~on_error:(fun detail -> Invalid_observation detail) read)

(* This call only reports transport success or the package's explicit outcome.
   Once dispatched, errors never establish that the environment was unchanged. *)
let act t ~arguments =
  if t.stopping then Error Stopped
  else Eio.Mutex.use_ro t.mutex (fun () ->
    if t.stopping then Error Stopped
    else try
      let* client = match t.client with Some client -> Ok client
        | None -> Error (Protocol_failed "worker initialization pending") in
      let* name, schema, store = match t.package.action_tool, t.action_schema, t.artifact_store with
        | Some name, Some schema, Some store -> Ok (name, schema, store)
        | _ -> Error (Protocol_failed "worker does not advertise an available action port") in
      let* arguments = Lane_addon_action.validate ~schema ~name arguments
        |> Result.map_error (fun detail -> Protocol_failed detail) in
      let* result = Agent_core.Mcp.call_tool_full client ~name ~arguments
        |> Result.map_error (fun error -> Protocol_failed (Agent_core.Error.to_string error)) in
      match result.Mcp_protocol.Mcp_types.is_error with
      | Some true -> Error (Protocol_failed (Agent_core.Mcp.text_of_tool_result result))
      | None | Some false ->
          (match result.structured_content with
           | None -> Error (Protocol_failed "action tool must return structuredContent")
           | Some json -> Eio_unix.run_in_systhread (fun () ->
               Lane_addon_action.decode_result ~store json)
               |> Result.map_error (fun detail -> Protocol_failed detail))
    with
    | Eio.Cancel.Cancelled _ as exn -> t.stopping <- true; raise exn
    | (Eio.Io _ | Unix.Unix_error _ | Sys_error _ | End_of_file | Failure _ | Invalid_argument _) as exn ->
        Error (Protocol_failed (Printexc.to_string exn)))

(* The host request tools answer the host only; no Keeper reaches them. Their
   answer is structured content, or the call failed. *)
let call_host_tool t ~name ~arguments =
  if t.stopping then Error Stopped
  else Eio.Mutex.use_ro t.mutex (fun () ->
    if t.stopping then Error Stopped
    else try
      let* client = match t.client with Some client -> Ok client
        | None -> Error (Protocol_failed "worker initialization pending") in
      let* result = Agent_core.Mcp.call_tool_full client ~name ~arguments
        |> Result.map_error (fun error -> Protocol_failed (Agent_core.Error.to_string error)) in
      match result.Mcp_protocol.Mcp_types.is_error with
      | Some true -> Error (Protocol_failed (Agent_core.Mcp.text_of_tool_result result))
      | None | Some false ->
          (match result.structured_content with
           | None -> Error (Protocol_failed (name ^ " must return structuredContent"))
           | Some json -> Ok json)
    with
    | Eio.Cancel.Cancelled _ as exn -> t.stopping <- true; raise exn
    | (Eio.Io _ | Unix.Unix_error _ | Sys_error _ | End_of_file | Failure _ | Invalid_argument _) as exn ->
        Error (Protocol_failed (Printexc.to_string exn)))

let host_requests t = call_host_tool t ~name:host_requests_tool ~arguments:(`Assoc [])
let host_result t ~arguments = call_host_tool t ~name:host_result_tool ~arguments

let call_exported_tool ?(on_result = fun _ -> ()) ?authorize ?(principal = Lane_addon_call_context.Anonymous) t ~name ~arguments =
  if t.stopping then Error Stopped
  else
      let* () = if List.exists (fun (tool : Mcp_protocol.Mcp_types.tool) ->
          String.equal tool.name name) t.exported_tools then Ok ()
        else Error (Protocol_failed "tool is not exported by this worker") in
      let* client = match t.client with Some client -> Ok client
        | None -> Error (Protocol_failed "worker initialization pending") in
      let* hooks = match List.assoc_opt name t.tool_hooks with
        | Some hooks -> Ok hooks
        | None -> Error (Protocol_failed "exported tool middleware is unavailable") in
      let* () = Lane_addon_tool_hooks.before_call hooks arguments
        |> Result.map_error (fun detail -> Host_refusal (Lane_addon_call_context.Rejected detail)) in
      let call ~name ~arguments =
        Eio.Mutex.use_ro t.mutex (fun () ->
          if t.stopping then Error "Add-on worker is stopped"
          else Agent_core.Mcp.call_tool_full client ~name ~arguments
            |> Result.map (fun result -> on_result result; result)
            |> Result.map_error Agent_core.Error.to_string) in
      try
        let* result = Lane_addon_worker_invocation.run ~invocation:t.package.tool_invocation
          ~authorize ~principal ~name ~arguments ~call
        |> Result.map_error (function
          | Lane_addon_call_context.Host_refusal refusal -> Host_refusal refusal
          | Transport_error detail -> Protocol_failed detail) in
        let* () = Lane_addon_tool_hooks.after_call hooks result
          |> Result.map_error (fun detail -> Protocol_failed ("tool result rejected after dispatch: " ^ detail)) in
        Ok result
      with
      | Eio.Cancel.Cancelled _ as exn -> t.stopping <- true; raise exn
      | (Eio.Io _ | Unix.Unix_error _ | Sys_error _ | End_of_file | Failure _ | Invalid_argument _) as exn ->
          Error (Protocol_failed (Printexc.to_string exn))
