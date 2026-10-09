open Alcotest
(* Real SDK stdio worker under an attached Runtime installation. Only container
   creation is substituted; seat calls still cross discovery and lane_call. *)
let with_worker ~machine ~create ~clock ~sw ~base_path f =
  let module R = Masc.Lane_addon_runtime in
  let module Transport = Mcp_protocol_eio.Stdio_transport in
  let module Client = Mcp_protocol_eio.Generic_client.Make (Transport) in
  let module S = Mcp_protocol.Mcp_types in
  let unwrap = function Ok value -> value | Error message -> fail message in
  let config = Masc.Workspace.default_config base_path in
  let request_source, request_sink = Eio_unix.pipe sw in
  let response_source, response_sink = Eio_unix.pipe sw in
  let max_reply_bytes = 4194304 in
  let transport = Transport.create ~stdin:response_source ~stdout:request_sink ~max_size:max_reply_bytes () in
  let client = Client.create ~transport ~clock () in
  Eio.Fiber.first
    (fun () -> Mcp_protocol_eio.Server.run (create ~base_path ())
      ~stdin:request_source ~stdout:response_sink ~clock ())
    (fun () ->
      ignore (unwrap (Client.initialize client ~client_name:"machine-fixture" ~client_version:"1"));
      let tools = unwrap (Client.list_tools_all client) in
      let control_ports = ["lane_observe";Lane_addon_call_context.tool_name;
        Machine_controller_contract.snapshot_tool;Machine_controller_contract.release_tool;
        Machine_input_history.tool_name] in
      let names = List.filter_map (fun (tool : S.tool) ->
        if List.mem tool.name control_ports then None else Some tool.name) tools in
      let mutex = Eio.Mutex.create () in
      let rpc ~name ~arguments = Client.call_tool client ~name ~arguments () in
      let call name arguments = Eio.Mutex.use_ro mutex (fun () -> rpc ~name ~arguments) in
      let backend : R.For_testing.backend = {
        image_ready=(fun ~package:_ -> Ok ());
        recover_stop=(fun ~state_owner:_ ~instance_id:_ ~container_id:_ -> Ok ());
        acquire=(fun ~access:_ ~store:_ ~package:_ ~resolve_machine_output:_ ~resolve_lane_output:_ ~binding:_ -> Ok (`List []));
        start=(fun ~sw:_ ~state_owner:_ ~instance_id ~(package : Masc.Lane_addon_types.package) ~binding:_ ~on_created ->
          let store = Masc.Lane_addon_store.create
            ~root:(Filename.concat (Masc.Workspace.masc_dir config) "lane-addons") in
          let history = Masc.Lane_addon_machine_history.create () in
          let connection : R.For_testing.connection = {
            container_id=instance_id;
            exported_tools=(fun () -> List.filter (fun (tool : S.tool) ->
              List.mem tool.name package.exported_tools) tools);
            call_exported_tool=(fun ~on_result ~authorize ~principal ~name ~arguments ->
              Masc.Lane_addon_worker_invocation.run ~invocation:package.tool_invocation
                ~authorize ~principal ~name ~arguments
                ~call:(fun ~name ~arguments -> Eio.Mutex.use_ro mutex (fun () ->
                  rpc ~name ~arguments |> Result.map (fun result -> on_result result;result))));
            observe=(fun ~binding ~sources -> Eio.Mutex.use_ro mutex (fun () ->
              let ( let* ) = Result.bind in
              let* result = rpc ~name:"lane_observe" ~arguments:(`Assoc ["binding",binding;"sources",sources]) in
              let* () = if result.is_error=Some true then Error (Agent_core.Mcp.text_of_tool_result result) else Ok () in
              let* output = match result.structured_content with
                | Some packet -> Eio_unix.run_in_systhread (fun () -> Masc.Lane_addon_packet.decode ~store packet)
                | None -> Error "worker omitted observation packet" in
              Masc.Lane_addon_machine_history.retain history ~store ~instance_id
                ~max_response_bytes:package.resources.max_reply_bytes ~call:rpc output));
            action_schema=(fun () -> None);
            act=(fun ~arguments:_ -> Error "no fixture action port");
            stop=(fun () -> Ok ())
          } in
          on_created connection; Ok connection)
      } in
      R.For_testing.with_backend backend (fun () ->
        let manifest = Filename.concat base_path (machine ^ "-fixture.toml") in
        Out_channel.with_open_bin manifest (fun channel -> output_string channel (Printf.sprintf {|id = "%s-fixture"
revision = "fixture-1"
title = "Machine fixture"
image = "fixture/%s"
command = ["worker"]
contributions = ["observe"]
[world.tools]
invocation = "host_context"
export = [%s]
[resources]
cpus = 1.0
memory_bytes = 536870912
pids = 32
max_reply_bytes = %d
|} machine machine (String.concat "," (List.map (Printf.sprintf "%S") names)) max_reply_bytes));
        let attached = R.dispatch ~access:Masc.Lane_addon_sources.Operator_configuration ~config
          ~operation:R.Attach (`Assoc ["manifest_path",`String manifest;
            "run_id",`String "seat";"binding",`Assoc ["sources",`List []]])
          |> Result.map_error R.error_to_string |> unwrap in
        let id = Yojson.Safe.Util.(attached |> member "instance_id" |> to_string) in
        let rec ready () =
          match R.tool_exports ~config ~access:Masc.Lane_addon_sources.Unauthenticated ~reserved:[] with
          | Ok exports when List.length exports = List.length names -> () | _ -> Eio.Time.sleep clock 0.001; ready () in
        ready ();
        let invoke ~principal ~controller ~name ~arguments =
          call Lane_addon_call_context.tool_name
            (Lane_addon_call_context.to_json_with_controller ~controller ~principal ~tool:name ~arguments) in
        let detach () = ignore (R.dispatch ~access:Masc.Lane_addon_sources.Operator_configuration
          ~config ~operation:R.Detach (`Assoc ["instance_id",`String id])
          |> Result.map_error R.error_to_string |> unwrap) in
        f ~invoke ~detach))


let with_dos ~clock ~sw ~base_path f =
  with_worker ~machine:"dos" ~create:Dos_addon_worker.create ~clock ~sw ~base_path f

let with_msx ~clock ~sw ~base_path f =
  with_worker ~machine:"msx" ~create:Msx_addon_worker.create ~clock ~sw ~base_path
    (fun ~invoke ~detach ->
      f ~invoke:(fun ~principal ~name ~arguments -> invoke ~principal ~controller:None ~name ~arguments) ~detach)
