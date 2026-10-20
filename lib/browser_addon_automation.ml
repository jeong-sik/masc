let ( let* ) = Result.bind
let configuration_to_json (configuration:Browser_configuration.automation) = `Assoc [
  "driver",`String configuration.driver;
  "binary",(match configuration.binary with None -> `Null | Some binary -> `String binary)]
let configuration_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=["binary";"driver"] ->
    let path = function `String path when not (Filename.is_relative path) && not (String.contains path '\000') -> Ok path
      | _ -> Error "automation executable must be an absolute path" in
    let* driver=match List.assoc_opt "driver" fields with Some value -> path value | None -> Error "missing driver" in
    let* binary=match List.assoc_opt "binary" fields with
      | Some `Null -> Ok None | Some value -> Result.map Option.some (path value) | None -> Error "missing binary" in
    Ok {Browser_configuration.driver;binary}
  | _ -> Error "invalid automation configuration"
let request ~pool ~clock ~endpoint ~method_ ~path ~body =
  match Masc_http_client.Pool.request pool ~clock ~timeout_seconds:60.
    ~method_ ~url:(endpoint ^ path) ~headers:["Content-Type","application/json"]
    ?body:(Option.map Yojson.Safe.to_string body) () with
  | Error detail -> Error (Browser_webdriver.Transport detail)
  | Ok response -> Browser_webdriver.decode_response ~status:response.status response.body
let close ~env ~endpoint ~uncertain driver =
  let result,finished=Eio.Promise.create () in
  Eio.Fiber.first (fun () -> Eio.Switch.run (fun sw ->
    let pool=Masc_http_client.Pool.create ~sw ~env () in
    Eio.Promise.resolve finished (Browser_webdriver.close driver
      ~request:(fun ~method_ ~path ~body ->
        let outcome=request ~pool ~clock:(Eio.Stdenv.clock env) ~endpoint ~method_ ~path ~body in
        (match outcome with Error (Browser_webdriver.Remote {code=Invalid_session_id;_}) -> uncertain:=true
         | Ok _ | Error (Transport _|Protocol _|Remote {code=No_such_window|No_such_alert|Unexpected_alert_open|Other _;_}) -> ());
        outcome));
    Eio.Fiber.await_cancel ())) (fun () -> Eio.Promise.await result)
let port () =
  let socket=Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect ~finally:(fun () -> Unix.close socket) (fun () ->
    Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback,0));
    match Unix.getsockname socket with Unix.ADDR_INET (_,port) -> port
      | Unix.ADDR_UNIX _ -> invalid_arg "expected loopback port")
let ready ~clock ~pool ~endpoint ~process =
  (* Same driver startup window as the previous owner: measured startup 1.5 s;
     cold disk allowance 10 s. This bounds readiness I/O, never agent work. *)
  let deadline=Monotonic_deadline.after ~seconds:10. in
  let rec poll () =
    match Masc_http_client.Pool.request pool ~clock ~timeout_seconds:0.1
      ~method_:`GET ~url:(endpoint ^ "/status") ~headers:[] () with
    | Ok response when response.status=200 -> ()
    | Ok _ | Error _ when Monotonic_deadline.passed deadline ->
        invalid_arg "owned geckodriver did not become ready; inspect webdriver.log"
    | Ok _ | Error _ -> Eio.Time.sleep clock 0.1;poll () in
  Eio.Fiber.first poll (fun () ->
    let status=Eio.Process.await process in
    invalid_arg (Format.asprintf "owned geckodriver exited before readiness: %a" Eio.Process.pp_status status))
let run_with_commit ~commit_receipt ~env ~owner ~directory work =
  let configuration = Eio_unix.run_in_systhread (fun () ->
    let text=Fs_compat.load_owned_regular_file ~ownership_root:directory (Filename.concat directory "automation.json")
      |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string in
    let* text=text in
    let* text=Option.to_result ~none:"missing automation configuration" text in
    try configuration_of_json (Yojson.Safe.from_string text) with Yojson.Json_error detail -> Error detail) in
  let configuration=match configuration with Ok value -> value | Error detail -> invalid_arg detail in
  let locate=match Browser_addon_locate.for_owner owner with
    | Ok locate -> locate | Error detail -> invalid_arg detail in
  let clean=ref true and uncertain=ref false in
  let ready_p,ready_u=Eio.Promise.create () in
  let stopping,stop=Eio.Promise.create () in
  let stopped,settle=Eio.Promise.create () in
  Eio.Switch.run (fun lifetime ->
    Eio.Switch.check lifetime;
    Eio.Fiber.fork ~sw:lifetime (fun () ->
    let outcome = try
    Eio.Switch.run (fun sw ->
      let profiles=Filename.concat directory "profiles" in
      let port=Eio_unix.run_in_systhread (fun () -> Unix.mkdir profiles 0o700;port ()) in
      let output=Eio.Path.open_out ~sw ~create:(`Exclusive 0o600) Eio.Path.(Eio.Stdenv.fs env / Filename.concat directory "webdriver.log") in
      Eio.Switch.check sw;
      let process=Eio.Process.spawn ~sw Posix_spawn_process_mgr.mgr ~stdout:output ~stderr:output
        (Browser_driver_process.argv ~driver:configuration.driver ~port ~profile_root:profiles) in
      let endpoint=Printf.sprintf "http://%s:%d" Masc_network_defaults.masc_http_loopback_peer port in
      let clock=Eio.Stdenv.clock env in
      let pool=Masc_http_client.Pool.create ~sw ~env () in
      let transport ~method_ ~path ~body =
        let creating=method_=`POST && path="/session" in
        (* Set before issuance, so cancellation between remote creation and its
           receipt cannot be rewritten into a clean [close None]. *)
        let was_uncertain = !uncertain in
        if creating then (clean:=false;uncertain:=true);
        match request ~pool ~clock ~endpoint ~method_ ~path ~body with
        | Ok value ->
          if creating then (match value with
            | `Assoc fields when (match List.assoc_opt "sessionId" fields with Some (`String id) -> id<>"" | None|Some _ -> false) -> uncertain:=was_uncertain
            | _ -> ());
          Ok value
        | Error ((Browser_webdriver.Remote {code=Invalid_session_id;_}) as error) -> uncertain:=true;Error error
        | Error ((Transport _|Protocol _|Remote {code=No_such_window|No_such_alert|Unexpected_alert_open|Other _;_}) as error) -> Error error in
      let driver=Browser_webdriver.create ?binary:configuration.binary ?locate ~request:transport
        ~start_downloads:(Browser_bidi_downloads.start ~sw ~env ~root:(Filename.concat directory "downloads")
          ~publish:(fun path -> Eio_unix.run_in_systhread (fun () -> Browser_addon_owner.publish_download owner path))) () in
      let close_original=Eio.Lazy.from_fun ~cancel:`Protect (fun () ->
        Browser_addon_owner.revoke owner;
        match close ~env ~endpoint ~uncertain driver with
        | Ok () -> clean:=true;Ok ()
        | Error error -> Error (Browser_webdriver.error_message error)) in
      Eio.Switch.on_release sw (fun () ->
        match Eio.Lazy.force close_original with
        | Ok () -> ()
        | Error detail -> Printf.eprintf "browser session cleanup unconfirmed: %s\n%!" detail);
      ready ~clock ~pool ~endpoint ~process;
      let execute verb = if !uncertain then
          Browser_lane.Rejected_before_effect "owned browser session authority is unknown; detach and inspect cleanup"
        else Browser_webdriver.execute driver verb in
      let cleanup () =
        ignore (Eio.Promise.try_resolve stop ());
        Eio.Promise.await stopped in
      (match Browser_addon_owner.attach_automation owner ~locate:(Option.is_some locate) ~execute
        ~session:(fun () -> if !uncertain then Browser_lane.Browser_unknown else Browser_webdriver.session_observation driver)
        ~document:(fun ~tab_id -> if !uncertain then Browser_lane.Rejected_before_effect "owned session authority is unknown"
          else Browser_webdriver.observe_document_if_idle driver ~tab_id) ~cleanup with
       | Ok () -> () | Error detail -> invalid_arg detail);
      Eio.Promise.resolve ready_u (Ok ());
      Eio.Promise.await stopping;
      (* BiDi's reader is a regular child of this switch. Close the original
         session before switch join so its stop signal can settle that reader;
         the release hook observes the same once-only cleanup on cancellation. *)
      (match Eio.Lazy.force close_original with
       | Ok () -> ()
       | Error detail ->
         (* A rejected DELETE leaves the regular BiDi reader alive. Fail this
            original switch so cancellation joins its reader and owned driver;
            returning normally would wait for that reader forever. *)
         raise (Sys_error ("browser session cleanup unconfirmed: " ^ detail))));
      Ok ()
    with
    | Eio.Cancel.Cancelled _ as exn ->
        ignore (Eio.Promise.try_resolve ready_u (Error "browser startup was cancelled"));
        ignore (Eio.Promise.try_resolve settle (Error "browser cleanup was cancelled"));raise exn
    | (Eio.Io _|Unix.Unix_error _|Sys_error _|Invalid_argument _) as exn -> Error (Printexc.to_string exn)
    | exn ->
        (* Unexpected adapter/release failures still have to wake both joins.
           Publish uncertainty, then preserve the original exception. *)
        ignore (Eio.Promise.try_resolve ready_u (Error "browser startup failed"));
        ignore (Eio.Promise.try_resolve settle (Error "browser cleanup is unconfirmed"));
        raise exn in
    ignore (Eio.Promise.try_resolve ready_u outcome);
    let outcome=match outcome with
      | Error _ -> outcome
      | Ok () -> if !clean && not !uncertain then Ok ()
        else Error "owned browser cleanup is unconfirmed" in
    (* Once driver teardown finishes, cancellation must not strand the foreground
       cleanup join. Commit its receipt and publish terminal completion together. *)
    Eio.Cancel.protect (fun () ->
      let finish () =
        let result=match outcome with
          | Error _ -> outcome
          | Ok () -> commit_receipt ~path:(Filename.concat directory "automation-closed.json")
              ~contents:(Yojson.Safe.to_string (`Assoc ["incarnation",`String (Browser_addon_owner.incarnation owner)])) in
        ignore (Eio.Promise.try_resolve settle result) in
      match finish () with
      | () -> ()
      | exception exn ->
          ignore (Eio.Promise.try_resolve settle (Error "browser cleanup receipt is unconfirmed"));
          raise exn));
    (match Eio.Promise.await ready_p with
     | Error detail -> invalid_arg detail
     | Ok () -> Eio.Switch.run (fun scope ->
         Eio.Switch.on_release scope (fun () ->
           Browser_addon_owner.revoke owner;
           ignore (Eio.Promise.try_resolve stop ());
           ignore (Eio.Promise.await stopped));
         work ())))

let run ~env ~owner ~directory work = run_with_commit ~env ~owner ~directory work
  ~commit_receipt:(fun ~path ~contents -> Eio_unix.run_in_systhread (fun () ->
    Fs_compat.save_file_atomic_strict path contents))
module For_testing = struct
  let run = run_with_commit
end
