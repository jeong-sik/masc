open Result.Syntax
type configuration = { driver : string; binary : string option; profiles : string }
let configuration_label = "automation configuration"
let configuration_keys = ["binary";"driver";"profiles"]
let configuration_to_json configuration = `Assoc [
  "driver",`String configuration.driver;
  "binary",(match configuration.binary with None -> `Null | Some binary -> `String binary);
  "profiles",`String configuration.profiles]
let configuration_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=configuration_keys ->
    let path name requirement = function
      | `String path when not (Filename.is_relative path) && not (String.contains path '\000') -> Ok path
      | value -> Error (Printf.sprintf "%s field %s must be %s; it is %s"
          configuration_label name requirement (Yojson.Safe.to_string value)) in
    let* driver=path "driver" "an absolute path without NUL" (List.assoc "driver" fields) in
    let* binary=match List.assoc "binary" fields with
      | `Null -> Ok None
      | value -> Result.map Option.some (path "binary" "null or an absolute path without NUL" value) in
    let* profiles=path "profiles" "an absolute path without NUL" (List.assoc "profiles" fields) in
    Ok {driver;binary;profiles}
  | `Assoc fields ->
    Error (Resource_requirement.keys ~label:configuration_label ~found:(List.map fst fields) ~required:configuration_keys)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ as value ->
    Error (Printf.sprintf "%s must be a JSON object; it is %s" configuration_label (Yojson.Safe.to_string value))
let request ~pool ~clock ~endpoint ~method_ ~path ~body =
  match Masc_http_client.Pool.request pool ~clock ~timeout_seconds:60.
    ~method_ ~url:(endpoint ^ path) ~headers:["Content-Type","application/json"]
    ?body:(Option.map Yojson.Safe.to_string body) () with
  | Error detail -> Error (Browser_webdriver.Transport detail)
  | Ok response -> Browser_webdriver.decode_response ~status:response.status response.body
let close ~env ~endpoint driver =
  let result,finished=Eio.Promise.create () in
  Eio.Fiber.first (fun () -> Eio.Switch.run (fun sw ->
    let pool=Masc_http_client.Pool.create ~sw ~env () in
    Eio.Promise.resolve finished (Browser_webdriver.close driver
      ~request:(request ~pool ~clock:(Eio.Stdenv.clock env) ~endpoint));
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
let run ~env ~owner ~directory work =
  let configuration = Eio_unix.run_in_systhread (fun () ->
    let text=Fs_compat.load_owned_regular_file ~ownership_root:directory (Filename.concat directory "automation.json")
      |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string in
    let* text=text in
    let* text=Option.to_result ~none:"missing automation configuration" text in
    try configuration_of_json (Yojson.Safe.from_string text) with Yojson.Json_error detail -> Error detail) in
  let configuration=match Result.bind configuration (fun configuration ->
      Eio_unix.run_in_systhread (fun () -> Browser_gecko_profile.check_instance configuration.profiles)
      |> Result.map (fun () -> configuration)) with
    | Ok value -> value | Error detail -> invalid_arg detail in
  let locate=match Browser_addon_locate.for_owner owner with
    | Ok locate -> locate | Error detail -> invalid_arg detail in
  (* Session authority lost while serving is never regained: the worker ends,
     so its group ends and the host sweep reaches any browser it left. *)
  let lost,lost_u=Eio.Promise.create () in
  let lose () = ignore (Eio.Promise.try_resolve lost_u ()) in
  let authority_lost () = Eio.Promise.is_resolved lost in
  let ending = "owned browser session authority was lost; this worker is ending" in
  let ready_p,ready_u=Eio.Promise.create () in
  let stopping,stop=Eio.Promise.create () in
  let stopped,settle=Eio.Promise.create () in
  Eio.Switch.run (fun lifetime ->
    Eio.Switch.check lifetime;
    Eio.Fiber.fork ~sw:lifetime (fun () ->
    let outcome = try
    Eio.Switch.run (fun sw ->
      let port=Eio_unix.run_in_systhread port in
      let output=Eio.Path.open_out ~sw ~create:(`Exclusive 0o600) Eio.Path.(Eio.Stdenv.fs env / Filename.concat directory "webdriver.log") in
      Eio.Switch.check sw;
      let process=Eio.Process.spawn ~sw Posix_spawn_process_mgr.mgr ~stdout:output ~stderr:output
        (Browser_driver_process.argv ~driver:configuration.driver ~port) in
      let endpoint=Printf.sprintf "http://%s:%d" Masc_network_defaults.masc_http_loopback_peer port in
      let clock=Eio.Stdenv.clock env in
      let pool=Masc_http_client.Pool.create ~sw ~env () in
      let profiles={Browser_webdriver.fresh=(fun () -> Eio_unix.run_in_systhread (fun () ->
          Browser_gecko_profile.create ~instance:configuration.profiles));
        (* A session ended by cancellation, such as a command timeout, still
           lets its profile go; the removal never waits on another process. *)
        ended=(fun path -> match Eio.Cancel.protect (fun () ->
            Eio_unix.run_in_systhread (fun () -> Browser_gecko_profile.remove_if_free path)) with
          | Ok Browser_gecko_profile.Removed -> ()
          | Ok Browser_gecko_profile.In_use ->
            Printf.eprintf "Gecko profile %s is still in use; the host removes it after this instance ends\n%!" path
          | Error detail -> Printf.eprintf "Gecko profile %s was kept: %s\n%!" path detail)} in
      let driver=Browser_webdriver.create ?binary:configuration.binary ?locate ~profiles ~lost:lose
        ~request:(request ~pool ~clock ~endpoint)
        ~start_downloads:(Browser_bidi_downloads.start ~sw ~env ~root:(Browser_addon_downloads.downloads_directory ~directory)
          ~publish:(fun path -> Eio_unix.run_in_systhread (fun () -> Browser_addon_owner.publish_download owner path))) () in
      let close_original=Eio.Lazy.from_fun ~cancel:`Protect (fun () ->
        Browser_addon_owner.revoke owner;
        Result.map_error Browser_webdriver.error_message (close ~env ~endpoint driver)) in
      Eio.Switch.on_release sw (fun () ->
        match Eio.Lazy.force close_original with
        | Ok () -> ()
        | Error detail -> Printf.eprintf "browser session cleanup unconfirmed: %s\n%!" detail);
      ready ~clock ~pool ~endpoint ~process;
      let execute verb = if authority_lost () then Browser_lane.Rejected_before_effect ending
        else Browser_webdriver.execute driver verb in
      let cleanup () =
        ignore (Eio.Promise.try_resolve stop ());
        Eio.Promise.await stopped in
      (match Browser_addon_owner.attach_automation owner ~locate:(Option.is_some locate) ~execute
        ~session:(fun () -> if authority_lost () then Browser_lane.Browser_unknown
          else Browser_webdriver.session_observation driver)
        ~document:(fun ~tab_id -> if authority_lost () then Browser_lane.Rejected_before_effect ending
          else Browser_webdriver.observe_document_if_idle driver ~tab_id) ~cleanup with
       | Ok () -> () | Error detail -> invalid_arg detail);
      Eio.Promise.resolve ready_u (Ok ());
      (* A driver that exits while the worker serves leaves no session it can
         address. *)
      Eio.Fiber.first (fun () -> Eio.Promise.await stopping)
        (fun () -> ignore (Eio.Process.await process); lose (); Eio.Fiber.await_cancel ());
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
      | Ok () -> if authority_lost () then Error "owned browser cleanup is unconfirmed" else Ok () in
    ignore (Eio.Promise.try_resolve settle outcome));
    (match Eio.Promise.await ready_p with
     | Error detail -> invalid_arg detail
     | Ok () -> Eio.Switch.run (fun scope ->
         Eio.Switch.on_release scope (fun () ->
           Browser_addon_owner.revoke owner;
           ignore (Eio.Promise.try_resolve stop ());
           ignore (Eio.Promise.await stopped));
         Eio.Fiber.first work (fun () ->
           Eio.Promise.await lost;
           (* A loss during the worker's own stop, such as a creation that
              retirement cancelled, leaves its cleanup unconfirmed; the stop
              goes on. *)
           if Browser_addon_owner.is_retired owner then Eio.Fiber.await_cancel ()
           else (Browser_addon_owner.revoke owner;
             raise (Sys_error "owned Gecko session authority was lost; this worker ends so the host replaces it"))))))
