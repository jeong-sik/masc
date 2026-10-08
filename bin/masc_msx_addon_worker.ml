let () =
  let base_path = ref None in
  Arg.parse ["--base-path", Arg.String (fun path -> base_path := Some path),
    "Worker-owned persistent workspace root"]
    (fun _ -> raise (Arg.Bad "unexpected positional argument"))
    "masc-msx-addon-worker --base-path /state";
  let base_path = match !base_path with
    | Some path when not (Filename.is_relative path) -> path
    | _ -> raise (Arg.Bad "--base-path must name an absolute worker-owned directory") in
  Eio_main.run (fun env ->
    Msx_lane.install_activity_observer (Some (fun () -> Machine_configuration.Enabled));
    Fun.protect ~finally:(fun () -> Msx_lane.install_activity_observer None) (fun () ->
      Mcp_protocol_eio.Server.run (Msx_addon_worker.create ~base_path ())
        ~stdin:(Eio.Stdenv.stdin env) ~stdout:(Eio.Stdenv.stdout env)
        ~clock:(Eio.Stdenv.clock env) ()))
