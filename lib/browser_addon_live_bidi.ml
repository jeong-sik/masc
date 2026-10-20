module B = Browser_lane
module W = Browser_addon_wire
module Peer = Browser_bidi_peer
module Lease = Native_addon_lease
type identity = { device:int; inode:int }
type validation_phase = Idle | Validating
type configuration = { firefox:string; profile:string; port:int; launcher:string;
  guardian:string; claim_directory:string; root:identity; slot:identity;
  gate:identity; lease:identity }
let ( let* ) = Result.bind
let protect work = try work () with
  | (Unix.Unix_error _ | Sys_error _ | Yojson.Json_error _) as exn -> Error (Printexc.to_string exn)
let lease result = Result.map_error Lease.error_to_string result
let absolute path = path<>"" && not (Filename.is_relative path) && not (String.contains path '\000')
let shared_slot profile = Filename.concat profile ".masc-firefox-profile-claim"
let identity ~directory path =
  let stat=Unix.lstat path in
  if stat.Unix.st_kind=(if directory then Unix.S_DIR else Unix.S_REG)
     && stat.st_uid=Unix.geteuid () && stat.st_perm=(if directory then 0o700 else 0o600)
     && (directory || stat.st_nlink=1)
  then Ok {device=stat.st_dev;inode=stat.st_ino}
  else Error "Firefox profile claim is not private and host-owned"
let verify c = protect (fun () ->
  let* ()=if Unix.realpath c.profile=c.profile then Ok () else Error "Firefox profile canonical path changed" in
  List.fold_left (fun result (path,directory,expected) -> let* ()=result in
    let* actual=identity ~directory path in
    if actual=expected then Ok () else Error "Firefox profile or stable claim inode changed") (Ok ())
    [c.profile,true,c.root;shared_slot c.profile,true,c.slot;
     Filename.concat (shared_slot c.profile) "gate",false,c.gate;
     Filename.concat (shared_slot c.profile) "lease",false,c.lease])
let configuration ~(browser:Browser_configuration.live_bidi) ~launcher ~guardian ~claim_directory = protect (fun () ->
  let* ()=if List.for_all absolute [browser.firefox;browser.profile;launcher;guardian;claim_directory]
    && browser.port>0 && browser.port<=65535 then Ok () else Error "invalid owned Firefox resources" in
  let profile=Unix.realpath browser.profile in
  let* root=identity ~directory:true profile in
  let slot_path=shared_slot profile in
  (try Unix.mkdir slot_path 0o700 with Unix.Unix_error (Unix.EEXIST,_,_) -> ());
  let* slot=identity ~directory:true slot_path in
  let* _=lease (Lease.recover_preparation ~directory:slot_path) in
  let* gate=identity ~directory:false (Filename.concat slot_path "gate") in
  let* claim_lease=identity ~directory:false (Filename.concat slot_path "lease") in
  let c={firefox=browser.firefox;profile;port=browser.port;launcher;guardian;claim_directory;
    root;slot;gate;lease=claim_lease} in
  let* ()=verify c in Ok c)
let claim_directories c = [c.claim_directory;shared_slot c.profile]
let id_json id = `Assoc ["device",`Int id.device;"inode",`Int id.inode]
let configuration_to_json c = `Assoc ["firefox",`String c.firefox;"profile",`String c.profile;
  "port",`Int c.port;"launcher",`String c.launcher;"guardian",`String c.guardian;
  "claim_directory",`String c.claim_directory;"root",id_json c.root;"slot",id_json c.slot;
  "gate",id_json c.gate;"lease",id_json c.lease]
let configuration_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=
      ["claim_directory";"firefox";"gate";"guardian";"launcher";"lease";"port";"profile";"root";"slot"] ->
    let path name=match List.assoc name fields with
      | `String path when absolute path -> Ok path | _ -> Error "invalid owned Firefox path" in
    let read name=match List.assoc name fields with
      | `Assoc pair when List.sort String.compare (List.map fst pair)=["device";"inode"] ->
        (match List.assoc "device" pair,List.assoc "inode" pair with
         | `Int device,`Int inode -> Ok {device;inode} | _ -> Error "invalid Firefox resource identity")
      | _ -> Error "invalid Firefox resource identity" in
    let* firefox=path "firefox" in let* profile=path "profile" in let* launcher=path "launcher" in
    let* guardian=path "guardian" in let* claim_directory=path "claim_directory" in
    let* port=match List.assoc "port" fields with `Int port when port>0 && port<=65535 -> Ok port
      | _ -> Error "invalid Firefox port" in
    let* root=read "root" in let* slot=read "slot" in let* gate=read "gate" in let* lease=read "lease" in
    Ok {firefox;profile;port;launcher;guardian;claim_directory;root;slot;gate;lease}
  | _ -> Error "invalid owned Firefox configuration"
let context c ~incarnation ~directory = `Assoc ["kind",`String "browser_addon_live_bidi";
  "incarnation",`String incarnation;"directory",`String directory;"profile",`String c.profile;
  "root",id_json c.root]
let original c ~incarnation ~directory = protect (fun () ->
  match Unix.lstat c.claim_directory with
  | _ ->
    let* prepared=lease (Lease.recover_preparation ~directory:c.claim_directory) in
    (match prepared with Lease.Unpublished -> Ok None | Current claim ->
      let* saved=lease (Lease.cleanup_context claim) in
      if saved=Some (context c ~incarnation ~directory) then Ok (Some claim)
      else Error "Firefox child claim belongs to another allocation")
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok None)
let settled claim =
  let* status=lease (Lease.status claim) in
  match status with Lease.Settled -> Ok ()
  | Awaiting_exec | Live _ | Cleanup_pending _ -> Error "original Firefox owner has not settled"
let settle c ~incarnation ~directory =
  let* claim=original c ~incarnation ~directory in
  match claim with None -> Ok () | Some claim -> let* ()=lease (Lease.request_termination claim) in settled claim
let cleanup = settle
let original_browser ~admission ~(receipt:Browser_process_owner.ready) =
  let* status=lease (Lease.status admission) in
  match status with
  | Lease.Live process when process.pid=receipt.owner_pid && process.instance_id=receipt.instance_id
      && Lease.instance_id admission=receipt.instance_id ->
    Browser_process_owner.verify_child receipt |> Result.map_error Browser_process_owner.error_to_string
  | Awaiting_exec | Live _ | Cleanup_pending _ | Settled -> Error "Firefox lost its original native owner"
let free_port c = protect (fun () ->
  let fd=Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    Unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback,c.port));Ok ()))
(* Firefox 157.0.1 opened a fresh profile's port in 0.67–0.85 s. A visible
   window, existing history and cold disk need a larger bootstrap allowance.
   This bounds startup I/O, never admitted page or model work. *)
let firefox_ready_timeout_s = 30.
let ready ~env ~process ~port =
  let clock=Eio.Stdenv.clock env in
  let rec poll () =
    let available=Eio.Switch.run (fun sw ->
      match Eio.Net.connect ~sw (Eio.Stdenv.net env) (`Tcp (Eio.Net.Ipaddr.V4.loopback,port)) with
      | flow -> Eio.Flow.close flow;true
      | exception Eio.Io (Eio.Net.E (Eio.Net.Connection_failure (Eio.Net.Refused _)),_) -> false) in
    if available then Ok () else (Eio.Time.sleep clock 0.1;poll ()) in
  Eio.Fiber.first
    (fun () -> match Eio.Time.with_timeout clock firefox_ready_timeout_s (fun () -> Ok (poll ())) with
      | Ok result -> result | Error `Timeout -> Error "owned Firefox did not open its debugging port")
    (fun () -> ignore (Eio.Process.await process);Error "original Firefox owner exited before readiness")
let fields = function `Assoc fields -> Ok fields | _ -> Error "invalid owned BiDi command"
let decode (issued:B.issued) =
  let* fields=fields issued.verb_json in
  let* ()=if List.for_all (fun (name,_) -> List.mem name ["verb";"args";"actor"]) fields
      && List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields))
    then Ok () else Error "invalid owned BiDi command fields" in
  let* verb=match List.assoc_opt "verb" fields with Some (`String name) ->
      Option.to_result ~none:"unsupported owned BiDi verb" (Peer.verb_of_wire name)
    | None|Some _ -> Error "missing owned BiDi verb" in
  let* args=match List.assoc_opt "args" fields with Some (`Assoc _ as args) -> Ok args
    | None|Some _ -> Error "invalid owned BiDi arguments" in
  let* actor=match List.assoc_opt "actor" fields with None -> Ok None
    | Some (`String actor) when String.trim actor<>"" -> Ok (Some actor)
    | Some _ -> Error "invalid owned BiDi actor" in
  Ok (verb,args,actor)
let payload = function
  | Ok data -> `Assoc ["ok",`Bool true;"data",data]
  | Error (Peer.Before_effect detail) -> `Assoc ["ok",`Bool false;"error",`String detail;"effectPhase",`String "not_started"]
  | Error (Peer.Partial_failure {tab_id;message}) -> `Assoc ["ok",`Bool false;"error",`String message;
      "effectPhase",`String "partial";"data",`Assoc ["action",`String "open_tab";"created",`Bool true;"tabId",`Int tab_id]]
  | Error (Peer.Outcome_unknown detail) -> `Assoc ["ok",`Bool false;"error",`String detail]
let accepted = function
  | W.Receipt -> Ok ()
  | W.Service_refusal {message;_} -> Error message
  | Snapshot_result _|Model_reply _|Download_reply _|Poll_result _|Issue_result _ -> Error "unexpected owned BiDi receipt"
let run_with ~before_command_validation ~env ~owner ~directory work =
  let c=match Eio_unix.run_in_systhread (fun () ->
    let* text=Fs_compat.load_owned_regular_file ~ownership_root:directory (Filename.concat directory "live-bidi.json")
      |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string in
    let* text=Option.to_result ~none:"missing owned Firefox configuration" text in
    protect (fun () -> configuration_of_json (Yojson.Safe.from_string text))) with
    | Ok c -> c | Error detail -> invalid_arg detail in
  let incarnation=Browser_addon_owner.incarnation owner in
  let dispatch command=Browser_addon_owner.dispatch owner {W.incarnation;command} in
  let startup,started=Eio.Promise.create () and stopping,stop=Eio.Promise.create ()
      and stopped,finish=Eio.Promise.create () in
  Eio.Switch.run (fun lifetime ->
    Eio.Switch.check lifetime;
    Eio.Fiber.fork ~sw:lifetime (fun () ->
      let outcome=try Eio.Switch.run (fun sw ->
        let* admission,child_admission=Eio_unix.run_in_systhread (fun () ->
          let* ()=verify c in let* ()=free_port c in
          let* ()=settle c ~incarnation ~directory in
          let id=Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())) in
          let* admission=lease (Lease.prepare ~directories:(claim_directories c) ~instance_id:id
            ~cleanup_context:(Some (context c ~incarnation ~directory))) in
          let* child=lease (Lease.reopen ~directories:[c.claim_directory] ~instance_id:id) in
          Ok (admission,child)) in
        let process=ref None and input=ref None and validation=ref Idle in
        let abort_requested,request_abort=Eio.Promise.create () in
        let signal_original () =
          Option.iter (fun child -> Eio.Process.signal child Sys.sigterm) !process;
          Option.iter Eio.Flow.close !input;input:=None in
        let request_shutdown () =
          ignore (Eio.Promise.try_resolve stop ());
          match !validation with Idle -> ()
          | Validating -> ignore (Eio.Promise.try_resolve request_abort ()) in
        let request_stop () =
          ignore (Eio.Promise.try_resolve request_abort ());
          signal_original ();
          let result=Eio_unix.run_in_systhread (fun () -> lease (Lease.retire child_admission)) in
          result in
        let abort () = Eio.Cancel.protect (fun () ->
          let retirement=request_stop () in
          Option.iter (fun child -> ignore (Eio.Process.await child)) !process;
          let* ()=retirement in Eio_unix.run_in_systhread (fun () -> settled child_admission)) in
        Eio.Switch.on_release sw (fun () -> ignore (request_stop ()));
        let start () =
          let output=Eio.Path.open_out ~sw ~append:true ~create:(`If_missing 0o600)
            Eio.Path.(Eio.Stdenv.fs env / Filename.concat directory "live-firefox.log") in
          let keep_read,keep_write=Eio_unix.pipe sw and ready_read,ready_write=Eio_unix.pipe sw in
          input:=Some keep_write;
          let id=Lease.instance_id admission in
          let argv=[c.launcher;"--instance";id] @ List.concat_map (fun path -> ["--slot";path]) (claim_directories c)
            @ ["--";c.guardian;"--instance";id;"--";c.firefox;"--no-remote";"--profile";c.profile;
               "--remote-debugging-port";string_of_int c.port] in
          Eio.Switch.check sw;
          let child=Eio.Process.spawn ~sw
            (Posix_spawn_process_mgr.foreground_mgr ~clock:(Eio.Stdenv.clock env) ~grace_seconds:5.)
            ~stdin:keep_read ~stdout:ready_write ~stderr:output argv in
          process:=Some child;Eio.Flow.close keep_read;Eio.Flow.close ready_write;
          (* The original process can be stopped while a separate status
             systhread waits on a native gate. Cancellation of a command waits
             for that thread; this sibling never needs the gate or RPC mutex. *)
          Eio.Switch.check sw;
          Eio.Fiber.fork_daemon ~sw (fun () ->
            Fun.protect ~finally:signal_original (fun () ->
              Eio.Fiber.first
                (fun () -> Eio.Promise.await abort_requested)
                (fun () -> Eio.Promise.await stopping;
                  match !validation with Validating -> ()
                    | Idle -> Eio.Promise.await abort_requested);
              `Stop_daemon));
          let* receipt=Eio.Fiber.first
            (fun () -> let reader=Eio.Buf_read.of_flow ready_read ~max_size:1024 in
              match Eio.Buf_read.line reader with
              | line -> protect (fun () -> Browser_process_owner.ready_of_json (Yojson.Safe.from_string line))
              | exception End_of_file -> Error "Firefox owner ended without bootstrap")
            (fun () -> ignore (Eio.Process.await child);Error "Firefox owner exited before bootstrap") in
          let* ()=if receipt.owner_pid=Eio.Process.pid child && receipt.instance_id=id then Ok ()
            else Error "Firefox bootstrap names another original owner" in
          Eio.Flow.close ready_read;
          let check ?(before=(fun () -> ())) ()=
            if Eio.Promise.is_resolved stopping then Error "owned Firefox is retiring"
            else (
              validation:=Validating;
              Fun.protect ~finally:(fun () -> validation:=Idle) (fun () ->
                before ();
                let* ()=Eio_unix.run_in_systhread (fun () ->
                  let* ()=original_browser ~admission ~receipt in verify c) in
                if Eio.Promise.is_resolved stopping then Error "owned Firefox retired during validation"
                else Ok ())) in
          let* ()=check () in let* ()=ready ~env ~process:child ~port:c.port in
          Peer.with_connection ~env ~timeout:B.default_timeout_sec
            ~url:(Printf.sprintf "ws://127.0.0.1:%d/session" c.port) (fun ~ended peer ->
            let session () =
              let* ()=check () in
              let* version=Peer.metadata peer |> Result.map_error Peer.session_failure_message in
              let* ()=Peer.runs_profile peer ~expected:c.profile
                |> Result.map_error (Peer.profile_refusal_message ~expected:c.profile) in
              let* ()=if Peer.process_id peer=Some receipt.child_pid then Ok ()
                else Error "BiDi endpoint belongs to another Firefox process" in
              let* ()=check () in Ok version in
            match session () with
            | Error detail -> ignore (Peer.end_session peer);Error detail
            | Ok version ->
              let client_id=Uuidm.v4_gen (Random.State.make_self_init ()) () in
              let client={B.client_id;browser=B.Firefox;version;engine_version=version;transport=B.Webdriver_bidi} in
              let poll window_sec=match dispatch (W.Poll {client;window_sec}) with
                | W.Poll_result {command;_} -> Ok command
                | Service_refusal {message;_} ->
                  if Browser_addon_owner.is_retired owner then Ok None else Error message
                | Snapshot_result _|Model_reply _|Download_reply _|Receipt|Issue_result _ -> Error "unexpected owned BiDi poll" in
              let* first=poll 0. in
              let* ()=if Option.is_none first then Ok () else Error "owned BiDi received input before attachment" in
              let* ()=Browser_addon_owner.attach_live owner ~client_id ~cleanup:(fun () ->
                request_shutdown ();Eio.Promise.await stopped) in
              ignore (Eio.Promise.try_resolve started (Ok ()));
              let rec serve () =
                let* command=poll B.default_timeout_sec in
                let* ()=match command with None -> Ok () | Some command ->
                  let result=let* ()=check ~before:before_command_validation ()
                      |> Result.map_error (fun detail -> Peer.Before_effect detail) in
                    let* verb,args,actor=decode command |> Result.map_error (fun detail -> Peer.Before_effect detail) in
                    Peer.dispatch ?actor ~request_id:command.id peer ~verb args in
                  let* ()=accepted (dispatch (W.Deliver {client_id;id=command.id;payload=payload result})) in
                  (match result with Error (Peer.Outcome_unknown detail) -> Error detail
                    | Ok _|Error (Before_effect _|Partial_failure _) -> Ok ()) in
                if Browser_addon_owner.is_retired owner then Ok () else serve () in
              let result=Eio.Fiber.first serve (fun () ->
                Eio.Fiber.first
                  (fun () -> Eio.Promise.await stopping;Ok ())
                  (fun () -> Error (Eio.Promise.await ended))) in
              ignore (dispatch (W.Disconnect client_id));
              match result with Error _ -> result | Ok () ->
                let orderly () =
                  (* Admission has been revoked. Only the already verified
                     original connection is closed; no new input is admitted.
                     Its pinned live child/group proves this is still that
                     owner without waiting on a native gate before shutdown. *)
                  let* ()=Eio_unix.run_in_systhread (fun () ->
                    let* ()=Browser_process_owner.verify_child receipt
                      |> Result.map_error Browser_process_owner.error_to_string in verify c) in
                  let* ()=Peer.close_browser peer |> Result.map_error (function
                    | Peer.Rejected code -> "Firefox browser.close rejected: " ^ Peer.error_code_to_wire code
                    | Unanswered detail | Unsent detail -> detail) in
                  ignore (Eio.Process.await child);
                  let* ()=Eio_unix.run_in_systhread (fun () -> lease (Lease.retire child_admission)) in
                  Eio_unix.run_in_systhread (fun () -> let* ()=settled child_admission in verify c) in
                (match Eio.Time.with_timeout (Eio.Stdenv.clock env) 5. (fun () -> Ok (orderly ())) with
                 | Ok result -> result | Error `Timeout -> Error "original Firefox orderly shutdown did not settle")) in
        match start () with
        | Ok () -> Ok ()
        | Error detail -> let cleanup=abort () in
          Error (match cleanup with Ok () -> detail | Error cleanup -> detail ^ "; cleanup: " ^ cleanup)
        | exception exn -> ignore (abort ());raise exn)
      with
      | Eio.Cancel.Cancelled _ as exn ->
        Eio.Cancel.protect (fun () -> Browser_addon_owner.revoke owner;
          ignore (Eio.Promise.try_resolve started (Error "Firefox worker cancelled"));
          ignore (Eio.Promise.try_resolve finish (Error "Firefox worker cancelled during cleanup")));
        raise exn
      | exn -> Error (Printexc.to_string exn) in
      Eio.Cancel.protect (fun () ->
        (match outcome with Ok () -> () | Error _ -> Browser_addon_owner.revoke owner);
        ignore (Eio.Promise.try_resolve started outcome);
        ignore (Eio.Promise.try_resolve finish outcome)));
    match Eio.Promise.await startup with
    | Error detail -> invalid_arg detail
    | Ok () -> Eio.Switch.run (fun scope ->
      Eio.Switch.on_release scope (fun () -> Browser_addon_owner.revoke owner;
        ignore (Eio.Promise.try_resolve stop ());ignore (Eio.Promise.await stopped));
      Eio.Fiber.first work (fun () -> match Eio.Promise.await stopped with
        | Ok () -> Eio.Fiber.await_cancel ()
        | Error detail -> raise (Sys_error ("owned Firefox backend ended: " ^ detail)))))
let run = run_with ~before_command_validation:(fun () -> ())
module For_testing = struct let run = run_with end
