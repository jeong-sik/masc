module Lease = Native_addon_lease
module Session = Browser_stagehand_session
module Process = Browser_chromium_process
module Profile = Browser_addon_chrome_profile
module Requirement = Resource_requirement
let ( let* ) = Result.bind

type configuration = { chrome : string; extension : string; launcher : string;
  guardian : string; claim_directory : string; profile:Profile.t }

let absolute path = path<>"" && not (Filename.is_relative path) && not (String.contains path '\000')
let configuration ~(browser:Browser_configuration.stagehand) ~launcher ~guardian ~claim_directory =
  let* ()=List.fold_left (fun result (name,path) -> let* ()=result in
      if absolute path then Ok ()
      else Error (Printf.sprintf "%s must be an absolute path without NUL; it is %S" name path)) (Ok ())
    ["[browser.stagehand] chrome",browser.chrome;"[browser.stagehand] extension",browser.extension;
     "Chrome launcher",launcher;"Chrome guardian",guardian;"Chrome claim directory",claim_directory] in
  let* profile=Profile.select ~path:browser.profile in
  Ok {chrome=browser.chrome;extension=browser.extension;launcher;guardian;claim_directory;profile}

let claim_directories c = c.claim_directory :: (match c.profile with
  | Profile.Private -> [] | Persistent profile -> [Profile.claim_directory profile])

let configuration_to_json c = `Assoc ["chrome",`String c.chrome;"extension",`String c.extension;
  "launcher",`String c.launcher;"guardian",`String c.guardian;"claim_directory",`String c.claim_directory;
  "profile",Profile.to_json c.profile]
let configuration_label = "Chrome Add-on configuration"
let configuration_keys = ["chrome";"claim_directory";"extension";"guardian";"launcher";"profile"]
let configuration_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=configuration_keys ->
    let field name=match List.assoc name fields with
      | `String path when absolute path -> Ok path
      | value -> Error (Printf.sprintf "%s field %s must be an absolute path without NUL; it is %s"
          configuration_label name (Yojson.Safe.to_string value)) in
    let* chrome=field "chrome" in
    let* extension=field "extension" in
    let* launcher=field "launcher" in
    let* guardian=field "guardian" in
    let* claim_directory=field "claim_directory" in
    let* profile=Profile.of_json (List.assoc "profile" fields) in
    Ok {chrome;extension;launcher;guardian;claim_directory;profile}
  | `Assoc fields ->
    Error (Requirement.keys ~label:configuration_label ~found:(List.map fst fields) ~required:configuration_keys)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ as value ->
    Error (Printf.sprintf "%s must be a JSON object; it is %s" configuration_label (Yojson.Safe.to_string value))

let protect work = try work () with
  | (Unix.Unix_error _ | Sys_error _ | Yojson.Json_error _) as exn -> Error (Printexc.to_string exn)
let lease result = Result.map_error Lease.error_to_string result
let original_browser ~admission ~(receipt:Browser_process_owner.ready) () =
  let* status=lease (Lease.status admission) in
  match status with
  | Lease.Live identity when identity.pid=receipt.owner_pid
      && identity.instance_id=receipt.instance_id && receipt.instance_id=Lease.instance_id admission ->
    Browser_process_owner.verify_child receipt |> Result.map_error Browser_process_owner.error_to_string
  | Awaiting_exec | Live _ | Cleanup_pending _ | Settled ->
    Error "Chrome connection lost its original kernel owner lease"
let verify_browser ~admission ~receipt cdp =
  let original () = Eio_unix.run_in_systhread (original_browser ~admission ~receipt) in
  let result=
    let* ()=original () in
    let* process_info=Browser_cdp.command cdp "SystemInfo.getProcessInfo" (`Assoc [])
      |> Result.map_error (function
        | Browser_cdp.Command_rejected {code;message} ->
          Printf.sprintf "Chrome process identity rejected (%d): %s" code message
        | Connection_lost detail -> "Chrome process identity connection ended: " ^ detail) in
    let* pid=Browser_cdp.browser_process_id_of_json process_info in
    let* ()=if pid=receipt.child_pid then Ok ()
      else Error "Chrome debugging endpoint belongs to another browser process" in
    original () in
  (match result with Ok () -> () | Error detail -> Browser_cdp.lost cdp detail);
  result
let context c ~incarnation ~directory = `Assoc ["kind",`String "browser_addon_chrome";
  "incarnation",`String incarnation;"directory",`String directory;
  "profile",Profile.to_json c.profile]
let original c ~incarnation ~directory = protect (fun () ->
  match Unix.lstat c.claim_directory with
  | _ ->
    let* preparation=lease (Lease.recover_preparation ~directory:c.claim_directory) in
    (match preparation with
     | Lease.Unpublished -> Ok None
     | Current claim ->
       let* known=lease (Lease.cleanup_context claim) in
       if known=Some (context c ~incarnation ~directory) then Ok (Some claim)
       else Error "Chrome child claim belongs to a different browser allocation")
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok None)
(* [original]'s reads without the gate or [recover_preparation]'s fence: the
   child slot decoded by [Lease.inspect] and its descriptor compared with the
   one this allocation recomputes. *)
let check_retained_child c ~incarnation ~directory =
  match Unix.lstat c.claim_directory with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | exception Unix.Unix_error (code, _, _) -> Error (c.claim_directory ^ ": " ^ Unix.error_message code)
  | _ ->
    (match Lease.inspect ~directory:c.claim_directory with
     | Error (refused : Lease.inspection_error) -> Error refused.refusal
     | Ok None -> Ok ()
     | Ok (Some recorded) ->
       if recorded.context = Some (context c ~incarnation ~directory) then Ok ()
       else Error (c.claim_directory ^ ": Chrome child claim belongs to a different browser allocation"))
let settled claim =
  let* status=lease (Lease.status claim) in
  match status with
  | Lease.Settled -> Ok ()
  | Awaiting_exec | Live _ | Cleanup_pending _ -> Error "Chrome child claim has not settled"
let settle c ~incarnation ~directory =
  let* claim=original c ~incarnation ~directory in
  match claim with
  | None -> Ok ()
  | Some claim -> let* ()=lease (Lease.request_termination claim) in settled claim

(* The host has already checked the original allocation inode and worker
   settlement. Never follow a profile symlink, and retain unexpected resources.
   A configured operator profile never enters this private tree. *)
let rec remove_profile path =
  let info=Unix.lstat path in
  if info.Unix.st_uid<>Unix.geteuid () then
    Error (Printf.sprintf "Chrome profile entry %s must be owned by uid %d; it is owned by uid %d"
      path (Unix.geteuid ()) info.st_uid)
  else match info.st_kind with
  | Unix.S_DIR ->
    let* ()=Array.fold_left (fun result name -> let* ()=result in
      remove_profile (Filename.concat path name)) (Ok ()) (Sys.readdir path) in
    Unix.rmdir path;Ok ()
  | Unix.S_LNK -> Unix.unlink path;Ok ()
  | Unix.S_REG when info.st_nlink=1 -> Unix.unlink path;Ok ()
  | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK as kind ->
    Error (Printf.sprintf
      "Chrome profile entry %s must be a directory, a symbolic link or a regular file with exactly one link; it is a %s with %d links"
      path (Requirement.kind_name kind) info.st_nlink)
let profiles directory = Filename.concat directory "chromium-profiles"
let profiles_label = "Chrome private profiles directory"
let cleanup c ~incarnation ~directory = protect (fun () ->
  let* claim=original c ~incarnation ~directory in
  let* ()=settle c ~incarnation ~directory in
  match Unix.lstat (profiles directory) with
  | info ->
    let* ()=Requirement.check ~label:profiles_label Requirement.private_directory ~path:(profiles directory) info in
    let names=Sys.readdir (profiles directory) in
    let* ()=if names<>[||] && Option.is_none claim then Error "Chrome profiles have no original child claim"
      else Ok () in
    let* ()=Array.fold_left (fun result name -> let* ()=result in
      match Uuidm.of_string name with
      | Some uuid when Uuidm.to_string uuid=name -> remove_profile (Filename.concat (profiles directory) name)
      | None | Some _ -> Error "Chrome profile directory contains an unknown allocation") (Ok ()) names in
    Unix.rmdir (profiles directory);Ok ()
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok ())

let read_configuration directory =
  let* text=Fs_compat.load_owned_regular_file ~ownership_root:directory (Filename.concat directory "stagehand.json")
    |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string in
  let* text=Option.to_result ~none:"missing Chrome Add-on configuration" text in
  protect (fun () -> configuration_of_json (Yojson.Safe.from_string text))
let fresh_id () = Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ()))
type opened = {session:Session.t; child_pid:int;shutdown:unit -> (unit,string) result}
let stop_grace_s = 5.
let port_poll_s = 0.1
let await_endpoint ~env ~profile ~process =
  let timeout=Browser_lane.Stagehand_open_budget.devtools_port_timeout_s in
  let deadline=Monotonic_deadline.after ~seconds:timeout in
  let path=Filename.concat profile Process.devtools_port_file in
  let rec poll () =
    let value=Eio_unix.run_in_systhread (fun () ->
      let* text=Fs_compat.load_owned_regular_file ~ownership_root:profile path
        |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string in
      let* text=Option.to_result ~none:"Chromium has not published its debugging endpoint" text in
      Process.devtools_endpoint_of_string text) in
    match value with
    | Ok endpoint -> Ok endpoint
    | Error _ when Monotonic_deadline.passed deadline -> Error "Chromium did not publish its debugging endpoint"
    | Error _ -> Eio.Time.sleep (Eio.Stdenv.clock env) port_poll_s;poll () in
  Eio.Fiber.first poll (fun () ->
    let status=Eio.Process.await process in
    Error (Format.asprintf "Chrome owner exited before readiness: %a" Eio.Process.pp_status status))

let open_session ~sw ~env ~owner ~directory ~configuration:c ~model ~headless ~log =
  let incarnation=Browser_addon_owner.incarnation owner in
  let verify_profile ()=match c.profile with
    | Profile.Private -> Ok () | Persistent profile -> Profile.verify profile in
  let* extension,extension_id,instance_id,admission,child_admission=(
  let* extension=Eio_unix.run_in_systhread (fun () -> protect (fun () -> Ok (Unix.realpath c.extension))) in
  let extension_id=Browser_stagehand_wire.extension_id_of_real_path extension in
  let* ()=Eio_unix.run_in_systhread (fun () -> settle c ~incarnation ~directory) in
  let instance_id=fresh_id () in
  (* The stable child reservation precedes any profile allocation. It survives
     worker death and fences a launcher delayed past detach or failed startup. *)
  let* admission,child_admission=Eio_unix.run_in_systhread (fun () ->
    let* ()=verify_profile () in
    let* admission=lease (Lease.prepare ~directories:(claim_directories c) ~instance_id
      ~cleanup_context:(Some (context c ~incarnation ~directory))) in
    let* child_admission=lease (Lease.reopen ~directories:[c.claim_directory] ~instance_id) in
    Ok (admission,child_admission)) in
  Ok (extension,extension_id,instance_id,admission,child_admission))
    |> Result.map_error (fun detail -> Browser_stagehand_backend.Not_opened detail) in
  let process=ref None and input=ref None in
  (* The shared profile slot may already belong to a successor after physical
     exit. Recovery/retirement stays bound to this exact original child slot. *)
  let retire () = Eio_unix.run_in_systhread (fun () -> lease (Lease.retire child_admission)) in
  let request_stop () =
    let result=retire () in
    Option.iter Eio.Flow.close !input;input:=None;
    Option.iter (fun process -> Eio.Process.signal process Sys.sigterm) !process;
    result in
  (* Registered before spawn: the process manager releases its pinned original
     group before this final claim observation runs. *)
  Eio.Switch.on_release sw (fun () ->
    match Eio_unix.run_in_systhread (fun () ->
      let* ()=lease (Lease.retire child_admission) in settled child_admission) with
    | Ok () -> ()
    | Error detail -> Log.Server.warn "browser Add-on Chrome cleanup: %s" detail);
  let start () =
    let* selected_profile=Eio_unix.run_in_systhread (fun () -> match c.profile with
      | Profile.Persistent profile ->
        let* ()=Profile.before_launch profile in Ok (Process.Operator_profile (Profile.path profile))
      | Private -> protect (fun () ->
      (try Unix.mkdir (profiles directory) 0o700 with Unix.Unix_error (Unix.EEXIST,_,_) -> ());
      let root=Unix.lstat (profiles directory) in
      let* ()=Requirement.check ~label:profiles_label Requirement.private_directory ~path:(profiles directory) root in
      let* ()=Requirement.canonical ~label:profiles_label (profiles directory) in
      let profile=Filename.concat (profiles directory) instance_id in
      Unix.mkdir profile 0o700;Ok (Process.Private_profile profile))) in
    let profile=Process.profile_path selected_profile in
    let output=Eio.Path.open_out ~sw ~append:true ~create:(`If_missing 0o600)
      Eio.Path.(Eio.Stdenv.fs env / Filename.concat directory "chromium.log") in
    let keepalive_read,keepalive_write=Eio_unix.pipe sw in
    let ready_read,ready_write=Eio_unix.pipe sw in
    input:=Some keepalive_write;
    let argv=[c.launcher;"--instance";instance_id] @
      List.concat_map (fun slot -> ["--slot";slot]) (claim_directories c) @
      ["--";c.guardian;"--instance";instance_id;"--"] @
      Process.argv ~chrome:c.chrome ~profile:selected_profile ~extension_id ~headless in
    Eio.Switch.check sw;
    let child=Eio.Process.spawn ~sw
      (Posix_spawn_process_mgr.foreground_mgr ~clock:(Eio.Stdenv.clock env) ~grace_seconds:stop_grace_s)
      ~stdin:keepalive_read ~stdout:ready_write ~stderr:output argv in
    process:=Some child;
    Eio.Flow.close keepalive_read;Eio.Flow.close ready_write;
    Eio.Switch.on_release sw (fun () -> ignore (request_stop ()));
    let* receipt=Eio.Fiber.first
      (fun () ->
        (* Fixed bootstrap metadata only; never a page/model payload. *)
        let reader=Eio.Buf_read.of_flow ready_read ~max_size:1024 in
        match Eio.Buf_read.line reader with
        | line -> protect (fun () -> Browser_process_owner.ready_of_json (Yojson.Safe.from_string line))
        | exception End_of_file -> Error "Chrome owner ended without a bootstrap receipt")
      (fun () -> ignore (Eio.Process.await child);Error "Chrome owner exited before bootstrap") in
    let* ()=if receipt.owner_pid=Eio.Process.pid child && receipt.instance_id=instance_id
      then Ok () else Error "Chrome bootstrap does not name its original process owner" in
    let* ()=Eio_unix.run_in_systhread (original_browser ~admission ~receipt) in
    Eio.Flow.close ready_read;
    (* No extension event handler or model callback is installed until the
       connection has independently identified the original browser child. *)
    let current_session=ref None in
    let connect () =
      let* port,path=await_endpoint ~env ~profile ~process:child in
      let url=Process.browser_ws_url ~port ~path in
      let* cdp=Browser_cdp.connect ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
        ~url ~max_message:(64*1024*1024)
        ~command_deadline_s:Browser_lane.Stagehand_open_budget.cdp_command_deadline_s
        ~on_event:(fun event -> Option.iter (fun session -> Session.on_cdp_event session event) !current_session) in
      let result=let* ()=verify_browser ~admission ~receipt cdp in
        let* ()=Eio_unix.run_in_systhread verify_profile in Ok (cdp,url) in
      (match result with Ok _ -> () | Error detail -> Browser_cdp.lost cdp detail);
      result in
    let* cdp,url=match c.profile with
      | Profile.Private -> connect ()
      | Persistent _ ->
        (* A preserved DevToolsActivePort may name a previous session. Only
           read-only bootstrap observations may be repeated, before installing
           the extension, model callback or any input. Never reset that file. *)
        let rec observe () =
          let* ()=Eio_unix.run_in_systhread (fun () ->
            let* ()=original_browser ~admission ~receipt () in verify_profile ()) in
          match connect () with
          | Ok _ as ready -> ready
          | Error _ -> Eio.Time.sleep (Eio.Stdenv.clock env) port_poll_s;observe () in
        (match Eio.Time.with_timeout (Eio.Stdenv.clock env)
          Browser_lane.Stagehand_open_budget.devtools_port_timeout_s (fun () -> Ok (observe ())) with
         | Ok result -> result
         | Error `Timeout -> Error "original Chrome did not publish a verified debugging endpoint") in
    let session=Session.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~worker_wait_s:Browser_lane.Stagehand_open_budget.service_worker_wait_s
      ~init_answer_s:Browser_lane.Stagehand_open_budget.init_answer_s
      (* Matches the existing session's bound for a caller-abandoned extension
         request. It never bounds ongoing agent/model work. *)
      ~abandoned_answer_s:30. ~model ~log in
    current_session:=Some session;
    let* init=Session.attach session cdp ~extension_dir:extension ~browser_cdp_url:url
      |> Result.map_error Browser_stagehand_executor.attach_error_message in
    let shutdown () =
      (* This closure retains the verified original connection and process.
         EOF is not a reason to replay Browser.close; actual owner completion
         and profile release are observed separately from the CDP answer. *)
      let orderly () =
        let* ()=Eio_unix.run_in_systhread (original_browser ~admission ~receipt) in
        let* ()=match Browser_cdp.command cdp "Browser.close" (`Assoc []) with
          | Ok _|Error (Browser_cdp.Connection_lost _) -> Ok ()
          | Error (Command_rejected {code;message}) ->
            Error (Printf.sprintf "Browser.close rejected (%d): %s" code message) in
        ignore (Eio.Process.await child);
        let* ()=retire () in
        Eio_unix.run_in_systhread (fun () ->
          let* ()=settled child_admission in
          match c.profile with Profile.Private -> Ok ()
            | Persistent profile -> Profile.before_launch profile) in
      let result=match Eio.Time.with_timeout (Eio.Stdenv.clock env) stop_grace_s
        (fun () -> Ok (orderly ())) with
        | Ok result -> result
        | Error `Timeout -> Error "original Chrome did not complete orderly shutdown within its resource grace" in
      match result with
      | Ok () -> Ok ()
      | Error detail ->
        (* Abort only the pinned original owner. A successful abort does not
           turn the failed orderly/profile shutdown into a clean receipt. *)
        let retirement=request_stop () in
        ignore (Eio.Process.await child);
        let cleanup=let* ()=retirement in
          Eio_unix.run_in_systhread (fun () -> settled child_admission) in
        Error (match cleanup with Ok () -> detail | Error error -> detail ^ "; abort cleanup: " ^ error) in
    Ok ({session;child_pid=receipt.child_pid;shutdown},init) in
  let stop_failed () = Eio.Cancel.protect (fun () ->
    let retirement=request_stop () in
    Option.iter (fun child -> ignore (Eio.Process.await child)) !process;
    let* ()=retirement in
    Eio_unix.run_in_systhread (fun () -> settled child_admission)) in
  match start () with
  | Ok _ as opened -> opened
  | Error detail -> (match stop_failed () with
      | Ok () -> Error (Browser_stagehand_backend.Not_opened detail)
      | Error cleanup -> Error (Browser_stagehand_backend.Cleanup_unconfirmed
          (detail ^ "; cleanup unconfirmed: " ^ cleanup)))
  | exception exn ->
    (match stop_failed () with
     | Ok () -> ()
     | Error detail -> Eio.Switch.fail sw (Failure ("partial Chrome cleanup unconfirmed: " ^ detail)));
    raise exn

let log = function
  | Session.Runtime_ready marker -> Log.Server.info "browser Add-on Chrome runtime %s ready" marker.runtime_version
  | Model_request_refused {reason} -> Log.Server.info "browser Add-on Chrome model refused: %s" reason
  | Model_failed detail -> Log.Server.warn "browser Add-on Chrome model failed: %s" detail
  | Worker_detached -> Log.Server.warn "browser Add-on Chrome extension detached"
  | Connection_ended reason -> Log.Server.info "browser Add-on Chrome connection ended: %s" reason
  | Reply_not_delivered detail | Malformed_message detail -> Log.Server.warn "browser Add-on Chrome: %s" detail
  | Unsupported_request {method_} | Unsupported_notification {method_} ->
    Log.Server.info "browser Add-on Chrome unsupported request: %s" method_
  | Malformed_cdp_event {method_;detail} -> Log.Server.warn "browser Add-on Chrome %s: %s" method_ detail
  | Unexpected_response {id} -> Log.Server.warn "browser Add-on Chrome unexpected response: %d" id
  | Cancelled_call_answered {method_;rejected} | Abandoned_call_ended {method_;rejected} ->
    Log.Server.info "browser Add-on Chrome departed caller's %s settled (rejected=%b)" method_ rejected
  | Abandoned_call_unanswered {method_;waited_s} ->
    Log.Server.warn "browser Add-on Chrome abandoned %s unanswered after %.0fs" method_ waited_s
  | Extension_log _ -> ()

let run ~env ~owner ~directory work =
  let c=match Eio_unix.run_in_systhread (fun () -> read_configuration directory) with
    | Ok configuration -> configuration | Error detail -> invalid_arg detail in
  let selected_model=match Browser_addon_stagehand_model.for_owner owner with
    | Error detail -> invalid_arg detail
    | Ok selected -> selected in
  let model=match selected_model with
    | Some model -> model
    | None -> (fun _ -> Error {Browser_stagehand_wire.code=Browser_stagehand_wire.host_refused;
        message="the browser Add-on stagehand Exact Output is not selected"}) in
  let ready,resolve_ready=Eio.Promise.create () in
  let stopping,stop=Eio.Promise.create () in
  let stopped,resolve_stopped=Eio.Promise.create () in
  Eio.Switch.run (fun lifetime ->
    Eio.Switch.check lifetime;
    Eio.Fiber.fork ~sw:lifetime (fun () ->
      let backend_settlement=ref (fun () -> Ok ()) in
      let outcome=try
        let result=Eio.Switch.run (fun sw ->
          let backend=Browser_stagehand_backend.create ~sw ~clock:(Eio.Stdenv.clock env)
            ~open_session:(open_session ~env ~owner ~directory ~configuration:c ~model)
            ~call:(fun opened -> Session.call opened.session)
            ~shutdown:(fun opened -> opened.shutdown ()) ~pid:(fun opened -> opened.child_pid) ~log in
          backend_settlement := (fun () -> Browser_stagehand_backend.settlement backend);
          let cleanup () =
            ignore (Eio.Promise.try_resolve stop ());Eio.Promise.await stopped in
          let* ()=Browser_addon_owner.attach_stagehand owner ~models:(Option.is_some selected_model)
            ~execute:(fun ~actor verb -> Browser_stagehand_backend.execute backend ?actor verb)
            ~session:(fun () -> Browser_stagehand_backend.session_observation backend) ~cleanup in
          Eio.Promise.resolve resolve_ready (Ok ());
          Eio.Promise.await stopping;Ok ()) in
        (match result with Error _ -> result | Ok () -> !backend_settlement ())
      with
      | Eio.Cancel.Cancelled _ as exn ->
        ignore (Eio.Promise.try_resolve resolve_ready (Error "Chrome backend startup cancelled"));
        ignore (Eio.Promise.try_resolve resolve_stopped (Error "Chrome backend cleanup cancelled"));raise exn
      | exn ->
        ignore (Eio.Promise.try_resolve resolve_ready (Error "Chrome backend startup failed"));
        ignore (Eio.Promise.try_resolve resolve_stopped (Error "Chrome backend cleanup unconfirmed"));raise exn in
      let finish () = Eio.Cancel.protect (fun () ->
        let physical=Eio_unix.run_in_systhread (fun () ->
          settle c ~incarnation:(Browser_addon_owner.incarnation owner) ~directory) in
        let result=match outcome,physical with
          | Ok (),Ok () -> Ok ()
          | Error detail,Ok ()|Ok (),Error detail -> Error detail
          | Error detail,Error physical -> Error (detail ^ "; original child cleanup: " ^ physical) in
        ignore (Eio.Promise.try_resolve resolve_ready result);
        ignore (Eio.Promise.try_resolve resolve_stopped result)) in
      match finish () with
      | () -> ()
      | exception exn ->
        ignore (Eio.Promise.try_resolve resolve_ready (Error "Chrome backend settlement failed"));
        ignore (Eio.Promise.try_resolve resolve_stopped (Error "Chrome backend settlement unconfirmed"));
        raise exn);
    match Eio.Promise.await ready with
    | Error detail -> invalid_arg detail
    | Ok () -> Eio.Switch.run (fun scope ->
      Eio.Switch.on_release scope (fun () ->
        Browser_addon_owner.revoke owner;
        ignore (Eio.Promise.try_resolve stop ());ignore (Eio.Promise.await stopped));
      work ()))
