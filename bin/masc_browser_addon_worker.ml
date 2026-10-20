let () =
  let socket = ref None and incarnation = ref None and bound = ref None and automation = ref false in
  Arg.parse [
    "--automation",Arg.Set automation,"Start the host-selected owned Gecko backend";
    "--socket",Arg.String (fun value -> socket:=Some value),"Host-selected private Unix socket";
    "--incarnation",Arg.String (fun value -> incarnation:=Some value),"Host-selected worker UUID";
    "--max-message-bytes",Arg.Int (fun value -> bound:=Some value),"Native installation reply bound"]
    (fun _ -> raise (Arg.Bad "unexpected positional argument")) "masc-browser-addon-worker";
  let socket_path,incarnation,max_message_bytes = match !socket,!incarnation,!bound with
    | Some path,Some id,Some bytes -> path,id,bytes
    | _ -> raise (Arg.Bad "--socket, --incarnation and --max-message-bytes are required") in
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Eio.Switch.run (fun sw ->
    let owner = match Masc.Browser_addon_owner.create ~incarnation with
      | Ok owner -> owner | Error message -> raise (Arg.Bad message) in
    let revoke () = Masc.Browser_addon_owner.revoke owner in
    Eio.Switch.on_release sw revoke;
    let stopping = Atomic.make false and wake = Eio.Condition.create () in
    List.iter (fun signal ->
      let previous = Sys.signal signal (Sys.Signal_handle (fun _ ->
        Atomic.set stopping true; Eio.Condition.broadcast wake)) in
      Eio.Switch.on_release sw (fun () -> Sys.set_signal signal previous)) [Sys.sigint;Sys.sigterm];
    let until_stop () =
      match Eio.Fiber.first
        (fun () -> Mcp_protocol_eio.Server.run (Masc.Browser_addon_service.mcp owner)
          ~stdin:(Eio.Stdenv.stdin env) ~stdout:(Eio.Stdenv.stdout env)
          ~clock:(Eio.Stdenv.clock env) ())
        (fun () -> Eio.Condition.loop_no_mutex wake (fun () ->
          if Atomic.get stopping then Some () else None)) with
      | () -> revoke ()
      | exception exn -> Eio.Cancel.protect revoke; raise exn in
    let serve () = Eio.Fiber.first
      (fun () -> Masc.Browser_addon_service.serve ~net:(Eio.Stdenv.net env) ~owner
        ~socket_path ~max_message_bytes)
      until_stop in
    if !automation then Masc.Browser_addon_automation.run ~env ~owner
      ~directory:(Filename.dirname socket_path) serve else serve ()))
