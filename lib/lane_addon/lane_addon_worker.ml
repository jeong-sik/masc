open Lane_addon_types

type error =
  | Invalid_package of string
  | Docker_failed of { operation : string; detail : string }
  | Protocol_failed of string
  | Host_refusal of Lane_addon_call_context.host_refusal
  | Invalid_observation of string
  | Stopped

type mount = { source : string; destination : string }

type t = {
  id : string;
  name : string;
  instance_id : string;
  package : package;
  artifact_store : Lane_addon_store.t option;
  input_history : Lane_addon_machine_history.t;
  sampling_broker : Lane_addon_sampling.t option;
  mutable exported_tools : Mcp_protocol.Mcp_types.tool list;
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
  | Host_refusal (Lane_addon_call_context.Rejected detail | Unavailable detail | Activity_disabled detail | Activity_unobserved detail) -> detail
  | Protocol_failed detail -> "Add-on MCP failure: " ^ detail
  | Invalid_observation detail -> "invalid Add-on observation: " ^ detail
  | Stopped -> "Add-on worker is stopped"

let ( let* ) = Result.bind
let container_id t = t.id
let container_name t = t.name
let action_schema t = t.action_schema
let exported_tools t = if t.stopping then [] else t.exported_tools
let owned_name instance_id =
  "masc-lane-" ^ Digestif.SHA256.(to_hex (digest_string instance_id))
let valid_container_id id =
  String.length id = 64 && String.for_all (function
    | '0' .. '9' | 'a' .. 'f' -> true | _ -> false) id

exception Control_reply_too_large

(* Docker control output is host-run CLI output, not a package reply, so the
   manifest's reply bound does not apply. It is bounded like any other
   captured subprocess stream, because an image can add large labels to an
   inspect result. Package stdout goes through the MCP transport's own bound. *)
let control_output_max_bytes = Common.max_process_capture_head_bytes

(* This reader bounds both Docker control streams before retaining their
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

let run_control ~clock ~timeout_sec ~mgr ~docker_command ~operation args =
  let run () =
    try Eio.Switch.run (fun sw ->
      let stdout_r, stdout_w = Eio.Process.pipe ~sw mgr in
      let stderr_r, stderr_w = Eio.Process.pipe ~sw mgr in
      let child = Eio.Process.spawn ~sw mgr
          ~stdin:(Eio.Flow.string_source "")
          ~stdout:stdout_w ~stderr:stderr_w (docker_command :: args) in
      Eio.Flow.close stdout_w;
      Eio.Flow.close stderr_w;
      let stdout, stderr = Eio.Fiber.pair
          (fun () -> read_control stdout_r)
          (fun () -> read_control stderr_r) in
      match Eio.Process.await child with
      | `Exited 0 -> Ok stdout
      | `Exited code ->
          Error (Docker_failed { operation;
            detail = Printf.sprintf "exit %d: %s" code (String.trim stderr) })
      | `Signaled signal ->
          Error (Docker_failed { operation;
            detail = Printf.sprintf "signal %d: %s" signal (String.trim stderr) }))
    with
    | Control_reply_too_large ->
        Error (Docker_failed { operation; detail = "control response exceeds byte limit" })
    | (Eio.Io _ | Unix.Unix_error _ | Sys_error _) as exn ->
        Error (Docker_failed { operation; detail = Printexc.to_string exn })
  in
  match Eio.Time.with_timeout clock timeout_sec (fun () -> Ok (run ())) with
  | Ok result -> result
  | Error `Timeout ->
      Error (Docker_failed { operation;
        detail = Printf.sprintf "timed out after %.3g seconds" timeout_sec })

let inspect_image ~clock ~control_timeout_sec ~mgr ~(package : package)
    ?(docker_command="docker") () =
  if not (Float.is_finite control_timeout_sec) || control_timeout_sec <= 0. then
    Error (Invalid_package "control_timeout_sec must be finite and positive")
  else
  let* raw = run_control ~clock ~timeout_sec:control_timeout_sec ~mgr ~docker_command
      ~operation:"image inspect" ["image";"inspect";"--format";"{{.Id}}";package.image] in
  let digest = String.trim raw in
  if digest="" then Error (Docker_failed {operation="image inspect";detail="empty image identity"})
  else Ok digest

let mount_argument ({ source; destination } : mount) =
  if Filename.is_relative source || Filename.is_relative destination then
    Error (Invalid_package "mount source and destination must be absolute")
  else if String.contains source ',' || String.contains destination ',' then
    Error (Invalid_package "Docker mount paths cannot contain a comma")
  else if String.contains source '\000' || String.contains destination '\000' then
    Error (Invalid_package "mount paths cannot contain NUL")
  else Ok (Printf.sprintf "type=bind,src=%s,dst=%s,readonly" source destination)

let validate_package (package : package) =
  match Lane_addon_types.check_resources package.resources with
  | Error detail -> Error (Invalid_package detail)
  | Ok () ->
  if String.trim package.image = "" || package.command = [] then
    Error (Invalid_package "image and command are required")
  else if Filename.is_relative package.directory then
    Error (Invalid_package "package directory must be absolute")
  else Ok ()

let int64_json = function
  | `Int value -> Some (Int64.of_int value)
  | `Intlit value -> Int64.of_string_opt value
  | _ -> None

let verify_container ~name ~resources raw =
  let bad detail = Error (Docker_failed { operation = "inspect"; detail }) in
  try
    match Yojson.Safe.from_string raw with
    | `List [ `Assoc fields ] ->
        (match List.assoc_opt "Id" fields, List.assoc_opt "Name" fields,
               List.assoc_opt "HostConfig" fields with
         | Some (`String id), Some (`String actual_name), Some (`Assoc host)
           when String.length id = 64 && String.equal actual_name ("/" ^ name) ->
             let expected_cpus = Int64.of_float
                 (Float.round (resources.cpus *. 1_000_000_000.)) in
             let field key = Option.bind (List.assoc_opt key host) int64_json in
             if field "NanoCpus" <> Some expected_cpus
                || field "Memory" <> Some resources.memory_bytes
                || field "MemorySwap" <> Some resources.memory_bytes
                || field "PidsLimit" <> Some (Int64.of_int resources.pids)
             then bad "Docker did not apply requested CPU, memory, swap and PID limits"
             else Ok id
         | _ -> bad "container identity or resource settings are absent")
    | _ -> bad "expected one Docker container inspect result"
  with Yojson.Json_error detail -> bad detail

let verify_absent ~run id =
  (* A successful exact-ID list query distinguishes absence from an
     unreachable Docker daemon; an inspect error alone cannot do that. *)
  let* raw = run ~operation:"verify removal"
      [ "container"; "ls"; "--all"; "--no-trunc";
        "--filter"; "id=" ^ id; "--format"; "{{json .ID}}" ] in
  if String.trim raw = "" then Ok ()
  else Error (Docker_failed { operation = "verify removal";
    detail = "container remains visible after removal: " ^ id })

let find_named_container ~run name =
  let* raw = run ~operation:"resolve owned container"
      [ "container"; "ls"; "--all"; "--no-trunc";
        "--filter"; "name=^/" ^ name ^ "$"; "--format"; "{{json .ID}}" ] in
  if String.trim raw = "" then Ok None
  else
    try match Yojson.Safe.from_string raw with
      | `String id when valid_container_id id -> Ok (Some id)
      | _ -> Error (Docker_failed { operation = "resolve owned container";
          detail = "unexpected container identity" })
    with Yojson.Json_error detail ->
      Error (Docker_failed { operation = "resolve owned container"; detail })

let remove_container ~run id =
  (* rm --force is the explicit detach operation, not a Keeper timeout. It
     stops a non-cooperative package and removes only its exact container. *)
  let removal = run ~operation:"remove" [ "container"; "rm"; "--force"; "--volumes"; id ] in
  match verify_absent ~run id with
  | Ok () -> Ok ()
  | Error verify_error ->
      (match removal with Error error -> Error error | Ok _ -> Error verify_error)

let inspect_owned_container ~run ~instance_id ~name id =
  let* raw = run ~operation:"recover inspect" [ "container"; "inspect"; id ] in
  let refusal () = Error (Docker_failed { operation = "recover ownership";
    detail = "container identity and masc.lane.instance label must match the persisted binding" }) in
  try match Yojson.Safe.from_string raw with
    | `List [ `Assoc fields ] ->
        let name_matches = match name with
          | None -> true
          | Some expected -> List.assoc_opt "Name" fields = Some (`String ("/" ^ expected)) in
        (match List.assoc_opt "Id" fields, List.assoc_opt "Config" fields with
         | Some (`String actual_id), Some (`Assoc config)
           when String.equal id actual_id && name_matches ->
             (match List.assoc_opt "Labels" config with
              | Some (`Assoc labels) ->
                  (match List.assoc_opt "masc.lane.instance" labels with
                   | Some (`String owner) when String.equal owner instance_id -> Ok ()
                   | _ -> refusal ())
              | _ -> refusal ())
         | _ -> refusal ())
    | _ -> refusal ()
  with Yojson.Json_error detail ->
    Error (Docker_failed { operation = "recover ownership"; detail })

let recover_stop ~clock ~control_timeout_sec ~mgr ~instance_id ~container_id ?state_owner
    ?(docker_command = "docker") () =
  if not (Float.is_finite control_timeout_sec) || control_timeout_sec <= 0. then
    Error (Invalid_package "control_timeout_sec must be finite and positive")
  else if String.trim instance_id = "" then Error (Invalid_package "instance_id must be non-blank")
  else if Option.exists (fun id -> not (valid_container_id id)) container_id then
    Error (Docker_failed { operation = "recover ownership"; detail = "invalid container ID" })
  else
    let run = run_control ~clock ~timeout_sec:control_timeout_sec ~mgr ~docker_command in
    let* found, name = match container_id with
      | None ->
          let name = match state_owner with
            | None -> owned_name instance_id
            | Some owner -> Lane_addon_worker_state.container_name owner in
          let* id = find_named_container ~run name in
          Ok (id, Some name)
      | Some id ->
          let* visible = run ~operation:"recover existence"
              [ "container"; "ls"; "--all"; "--no-trunc";
                "--filter"; "id=" ^ id; "--format"; "{{json .ID}}" ] in
          Ok ((if String.trim visible = "" then None else Some id), None)
    in
    match found with
    | None -> Ok ()
    | Some id ->
        let* () = inspect_owned_container ~run ~instance_id ~name id in
        remove_container ~run id

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
    ?(docker_command = "docker") ?(on_created = fun _ -> ()) ?artifact_store ?sampling_handler () =
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
  let* package_mount = mount_argument
      { source = package.directory; destination = "/addon" } in
  let* mounted = List.fold_left (fun acc mount ->
      let* paths = acc in
      let* path = mount_argument mount in
      Ok (paths @ [ "--mount"; path ])) (Ok []) mounts in
  (* The binding is persisted before create. Its instance ID therefore also
     identifies a container when the process dies before receiving create's
     stdout or persisting [on_created]. Domain labels are checked before any
     recovered container is removed. *)
  let name = match state_owner with
            | None -> owned_name instance_id
            | Some owner -> Lane_addon_worker_state.container_name owner in
  let run = run_control ~clock ~timeout_sec:control_timeout_sec ~mgr ~docker_command in
  let* state_mount = match state_owner with
    | None -> Ok []
    | Some owner when not (Lane_addon_worker_state.belongs_to owner ~package_id:package.id) ->
        Error (Invalid_package "persistent state owner names a different package")
    | Some owner ->
        Lane_addon_worker_state.ensure owner
          ~run:(fun ~operation args -> run ~operation args |> Result.map_error error_to_string)
        |> Result.map (fun mount -> ["--mount"; mount])
        |> Result.map_error (fun detail -> Docker_failed {operation="persistent state";detail})
  in
  let identity = ref None in
  let cleanup_finished = ref false in
  let cleanup () =
    if !cleanup_finished then Ok ()
    else match !identity with
      | None ->
          (* create can take effect before its stdout is received. Verify the
             binding's deterministic name and label instead of removing an
             unverified name collision. *)
          let* () = recover_stop ~clock ~control_timeout_sec ~mgr ~instance_id ~container_id:None ?state_owner
              ~docker_command () in
          cleanup_finished := true;
          Ok ()
      | Some id ->
          let* () = remove_container ~run id in
          cleanup_finished := true;
          Ok ()
  in
  Eio.Switch.on_release sw (fun () ->
    Eio.Cancel.protect (fun () ->
      match cleanup () with
      | Ok () -> ()
      | Error error -> Eio.traceln "%s" (error_to_string error)));
  let fail_start error =
    match cleanup () with
    | Ok () -> Error error
    | Error cleanup_error ->
        Error (Docker_failed { operation = "failed attach cleanup";
          detail = error_to_string error ^ "; " ^ error_to_string cleanup_error })
  in
  let cpus = Printf.sprintf "%.9f" package.resources.cpus in
  let memory = Int64.to_string package.resources.memory_bytes in
  let* created = match run ~operation:"create"
      ([ "container"; "create"; "--pull"; "never";
         "--name"; name; "--label"; "masc.lane.instance=" ^ instance_id;
         "--cpus"; cpus; "--memory"; memory; "--memory-swap"; memory;
         "--pids-limit"; string_of_int package.resources.pids;
         "--network"; "none"; "--read-only"; "--cap-drop"; "ALL";
         "--security-opt"; "no-new-privileges"; "--log-driver"; "none";
         "--interactive"; "--workdir"; "/addon"; "--mount"; package_mount ]
       @ mounted @ state_mount @ [ "--"; package.image ] @ package.command) with
    | Ok value -> Ok value
    | Error error -> fail_start error
  in
  let id = String.trim created in
  if not (valid_container_id id) then
    fail_start (Docker_failed { operation = "create"; detail = "invalid container ID" })
  else begin
    identity := Some id;
    let stderr_source = ref None in
    let worker_cleanup () =
      let* () = cleanup () in
      Option.iter (fun source ->
        try Eio.Flow.close source with Eio.Io _ | Unix.Unix_error _ -> ()) !stderr_source;
      stderr_source := None;
      Ok () in
    let worker = { id; name; instance_id; package; artifact_store; input_history=Lane_addon_machine_history.create (); sampling_broker; action_schema = None; exported_tools = [];
                   client = None; cleanup = worker_cleanup;
                   mutex = Eio.Mutex.create (); stopping = false; removed = false } in
    let result = try
      on_created worker;
      let* () = if worker.stopping then Error Stopped else Ok () in
      let* inspected = run ~operation:"inspect" [ "container"; "inspect"; id ] in
      let* inspected_id = verify_container ~name ~resources:package.resources inspected in
      if not (String.equal inspected_id id) then
        Error (Docker_failed { operation = "inspect"; detail = "container ID changed" })
      else
        (* Package diagnostics have an OS-bounded pipe. They cannot flood the
           host log or allocate an unbounded buffer. A noisy package may block
           itself; the owner and other Add-ons do not share this pipe. *)
        let stderr_r, stderr_w = Eio.Process.pipe ~sw mgr in
        stderr_source := Some stderr_r;
        let protocol_error error = Protocol_failed (Agent_core.Error.to_string error) in
        let* client = Agent_core.Mcp.connect ~sw ~mgr ~command:docker_command
            ~args:[ "container"; "start"; "--attach"; "--interactive"; id ]
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
          let* exported = List.fold_left (fun result name ->
            let* selected = result in
            match List.filter (fun (tool : Mcp_protocol.Mcp_types.tool) -> String.equal tool.name name) tools with
            | [tool] -> Ok (tool :: selected)
            | _ -> Error (Protocol_failed ("package must advertise exactly one exported tool: " ^ name)))
            (Ok []) package.exported_tools in
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

let call_exported_tool ?(on_result = fun _ -> ()) ?authorize ?(principal = Lane_addon_call_context.Anonymous) t ~name ~arguments =
  if t.stopping then Error Stopped
  else
      let* () = if List.exists (fun (tool : Mcp_protocol.Mcp_types.tool) ->
          String.equal tool.name name) t.exported_tools then Ok ()
        else Error (Protocol_failed "tool is not exported by this worker") in
      let* client = match t.client with Some client -> Ok client
        | None -> Error (Protocol_failed "worker initialization pending") in
      let call ~name ~arguments =
        Eio.Mutex.use_ro t.mutex (fun () ->
          if t.stopping then Error "Add-on worker is stopped"
          else Agent_core.Mcp.call_tool_full client ~name ~arguments
            |> Result.map (fun result -> on_result result; result)
            |> Result.map_error Agent_core.Error.to_string) in
      try
        Lane_addon_worker_invocation.run ~invocation:t.package.tool_invocation
          ~authorize ~principal ~name ~arguments ~call
        |> Result.map_error (function
          | Lane_addon_call_context.Host_refusal refusal -> Host_refusal refusal
          | Transport_error detail -> Protocol_failed detail)
      with
      | Eio.Cancel.Cancelled _ as exn -> t.stopping <- true; raise exn
      | (Eio.Io _ | Unix.Unix_error _ | Sys_error _ | End_of_file | Failure _ | Invalid_argument _) as exn ->
          Error (Protocol_failed (Printexc.to_string exn))
