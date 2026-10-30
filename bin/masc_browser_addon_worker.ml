let () =
  let socket = ref None and incarnation = ref None and bound = ref None and backend = ref None and models = ref false
    and live_ego_command = ref None and live_ego_space = ref None and live_ego_space_id = ref None in
  Arg.parse [
    "--backend",Arg.String (fun value -> backend:=Some value),
      "The one browser source this worker serves: " ^ Browser_lane.Backend.expected;
    "--live-ego-command",Arg.String (fun value -> live_ego_command:=Some value),"Serve an ego lite task space with this ego-browser";
    "--live-ego-space",Arg.String (fun value -> live_ego_space:=Some value),"The ego lite task space to serve";
    "--live-ego-space-id",Arg.Int (fun value -> live_ego_space_id:=Some value),"An existing ego lite Space ID to resume exactly";
    "--models",Arg.Set models,"Attach the host-selected model request broker";
    "--socket",Arg.String (fun value -> socket:=Some value),"Host-selected private Unix socket";
    "--incarnation",Arg.String (fun value -> incarnation:=Some value),"Host-selected worker UUID";
    "--max-message-bytes",Arg.Int (fun value -> bound:=Some value),"Native installation reply bound"]
    (fun _ -> raise (Arg.Bad "unexpected positional argument")) "masc-browser-addon-worker";
  let socket_path,incarnation,max_message_bytes = match !socket,!incarnation,!bound with
    | Some path,Some id,Some bytes -> path,id,bytes
    | _ -> raise (Arg.Bad "--socket, --incarnation and --max-message-bytes are required") in
  let backend = match Option.map Browser_lane.Backend.of_wire !backend with
    | Some (Some backend) -> backend
    | Some None | None -> raise (Arg.Bad ("--backend is required, one of " ^ Browser_lane.Backend.expected)) in
  let ego_reference=match !live_ego_space,!live_ego_space_id with
    | Some name,None -> Some (Browser_configuration.Named_space name)
    | None,Some id -> Some (Browser_configuration.Existing_space id)
    | None,None -> None
    | Some _,Some _ -> raise (Arg.Bad "--live-ego-space and --live-ego-space-id are mutually exclusive") in
  let live_ego = match backend,!live_ego_command,ego_reference with
    | Browser_lane.Backend.Ego,Some command,Some space -> Some {Browser_configuration.command;space}
    | Browser_lane.Backend.Ego,_,_ -> raise (Arg.Bad "the ego source needs --live-ego-command and one Space reference")
    | Browser_lane.Backend.(Automation|Stagehand|Owned_firefox|External_host),None,None -> None
    | Browser_lane.Backend.(Automation|Stagehand|Owned_firefox|External_host),_,_ ->
      raise (Arg.Bad "--live-ego-command and the Space reference belong to the ego source") in
  (* The browsers that read upload copies and write downloads are the owned
     Gecko and ego lite; the other sources get neither broker. *)
  let transfers = match backend with
    | Browser_lane.Backend.(Automation|Ego) -> true
    | Browser_lane.Backend.(Stagehand|Owned_firefox|External_host) -> false in
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Eio.Switch.run (fun sw ->
    let owner = match Masc.Browser_addon_owner.create ~incarnation with
      | Ok owner -> owner | Error message -> raise (Arg.Bad message) in
    if transfers then (
      let uploads=Eio_unix.run_in_systhread (fun () ->
        Masc.Browser_addon_uploads.create ~directory:(Filename.dirname socket_path)) in
      match Result.bind uploads (Masc.Browser_addon_owner.attach_uploads owner) with
      | Ok () -> () | Error detail -> raise (Arg.Bad detail));
    Eio.Switch.on_release sw (fun () ->
      (* The owned source's scope has joined before this outer release.
         Cancellation may bypass the host's orderly Retire RPC; observe the same
         original backend and transfer cleanup here as well. *)
      match Masc.Browser_addon_owner.dispatch owner
        {Masc.Browser_addon_wire.incarnation;command=Retire} with
      | Receipt -> ()
      | Service_refusal {message;_} -> Printf.eprintf "browser cleanup unconfirmed: %s\n%!" message
      | Snapshot_result _|Model_reply _|Extension_reply _|Download_reply _|Poll_result _|Issue_result _ ->
          Printf.eprintf "browser cleanup returned no settlement receipt\n%!");
    if transfers then (
      let downloads=Eio_unix.run_in_systhread (fun () ->
        Masc.Browser_addon_downloads.create ~directory:(Filename.dirname socket_path)) in
      match Result.bind downloads (Masc.Browser_addon_owner.attach_downloads owner) with
      | Ok () -> () | Error detail -> raise (Arg.Bad detail));
    if !models then (
      let directory=Filename.dirname socket_path in
      let configuration=Eio_unix.run_in_systhread (fun () ->
        Masc.Browser_addon_models.load_configuration ~directory) in
      let queue=Result.bind configuration (fun configuration -> Masc.Browser_addon_models.create ~incarnation ~configuration) in
      match Result.bind queue (Masc.Browser_addon_owner.attach_models owner) with
      | Ok () -> () | Error detail -> raise (Arg.Bad detail));
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
    let directory=Filename.dirname socket_path in
    match backend,live_ego with
    | Browser_lane.Backend.Automation,_ -> Masc.Browser_addon_automation.run ~env ~owner ~directory serve
    | Browser_lane.Backend.Stagehand,_ -> Masc.Browser_addon_stagehand.run ~env ~owner ~directory serve
    | Browser_lane.Backend.Owned_firefox,_ -> Masc.Browser_addon_live_bidi.run ~env ~owner ~directory serve
    | Browser_lane.Backend.Ego,Some configuration ->
      Masc.Browser_addon_live_ego.run ~env ~owner
        ~downloads:(Masc.Browser_addon_downloads.downloads_directory ~directory) configuration serve
    | Browser_lane.Backend.Ego,None -> raise (Arg.Bad "the ego source needs its task space")
    | Browser_lane.Backend.External_host,_ -> serve ()))
