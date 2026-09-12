open Lane_addon_types

type error =
  | Invalid_package of string
  | Docker_failed of { operation : string; detail : string }
  | Protocol_failed of string
  | Invalid_observation of string
  | Stopped

type mount = { source : string; destination : string }

type t = {
  id : string;
  name : string;
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
  | Protocol_failed detail -> "Add-on MCP failure: " ^ detail
  | Invalid_observation detail -> "invalid Add-on observation: " ^ detail
  | Stopped -> "Add-on worker is stopped"

let ( let* ) = Result.bind
let container_id t = t.id
let container_name t = t.name
let owned_name instance_id =
  "masc-lane-" ^ Digestif.SHA256.(to_hex (digest_string instance_id))
let valid_container_id id =
  String.length id = 64 && String.for_all (function
    | '0' .. '9' | 'a' .. 'f' -> true | _ -> false) id

exception Control_reply_too_large

(* This reader bounds both Docker control streams before retaining their
   contents. Package stdout goes through the MCP transport's own bound. *)
let read_control ~max_bytes flow =
  let buffer = Buffer.create (min max_bytes 4096) in
  let chunk = Cstruct.create (min max_bytes 4096) in
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

let run_control ~mgr ~docker_command ~max_bytes ~operation args =
  try
    Eio.Switch.run (fun sw ->
      let stdout_r, stdout_w = Eio.Process.pipe ~sw mgr in
      let stderr_r, stderr_w = Eio.Process.pipe ~sw mgr in
      let child = Eio.Process.spawn ~sw mgr
          ~stdin:(Eio.Flow.string_source "")
          ~stdout:stdout_w ~stderr:stderr_w (docker_command :: args) in
      Eio.Flow.close stdout_w;
      Eio.Flow.close stderr_w;
      let stdout, stderr = Eio.Fiber.pair
          (fun () -> read_control ~max_bytes stdout_r)
          (fun () -> read_control ~max_bytes stderr_r) in
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

let mount_argument ({ source; destination } : mount) =
  if Filename.is_relative source || Filename.is_relative destination then
    Error (Invalid_package "mount source and destination must be absolute")
  else if String.contains source ',' || String.contains destination ',' then
    Error (Invalid_package "Docker mount paths cannot contain a comma")
  else if String.contains source '\000' || String.contains destination '\000' then
    Error (Invalid_package "mount paths cannot contain NUL")
  else Ok (Printf.sprintf "type=bind,src=%s,dst=%s,readonly" source destination)

let validate_package (package : package) =
  let resources = package.resources in
  if not (Float.is_finite resources.cpus) || resources.cpus <= 0. then
    Error (Invalid_package "cpus must be finite and positive")
  else if resources.cpus *. 1_000_000_000. < 1. then
    Error (Invalid_package "cpus must be representable as a positive Docker NanoCpus value")
  else if resources.cpus *. 1_000_000_000. >= Int64.to_float Int64.max_int then
    Error (Invalid_package "cpus exceed Docker NanoCpus representation")
  else if resources.memory_bytes <= 0L || resources.pids <= 0
          || resources.max_reply_bytes <= 0 then
    Error (Invalid_package "memory_bytes, pids and max_reply_bytes must be positive")
  else if String.trim package.image = "" || package.command = [] then
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

let recover_stop ~mgr ~instance_id ~container_id ~max_reply_bytes
    ?(docker_command = "docker") () =
  if max_reply_bytes <= 0 then Error (Invalid_package "max_reply_bytes must be positive")
  else if String.trim instance_id = "" then Error (Invalid_package "instance_id must be non-blank")
  else if Option.exists (fun id -> not (valid_container_id id)) container_id then
    Error (Docker_failed { operation = "recover ownership"; detail = "invalid container ID" })
  else
    let run = run_control ~mgr ~docker_command ~max_bytes:max_reply_bytes in
    let* found, name = match container_id with
      | None ->
          let name = owned_name instance_id in
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

let start ~sw ~mgr ~instance_id ~(package : package) ?(mounts = [])
    ?(docker_command = "docker") ?(on_created = fun _ -> ()) () =
  let* () = if String.trim instance_id = "" then Error (Invalid_package "instance_id must be non-blank")
    else Ok () in
  let* () = validate_package package in
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
  let name = owned_name instance_id in
  let run = run_control ~mgr ~docker_command
      ~max_bytes:package.resources.max_reply_bytes in
  let identity = ref None in
  let cleanup_finished = ref false in
  let cleanup () =
    if !cleanup_finished then Ok ()
    else match !identity with
      | None ->
          (* create can take effect before its stdout is received (or exceed
             a tiny reply limit). Verify the binding's deterministic name
             and label instead of removing an unverified name collision. *)
          let* () = recover_stop ~mgr ~instance_id ~container_id:None
              ~max_reply_bytes:package.resources.max_reply_bytes ~docker_command () in
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
       @ mounted @ [ "--"; package.image ] @ package.command) with
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
    let worker = { id; name; client = None; cleanup = worker_cleanup;
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
            ~max_response_bytes:package.resources.max_reply_bytes ()
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
        else Ok worker
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
      try
        let* client = match t.client with
          | Some client -> Ok client | None -> Error (Protocol_failed "worker initialization pending") in
        let* result = Agent_core.Mcp.call_tool_full client ~name:"lane_observe"
            ~arguments:(`Assoc [ "binding", binding; "sources", sources ])
          |> Result.map_error (fun error -> Protocol_failed (Agent_core.Error.to_string error)) in
        if t.stopping then Error Stopped
        else match result.Mcp_protocol.Mcp_types.is_error with
          | Some true -> Error (Protocol_failed (Agent_core.Mcp.text_of_tool_result result))
          (* MCP permits omission of isError; only an explicit true reports
             tool failure. Structured observation validation remains required. *)
          | Some false | None ->
              match result.structured_content with
              | None -> Error (Invalid_observation "lane_observe must return structuredContent")
              | Some json -> output_of_json json |> Result.map_error (fun detail -> Invalid_observation detail)
      with
      | Eio.Cancel.Cancelled _ as exn -> t.stopping <- true; raise exn
      | (Eio.Io _ | Unix.Unix_error _ | Sys_error _ | End_of_file | Failure _
        | Invalid_argument _) as exn ->
          if t.stopping then Error Stopped
          else Error (Protocol_failed (Printexc.to_string exn)))
