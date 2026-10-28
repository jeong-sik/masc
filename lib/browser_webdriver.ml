(* The W3C WebDriver error code is parsed once, in [decode_response], into a
   closed sum; every recovery site below matches a constructor, never the wire
   string. [Other] keeps the raw code so an unlisted error stays reportable. *)
type remote_error = Invalid_session_id | No_such_window | No_such_alert | Unexpected_alert_open | Other of string
type error = Transport of string | Protocol of string | Remote of { code : remote_error; message : string }
type request = method_:Masc_http_client.Pool.http_method -> path:string -> body:Yojson.Safe.t option -> (Yojson.Safe.t, error) result
type pointer_state = Released | Release_required
type located_node = { node_id : string; description : string }
type locate = scene:Browser_scene.t -> instruction:string option -> (located_node list, string) result
type session = { mutable pointer_state : pointer_state; uploads : Browser_lane.Upload_lease.owner; id : string; mutable handles : (string * int) list; mutable window_sizes : (string * (int * int)) list; mutable emulated : (string * (string * string)) list; mutable blocks : (string * string) list; mutable download_contexts : (string * int) list; mutable downloads : (Browser_downloads.connection, string) result; profile : string option }
type profiles = { fresh : unit -> (string, string) result; ended : string -> unit }
type t = { start_downloads : Browser_downloads.start; binary : string option; locate : locate option; profiles : profiles option; lost : unit -> unit; request : request; mutex : Eio.Mutex.t; active : int Atomic.t; mutable session : session option; mutable next_tab : int; observed_session : Browser_lane.session_observation Atomic.t }
open Result.Syntax
let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None
let string_field key json = match field key json with
  | Some (`String value) when value <> "" -> Ok value
  | _ -> Error (Protocol ("missing string field: " ^ key))
let remote_error_of_code = function
  | "invalid session id" -> Invalid_session_id
  | "no such window" -> No_such_window
  | "no such alert" -> No_such_alert
  | "unexpected alert open" -> Unexpected_alert_open
  | code -> Other code
let remote_error_code = function
  | Invalid_session_id -> "invalid session id"
  | No_such_window -> "no such window"
  | No_such_alert -> "no such alert"
  | Unexpected_alert_open -> "unexpected alert open"
  | Other code -> code
let error_message = function
  | Transport message | Protocol message -> message
  | Remote { code; message } -> remote_error_code code ^ ": " ^ message
let error_at_tab tab_id error =
  let context message = Printf.sprintf "tabId=%d: %s" tab_id message in
  match error with
  | Transport message -> Transport (context message)
  | Protocol message -> Protocol (context message)
  | Remote {code;message} -> Remote {code;message=context message}
let decode_response ~status body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error detail -> Error (Protocol detail)
  | json ->
    match field "value" json with
    | None -> Error (Protocol "WebDriver response has no value")
    | Some value when status >= 200 && status < 300 -> Ok value
    | Some value ->
      let* code = string_field "error" value in
      let* message = match field "message" value with
        | Some (`String message) -> Ok message
        | _ -> Error (Protocol "missing string field: message") in
      Error (Remote { code = remote_error_of_code code; message })
let create ?binary ?locate ?profiles ?(lost = ignore) ~start_downloads ~request () = { start_downloads; binary; locate; profiles; lost; request; mutex = Eio.Mutex.create (); active = Atomic.make 0; session = None; next_tab = 1; observed_session = Atomic.make Browser_lane.Browser_closed }
let session_observation t = Atomic.get t.observed_session
let path session suffix = "/session/" ^ Uri.pct_encode session.id ^ suffix
let profile_ended t = function
  | None -> ()
  | Some path -> Option.iter (fun profiles -> profiles.ended path) t.profiles
let release_resources t session =
  Result.iter (fun (d : Browser_downloads.connection) -> d.close ()) session.downloads;
  Browser_lane.Upload_lease.release_owner session.uploads;
  profile_ended t session.profile
let call t session method_ suffix body =
  let result = t.request ~method_ ~path:(path session suffix) ~body in
  (match result with
   | Error (Remote { code = Invalid_session_id; _ }) ->
     (* A release hook may call again with a session already released. *)
     (match t.session with
      | Some current when current == session ->
        t.session <- None; Atomic.set t.observed_session Browser_lane.Browser_closed; release_resources t session;
        t.lost ()
      | Some _ | None -> ())
   | Error (Transport _ | Protocol _) -> Atomic.set t.observed_session Browser_lane.Browser_unknown
   | Ok _ -> (match session.downloads with Ok _ -> Atomic.set t.observed_session Browser_lane.Browser_open | Error _ -> ())
   | Error (Remote { code = No_such_window | No_such_alert | Unexpected_alert_open | Other _; _ }) -> ());
  result
(* State changes below never yield: cancellation can interrupt remote I/O but
   cannot leave a half-written local session. Explicit ownership releases the
   lock on cancellation without poisoning it as [use_rw] would. *)
let with_registered_session_lock t f =
  Eio.Switch.run (fun sw ->
    (* See [with_session_lock]: balance registration on release; the prior count is unused. *)
    Eio.Switch.on_release sw (fun () -> ignore (Atomic.fetch_and_add t.active (-1)));
    Eio.Mutex.lock t.mutex;
    Eio.Switch.on_release sw (fun () -> Eio.Mutex.unlock t.mutex);
    f ())
let with_session_lock t f =
  (* See [observe_document_if_idle]: admission reads the updated count, not its prior value. *)
  ignore (Atomic.fetch_and_add t.active 1);
  with_registered_session_lock t f
let close_unlocked ?request t = match t.session with
  | None -> Ok ()
  | Some session ->
    let request = Option.value ~default:t.request request in
    Atomic.set t.observed_session Browser_lane.Browser_changing;
    let result = match request ~method_:`DELETE ~path:(path session "") ~body:None with
      | result -> result
      | exception exn -> Atomic.set t.observed_session Browser_lane.Browser_unknown; raise exn in
    match result with
    | Ok _ -> t.session <- None; Atomic.set t.observed_session Browser_lane.Browser_closed; release_resources t session; Ok ()
    | Error (Remote { code = Invalid_session_id; _ }) ->
      t.session <- None; Atomic.set t.observed_session Browser_lane.Browser_closed; release_resources t session;
      t.lost (); Ok ()
    | Error ((Transport _ | Protocol _
             | Remote { code = No_such_window | No_such_alert | Unexpected_alert_open | Other _; _ }) as error) ->
      Atomic.set t.observed_session Browser_lane.Browser_unknown; Error error
let close ?request t = with_session_lock t (fun () -> close_unlocked ?request t)
let session t = match t.session with
  | Some session ->
    let* () = match session.pointer_state with
      | Released -> Ok ()
      | Release_required ->
        (* A click that opens a JavaScript dialog leaves the release refused
           while the dialog is open. The dialog is answered through this same
           session, so the refusal must not block it; the release stays
           pending and runs once the dialog is gone. *)
        (match call t session `DELETE "/actions" None with
         | Ok _ -> session.pointer_state <- Released; Ok ()
         | Error (Remote {code=Unexpected_alert_open;_}) -> Ok ()
         | Error (Transport _ | Protocol _
                 | Remote {code=Invalid_session_id | No_such_window | No_such_alert | Other _;_}) as error ->
           Result.map ignore error) in
    let* downloads = Result.map_error (fun detail -> Protocol detail) session.downloads in
    let* () = Result.map_error (fun detail -> Protocol detail) (downloads.check ()) in
    Ok session
  | None -> Error (Protocol "Firefox session is closed; open a browser session first")
let tab_id t session handle = match List.assoc_opt handle session.handles with
  | Some id -> id
  | None ->
    let id = t.next_tab in
    t.next_tab <- id + 1;
    session.handles <- (handle, id) :: session.handles;
    session.download_contexts <- (handle, id) :: session.download_contexts;
    id
let select t session handle =
  call t session `POST "/window" (Some (`Assoc ["handle", `String handle]))
let with_tab t session tab_id f =
  match tab_id with
  | None -> let* _ = call t session `POST "/frame" (Some (`Assoc ["id",`Null])) in f ()
  | Some id ->
    match List.find_opt (fun (_, known) -> known = id) session.handles with
    | None -> Error (Protocol "unknown tab id; refresh the tab list")
    | Some (handle, _) -> let* _ = select t session handle in f ()
let script t session source args =
  call t session `POST "/execute/sync"
    (Some (`Assoc ["script", `String source; "args", `List args]))
let page_summary t session =
  script t session "return {url:location.href,title:document.title};" []
let absolute_http_url url =
  let uri = Uri.of_string url in
  match Uri.scheme uri, Uri.host uri with
  | Some ("http" | "https"), Some host when host <> "" -> Ok ()
  | _ -> Error (Protocol "navigation requires an absolute HTTP(S) URL")
let element_id t session selector =
  let* result = call t session `POST "/elements"
      (Some (`Assoc ["using", `String "css selector"; "value", `String selector])) in
  match result with
  | `List [element] -> string_field "element-6066-11e4-a52e-4f735466cecf" element
  | `List [] -> Error (Protocol "selector matched no element; read elements again")
  | `List _ -> Error (Protocol "selector is ambiguous; select exactly one element")
  | _ -> Error (Protocol "malformed WebDriver elements response")
let enter_frames t session selectors =
  let rec enter = function
    | [] -> Ok ()
    | selector :: rest ->
      let* id = element_id t session selector in
      let* _ = call t session `POST "/frame" (Some (`Assoc ["id",
        `Assoc ["element-6066-11e4-a52e-4f735466cecf",`String id]])) in
      enter rest in
  enter selectors
(* Firefox sizes a window; the WebDriver rect is the outer size. The browser's
   own chrome is outer minus inner, so the window is asked for the viewport
   plus that difference and the inner size is read back. Headless Firefox keeps
   a window at least 500 x 120 outer pixels (probed on Firefox 158): a smaller
   request leaves the viewport larger than asked, which is reported, not hidden.
   The first resize of a window remembers its outer size for [Browser_default]. *)
let set_viewport t session size args =
  let failure ~started message =
    Ok (`Assoc ["interactionFailure",`Assoc ["message",`String message;"effectStarted",`Bool started]]) in
  match script t session Browser_interaction.url_guard_script [args] with
  | Error error -> failure ~started:false (error_message error)
  | Ok observed ->
    let int key json = match field key json with
      | Some (`Int n) -> Ok n
      | _ -> Error (Protocol ("window measurement lacks " ^ key)) in
    let* handle = match call t session `GET "/window" None with
      | Ok (`String handle) -> Ok handle
      | Ok _ -> Error (Protocol "invalid current browser window")
      | Error error -> Error error in
    let measure () =
      let* rect = call t session `GET "/window/rect" None in
      let* outer_w = int "width" rect in
      let* outer_h = int "height" rect in
      let* inner = script t session "return {w:innerWidth,h:innerHeight};" [] in
      let* inner_w = int "w" inner in
      let* inner_h = int "h" inner in
      Ok (outer_w, outer_h, inner_w, inner_h) in
    let* (first_w, first_h, _, _) as start = measure () in
    (* The chrome around the viewport differs between a maximized and a normal
       window (85 then 73 pixels on Firefox 158), so the first request can land
       a few pixels off; measure again and correct, a bounded number of times. *)
    let rec settle attempts (outer_w, outer_h, inner_w, inner_h) = match size with
      | Browser_lane.Browser_default ->
        (match List.assoc_opt handle session.window_sizes with
         | None -> Ok ()
         | Some (w,h) ->
           let* _ = call t session `POST "/window/rect" (Some (`Assoc ["width",`Int w;"height",`Int h])) in Ok ())
      | Browser_lane.Fit {width;height} ->
        if inner_w = width && inner_h = height || attempts = 0 then Ok ()
        else
          let* _ = call t session `POST "/window/rect"
            (Some (`Assoc ["width",`Int (width + outer_w - inner_w);"height",`Int (height + outer_h - inner_h)])) in
          let* measured = measure () in
          if measured = (outer_w, outer_h, inner_w, inner_h) then Ok () else settle (attempts - 1) measured in
    let* () = match size with
      | Browser_lane.Fit _ when not (List.mem_assoc handle session.window_sizes) ->
        session.window_sizes <- (handle,(first_w,first_h)) :: session.window_sizes; Ok ()
      | Browser_lane.Fit _ | Browser_lane.Browser_default -> Ok () in
    let* () = settle 3 start in
    (match size with
     | Browser_lane.Browser_default -> session.window_sizes <- List.remove_assoc handle session.window_sizes
     | Browser_lane.Fit _ -> ());
    let* after = script t session Browser_interaction.viewport_receipt_script [] in
    let* old_url = string_field "url" observed in
    let* after_w = int "innerWidth" after in
    let* after_h = int "innerHeight" after in
    (match size with
     | Browser_lane.Fit {width;height} when after_w <> width || after_h <> height ->
       failure ~started:true (Printf.sprintf
         "Firefox kept the viewport at %d x %d instead of %d x %d; its smallest window is larger than that" after_w after_h width height)
     | Browser_lane.Fit _ | Browser_lane.Browser_default ->
       (match after with
        | `Assoc fields -> Ok (`Assoc (("action",`String "set_viewport")::("urlBefore",`String old_url)::fields))
        | _ -> Error (Protocol "invalid post-resize observation")))
let dialog_text t session =
  match call t session `GET "/alert/text" None with
  | Ok (`String text) -> Ok (`Assoc ["open",`Bool true;"text",`String text])
  | Error (Remote {code=No_such_alert;_}) -> Ok (`Assoc ["open",`Bool false])
  | Ok _ -> Error (Protocol "invalid dialog text response")
  | Error ((Transport _ | Protocol _
           | Remote { code = Invalid_session_id | No_such_window | Unexpected_alert_open | Other _; _ }) as error) -> Error error
let element_call perform_effect id suffix body =
  perform_effect `POST ("/element/" ^ Uri.pct_encode id ^ suffix) (Some body)
(* Environment emulation goes over the session's own BiDi connection: WebDriver
   classic has no call for it. Firefox 158 accepts a location, a locale and a
   time zone per browsing context (the classic window handle is that context's
   id), but resetting a locale or time zone with null leaves the override in
   place (probed). Clearing therefore sets the values the tab had before its
   first override, which the page cannot tell from no override. *)
let current_window t session = match call t session `GET "/window" None with
  | Ok (`String handle) -> Ok handle
  | Ok _ -> Error (Protocol "invalid current browser window")
  | Error error -> Error error
let emulate t session ~started emulation =
  let* connection = Result.map_error (fun detail -> Protocol detail) session.downloads in
  let send method_ params =
    started ();
    Result.map_error (fun detail -> Protocol (method_ ^ ": " ^ detail)) (connection.Browser_downloads.command method_ params) in
  let* handle = current_window t session in
  let contexts = ["contexts", `List [`String handle]] in
  let grant_geolocation () =
    let* origin = script t session "return location.origin;" [] in
    let origin = match origin with `String origin when origin <> "null" -> Some origin | _ -> None in
    match origin with
    | None -> Ok ()
    | Some origin ->
      let* _ = send "permissions.setPermission" (`Assoc ["descriptor",`Assoc ["name",`String "geolocation"];
        "state",`String "granted";"origin",`String origin]) in Ok () in
  let remember_originals () =
    if List.mem_assoc handle session.emulated then Ok ()
    else
      let* seen = script t session "return {locale: navigator.language, timezone: Intl.DateTimeFormat().resolvedOptions().timeZone};" [] in
      let* locale = string_field "locale" seen in
      let* timezone = string_field "timezone" seen in
      session.emulated <- (handle,(locale,timezone)) :: session.emulated; Ok () in
  match emulation with
  | Some {Browser_lane.Action.geolocation; locale; timezone} ->
    let* () = if locale <> None || timezone <> None then remember_originals () else Ok () in
    let* () = match geolocation with
      | None -> Ok ()
      | Some {Browser_lane.Action.latitude; longitude; accuracy_m} ->
        let* () = grant_geolocation () in
        let* _ = send "emulation.setGeolocationOverride" (`Assoc (("coordinates",`Assoc
          ["latitude",`Float latitude;"longitude",`Float longitude;"accuracy",`Float accuracy_m]) :: contexts)) in
        Ok () in
    let* () = match locale with
      | None -> Ok ()
      | Some locale -> let* _ = send "emulation.setLocaleOverride" (`Assoc (("locale",`String locale) :: contexts)) in Ok () in
    let* () = match timezone with
      | None -> Ok ()
      | Some timezone -> let* _ = send "emulation.setTimezoneOverride" (`Assoc (("timezone",`String timezone) :: contexts)) in Ok () in
    Ok (`Assoc ["emulated",`Assoc
      ((match geolocation with
        | Some {Browser_lane.Action.latitude; longitude; accuracy_m} ->
          ["geolocation",`Assoc ["latitude",`Float latitude;"longitude",`Float longitude;"accuracyMeters",`Float accuracy_m]]
        | None -> [])
       @ Option.to_list (Option.map (fun l -> "locale",`String l) locale)
       @ Option.to_list (Option.map (fun z -> "timezone",`String z) timezone));
      "note",`String ("a page that already read its location, language or time zone keeps what it read; reload to see the new ones"
        ^ (match geolocation with None -> "" | Some _ ->
          "; the current origin geolocation grant persists in this owned browser session after clearing overrides"))])
  | None ->
    let* _ = send "emulation.setGeolocationOverride" (`Assoc (("coordinates",`Null) :: contexts)) in
    let* () = match List.assoc_opt handle session.emulated with
      | None -> Ok ()
      | Some (locale,timezone) ->
        let* _ = send "emulation.setLocaleOverride" (`Assoc (("locale",`String locale) :: contexts)) in
        let* _ = send "emulation.setTimezoneOverride" (`Assoc (("timezone",`String timezone) :: contexts)) in
        session.emulated <- List.remove_assoc handle session.emulated; Ok () in
    Ok (`Assoc ["cleared",`Bool true;"permissionsUnchanged",`Bool true;
      "note",`String "clearing restores environment overrides only; geolocation permission grants remain until this owned browser session closes"])
(* A block is a BiDi intercept on the tab's context, which the connection
   fails request by request. The session keeps which intercepts belong to
   which tab, so unblocking one tab leaves the others' blocks in place. *)
let block_requests t session ~started hosts =
  let* connection = Result.map_error (fun detail -> Protocol detail) session.downloads in
  let* handle = current_window t session in
  match hosts with
  | Some hosts ->
    started ();
    let* intercept = Result.map_error (fun detail -> Protocol ("network.addIntercept: " ^ detail))
        (connection.Browser_downloads.block ~context:handle ~hosts) in
    session.blocks <- (handle, intercept) :: session.blocks;
    Ok (`Assoc ["blocked",`List (List.map (fun host -> `String host) hosts);
      "note",`String "requests from this tab and its frames to these hosts now fail as network errors until unblock_requests or the session closes; a request already sent is not affected"])
  | None ->
    let rec remove count = function
      | [] -> Ok (`Assoc ["unblocked",`Int count])
      | intercept :: rest ->
        started ();
        let* () = Result.map_error (fun detail -> Protocol ("network.removeIntercept: " ^ detail))
            (connection.Browser_downloads.unblock ~intercept) in
        session.blocks <- List.filter (fun block -> block <> (handle, intercept)) session.blocks;
        remove (count + 1) rest in
    remove 0 (List.filter_map (fun (tab, intercept) -> if tab = handle then Some intercept else None) session.blocks)
let interact t session ~perform_effect ~started = function
  | Browser_lane.Action.Set_emulation emulation -> emulate t session ~started (Some emulation)
  | Browser_lane.Action.Clear_emulation -> emulate t session ~started None
  | Browser_lane.Action.Block_requests hosts -> block_requests t session ~started (Some hosts)
  | Browser_lane.Action.Unblock_requests -> block_requests t session ~started None
  | Browser_lane.Action.Upload {target = Browser_lane.Action.Chooser_opener _; _} ->
    Error (Protocol "the automation Firefox sets files on a file input only; name it with selector")
  | Browser_lane.Action.Upload {target = Browser_lane.Action.File_input selector; paths} ->
    let* id = element_id t session selector in
    let element = `Assoc ["element-6066-11e4-a52e-4f735466cecf",`String id] in
    let* is_file = script t session "return arguments[0].localName==='input' && arguments[0].type==='file';" [element] in
    let* () = if is_file = `Bool true then Ok () else Error (Protocol "upload requires a file input") in
    Browser_lane.Upload_lease.claim ~owner:session.uploads ~paths;
    let* _ = element_call perform_effect id "/clear" (`Assoc []) in
    element_call perform_effect id "/value" (`Assoc ["text",`String (String.concat "\n" paths)])
  | Browser_lane.Action.Accept_dialog text ->
    let* _ = call t session `GET "/alert/text" None in
    let* _ = match text with
      | None -> Ok `Null
      | Some text -> perform_effect `POST "/alert/text" (Some (`Assoc ["text",`String text])) in
    perform_effect `POST "/alert/accept" (Some (`Assoc []))
  | Browser_lane.Action.Dismiss_dialog ->
    let* _ = call t session `GET "/alert/text" None in
    perform_effect `POST "/alert/dismiss" (Some (`Assoc []))
  | Browser_lane.Action.Set_cookie {name;value;path;secure;http_only;same_site;max_age_sec} ->
    (* The cookie is scoped to the tab's current document by the driver; the
       value is the caller's and is never part of the answer. *)
    let expiry = match max_age_sec with
      | Some age -> ["expiry",`Int (int_of_float (Unix.gettimeofday ()) + age)] | None -> [] in
    let cookie = `Assoc (["name",`String name;"value",`String value;"path",`String path;
      "secure",`Bool secure;"httpOnly",`Bool http_only]
      @ (match same_site with Some site -> ["sameSite",`String (Browser_lane.Action.same_site_wire site)] | None -> [])
      @ expiry) in
    let* _ = perform_effect `POST "/cookie" (Some (`Assoc ["cookie",cookie])) in
    Ok (`Assoc ["name",`String name;"path",`String path;"secure",`Bool secure;"httpOnly",`Bool http_only;
                "sessionCookie",`Bool (max_age_sec = None);"valueWithheld",`Bool true])
  | Browser_lane.Action.Delete_cookie name ->
    let* _ = perform_effect `DELETE ("/cookie/" ^ Uri.pct_encode ~component:`Path name) None in
    Ok (`Assoc ["name",`String name])
  | Browser_lane.Action.Back -> perform_effect `POST "/back" (Some (`Assoc []))
  | Browser_lane.Action.Forward -> perform_effect `POST "/forward" (Some (`Assoc []))
  | Browser_lane.Action.Reload -> perform_effect `POST "/refresh" (Some (`Assoc []))
  | Browser_lane.Action.Close_tab -> perform_effect `DELETE "/window" None
type effect_phase = Not_started | Started
let execute_action t action =
  let phase = ref Not_started in
  let perform_effect session method_ path body =
    phase := Started;
    call t session method_ path body in
  let result = match action with
  | Browser_lane.Action.Control (Browser_lane.Action.Hand_off | Browser_lane.Action.Take_over | Browser_lane.Action.Space_status | Browser_lane.Action.Finish_space _ | Browser_lane.Action.Wait_for_control _ | Browser_lane.Action.Adopt_tab _ | Browser_lane.Action.Release_tab _) ->
    Error (Protocol Browser_lane.handoff_refused)
  | (Browser_lane.Action.Open_tab url | Browser_lane.Action.Open_window url) as opening ->
    let kind = match opening with
      | Browser_lane.Action.Open_window _ -> "window"
      | Browser_lane.Action.Open_tab _ | Browser_lane.Action.Control _ | Browser_lane.Action.On_tab _ -> "tab" in
    let* () = absolute_http_url url in
    let* session = session t in
    let* _ = match call t session `GET "/window" None with
      | Error (Remote {code=No_such_window;_}) ->
        let* handles = call t session `GET "/window/handles" None in
        (match handles with
         | `List (`String handle :: _) -> select t session handle
         | _ -> Error (Protocol "no surviving browser window; reopen the session"))
      | (Error (Remote { code = (Invalid_session_id | (No_such_alert | (Unexpected_alert_open | Other _)));_}) | Error (Transport _ | Protocol _) | Ok _) as result -> result in
    let* created = perform_effect session `POST "/window/new" (Some (`Assoc ["type",`String kind])) in
    let* handle = string_field "handle" created in
    let id = tab_id t session handle in
    let navigate () =
      let* _ = select t session handle in
      let* _ = call t session `POST "/url" (Some (`Assoc ["url",`String url])) in
      page_summary t session in
    (match navigate () with
     | Ok summary -> Ok (`Assoc ["tabId",`Int id;"page",summary])
     | Error (Remote {code=Unexpected_alert_open;_}) ->
       (* The tab was created, and its document is waiting on a user prompt.
          Retain the identity without claiming that navigation completed. *)
       Ok (`Assoc ["tabId",`Int id;"navigation",`String "blocked_by_dialog";"requested_url",`String url])
     | Error ((Transport _ | Protocol _
              | Remote { code = Invalid_session_id | No_such_window | No_such_alert | Other _; _ }) as error) -> Error (error_at_tab id error))
  | Browser_lane.Action.On_tab {tab_id=id;frame_path;interaction} ->
    let* session = session t in
    with_tab t session (Some id) (fun () ->
      let* () = enter_frames t session frame_path in
      let* result = interact t session ~perform_effect:(perform_effect session) ~started:(fun () -> phase := Started) interaction in
      match interaction with
      | Browser_lane.Action.Close_tab ->
        session.handles <- List.filter (fun (_,known) -> known <> id) session.handles;
        (match result with `List [] -> t.session <- None; Atomic.set t.observed_session Browser_lane.Browser_closed; release_resources t session | _ -> ());
        Ok (`Assoc ["tabId",`Int id;"closed",`Bool true])
      | Browser_lane.Action.Dismiss_dialog | Browser_lane.Action.Back | Browser_lane.Action.Forward
      | Browser_lane.Action.Reload | Browser_lane.Action.Upload _ | Browser_lane.Action.Accept_dialog _
      | Browser_lane.Action.Set_cookie _ | Browser_lane.Action.Delete_cookie _
      | Browser_lane.Action.Set_emulation _ | Browser_lane.Action.Clear_emulation
      | Browser_lane.Action.Block_requests _ | Browser_lane.Action.Unblock_requests ->
        (* Do not issue another fallible browser request after an effect.
           The caller observes the resulting page with a separate read. *)
        Ok (`Assoc ["tabId",`Int id;"performed",`Bool true;"result",result]))
  in result, !phase
(* The remote end's own answer to "can a session be created now" (W3C
   WebDriver, Status: [ready] and [message]). A driver that does not answer is
   reported in place, so a status call never fails because of it. *)
let driver_status t =
  match t.request ~method_:`GET ~path:"/status" ~body:None with
  | Error error -> `Assoc [ "error", `String (error_message error) ]
  | Ok value ->
    match field "ready" value, field "message" value with
    | Some (`Bool ready), Some (`String message) ->
      `Assoc [ "ready", `Bool ready; "message", `String message ]
    | (Some _ | None), (Some _ | None) ->
      `Assoc [ "error", `String "WebDriver /status answered without ready and message" ]

let native_keyboard t session ~args ~action_name sources =
  match script t session (Browser_scene_script.runtime ^ Browser_interaction.keyboard_guard_script) [args] with
  | Error error -> Ok (`Assoc ["interactionFailure", `Assoc
      ["message",`String (error_message error);"effectStarted",`Bool false]])
  | Ok before ->
    let released = ref None in
    let applied = Eio.Switch.run (fun sw ->
      Eio.Switch.on_release sw (fun () ->
        let result = call t session `DELETE "/actions" None in
        (match result with Ok _ -> session.pointer_state <- Released | Error _ -> ());
        released := Some result);
      session.pointer_state <- Release_required;
      call t session `POST "/actions" (Some (`Assoc ["actions",sources]))) in
    let* _ = applied in
    let* () = match !released with Some result -> Result.map (fun _ -> ()) result
      | None -> Error (Protocol "keyboard cleanup did not run") in
    let* after = script t session Browser_interaction.pointer_receipt_script [] in
    let* url_before = string_field "url" before in
    match after with
    | `Assoc fields -> Ok (`Assoc (("urlBefore",`String url_before)::("action",`String action_name)::fields))
    | _ -> Error (Protocol "invalid keyboard receipt")

(* The source of the document [session] currently shows, as tab [id]. *)
let read_document t session id =
  let* data = script t session
    (Browser_scene_script.runtime ^ "\n" ^ Browser_lane.Document.runtime
     ^ "\nreturn browserDocument();") [] in
  match data with
  | `Assoc fields -> Ok (`Assoc (("tabId", `Int id)
      :: ("clientId", `String ("automation:" ^ session.id)) :: fields))
  | _ -> Error (Protocol "invalid document observation")
let rec execute_unlocked t = function
  | Browser_lane.Session_open { headless } ->
    (match t.session with
     | Some _ ->
       let* _ = session t |> Result.map_error (fun error ->
         (match t.session with None -> () | Some _ -> Atomic.set t.observed_session Browser_lane.Browser_unknown);error) in
       Ok (`Assoc ["opened", `Bool true; "reused", `Bool true])
     | None ->
       let* profile = match t.profiles with
         | None -> Ok None
         | Some profiles -> profiles.fresh () |> Result.map Option.some
           |> Result.map_error (fun detail -> Protocol ("the session profile was not created: " ^ detail)) in
       let args = (if Option.value ~default:true headless then [`String "-headless"] else [])
         @ (match profile with None -> [] | Some path -> [`String "-profile"; `String path]) in
       let caps = `Assoc ["capabilities", `Assoc ["alwaysMatch", `Assoc
         ["browserName", `String "firefox";
          "webSocketUrl", `Bool true;
          "unhandledPromptBehavior", `String "ignore";
          "moz:firefoxOptions", `Assoc (("args", `List args) ::
            ("prefs", `Assoc Browser_gecko_profile.resource_guard_prefs) ::
            (Option.map (fun path -> "binary", `String path) t.binary |> Option.to_list))]]] in

       Atomic.set t.observed_session Browser_lane.Browser_changing;
       let* result = match t.request ~method_:`POST ~path:"/session" ~body:(Some caps) with
         | Ok result -> Atomic.set t.observed_session Browser_lane.Browser_unknown;Ok result
         | Error (Remote _ as error) ->
           Atomic.set t.observed_session Browser_lane.Browser_closed;profile_ended t profile;Error error
         | Error ((Transport _ | Protocol _) as error) ->
           Atomic.set t.observed_session Browser_lane.Browser_unknown;profile_ended t profile;t.lost ();Error error
         | exception exn ->
           Atomic.set t.observed_session Browser_lane.Browser_unknown;profile_ended t profile;t.lost ();raise exn in
       let* id = match string_field "sessionId" result with
         | Ok _ as id -> id
         | Error _ as missing -> profile_ended t profile;t.lost ();missing in
       let owned = { pointer_state = Released; id; handles = []; window_sizes = []; emulated = []; blocks = []; uploads = Browser_lane.Upload_lease.create_owner (); download_contexts = []; downloads = Error "BiDi setup incomplete; close this session before retrying"; profile } in
       t.session <- Some owned;
       Eio.Switch.run (fun setup_sw ->
         let committed = ref false in
         Eio.Switch.on_release setup_sw (fun () ->
           if not !committed then
             match close_unlocked t with
             | Ok () -> ()
             | Error error -> owned.downloads <- Error
                 ("BiDi setup incomplete; session cleanup failed: " ^ error_message error));
         let* capabilities = match field "capabilities" result with
           | Some value -> Ok value | None -> Error (Protocol "Firefox omitted capabilities") in
         (* geckodriver reaches the browser through the Marionette port the
            given profile reports; a session whose browser runs another
            profile is not the one this client started. *)
         let* () = match profile, field "moz:profile" capabilities with
           | None, (Some _ | None) -> Ok ()
           | Some expected, Some (`String reported) when String.equal reported expected -> Ok ()
           | Some expected, Some (`String reported) ->
             Error (Protocol (Printf.sprintf "Firefox runs profile %s, not this session's profile %s" reported expected))
           | Some _, Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) | Some _, None ->
             Error (Protocol "Firefox did not report the session's moz:profile") in
         let* websocket_url = string_field "webSocketUrl" capabilities in
         let* downloads = Result.map_error (fun detail -> Protocol ("Firefox download setup failed: " ^ detail))
           (t.start_downloads ~session_id:id ~websocket_url) in
         owned.downloads <- Ok downloads;
         committed := true;
         Atomic.set t.observed_session Browser_lane.Browser_open;
         Ok (`Assoc ["opened", `Bool true; "reused", `Bool false; "backend", `String "firefox-webdriver"])))
  | Browser_lane.Session_close ->
    let* () = close_unlocked t in Ok (`Assoc ["closed", `Bool true])
  | Browser_lane.Session_status ->
    (* Reports the backend's own record, and never fails on a closed session.
       With no session open it adds the driver's own status. On 2026-09-15
       three Keepers read a bare {"open":false} as a broken lane, and that
       morning the same answer hid a driver still holding a session this record
       did not know, which /status reports as ready=false, "Session already
       started". [downloads] is reported because a session can be open with
       BiDi setup incomplete, and every later download call refuses with that
       detail. *)
    (match t.session with
     | None -> Ok (`Assoc ["open", `Bool false; "driver", driver_status t])
     | Some session ->
       Ok (`Assoc
         [ "open", `Bool true
         ; "sessionId", `String session.id
         ; "tabs", `Int (List.length session.handles)
         ; "downloads",
           (match session.downloads with
            | Ok _ -> `String "ready"
            | Error detail -> `String detail)
         ]))
  | Browser_lane.Page_downloads {tab_id=id} ->
    (* Retain readable interruption evidence even when further actions refuse. *)
    (match t.session with
     | None -> Error (Protocol "Firefox session is closed")
     | Some session ->
       let* downloads = Result.map_error (fun detail -> Protocol detail) session.downloads in
       match List.find_opt (fun (_, known) -> known = id) session.download_contexts with
       | None -> Error (Protocol "unknown tab id; refresh the tab list")
       | Some (context, _) ->
         Result.map_error (fun detail -> Protocol detail) (downloads.read ~context))
  | Browser_lane.Page_console {tab_id=id} ->
    (match t.session with
     | None -> Error (Protocol "Firefox session is closed")
     | Some session ->
       let* events = Result.map_error (fun detail -> Protocol detail) session.downloads in
       match List.find_opt (fun (_, known) -> known = id) session.download_contexts with
       | None -> Error (Protocol "unknown tab id; refresh the tab list")
       | Some (context, _) ->
         let* data = Result.map_error (fun detail -> Protocol detail) (events.console ~context) in
         Ok (match data with `Assoc fields -> `Assoc (("tabId",`Int id)::fields) | other -> other))
  | Browser_lane.Page_network {tab_id=id} ->
    (match t.session with
     | None -> Error (Protocol "Firefox session is closed")
     | Some session ->
       let* events = Result.map_error (fun detail -> Protocol detail) session.downloads in
       match List.find_opt (fun (_, known) -> known = id) session.download_contexts with
       | None -> Error (Protocol "unknown tab id; refresh the tab list")
       | Some (context, _) ->
         let* data = Result.map_error (fun detail -> Protocol detail) (events.network ~context) in
         Ok (match data with `Assoc fields -> `Assoc (("tabId",`Int id)::fields) | other -> other))
  | Browser_lane.Page_cookies {tab_id=id} ->
    (* The driver returns the cookies of the current page, values included. They are removed here, before
       anything leaves this module. *)
    let* session = session t in
    with_tab t session (Some id) (fun () ->
      let* cookies = call t session `GET "/cookie" None in
      let* projected = Result.map_error (fun detail -> Protocol detail) (Browser_cookies.of_driver cookies) in
      (* Web storage names ride on the same read. A page that forbids storage
         (a sandboxed frame, a data: URL) reports that area's error instead of
         failing the cookie read. *)
      let* web = script t session Browser_cookies.storage_script [] in
      let indexeddb = match call t session `POST "/execute/async"
          (Some (`Assoc ["script",`String Browser_cookies.indexeddb_script;"args",`List []])) with
        | Ok answer -> answer
        | Error error -> `Assoc ["error",`String (error_message error)] in
      let reply = Browser_cookies.with_storage ~web ~indexeddb projected in
      Ok (match reply with `Assoc fields -> `Assoc (("tabId",`Int id)::fields) | other -> other))
  | Browser_lane.Page_goto { url; tab_id } ->
    let* () = absolute_http_url url in
    let* session = session t in
    with_tab t session tab_id (fun () ->
      let* _ = call t session `POST "/url" (Some (`Assoc ["url", `String url])) in
      page_summary t session)
  | Browser_lane.Page_act action -> fst (execute_action t action)
  | Browser_lane.Page_scene {tab_id=id;max_chars;view;scope} ->
    let* session = session t in
    with_tab t session (Some id) (fun () ->
      let args = match Browser_lane.scene_args ~tab_id:id ~max_chars ~view ~scope with
        | `Assoc fields -> `Assoc (("mode",`String "read")::fields) | json -> json in
      let* data = script t session Browser_scene_script.read [args] in
      match data with
      | `Assoc fields -> Ok (`Assoc (("tabId",`Int id) :: fields))
      | _ -> Error (Protocol "malformed semantic scene"))
  | Browser_lane.Page_elements {tab_id=target_tab_id;filter} ->
    let* session = session t in
    with_tab t session target_tab_id (fun () ->
      let* handle = call t session `GET "/window" None in
      let* handle = match handle with `String value -> Ok value | _ -> Error (Protocol "invalid current window") in
      let* data = script t session Browser_page_script.elements [Browser_page_script.elements_args filter] in
      match data with
      | `Assoc fields -> Ok (`Assoc (("tabId",`Int (tab_id t session handle)) :: fields))
      | _ -> Error (Protocol "malformed elements observation"))
  | Browser_lane.Page_context {tab_id=id;frame_path;mode} ->
    let* session = session t in
    with_tab t session (Some id) (fun () ->
      let* () = enter_frames t session frame_path in
      let* data = match mode with
        | `Dialog -> dialog_text t session
        | `Elements filter -> script t session Browser_page_script.elements [Browser_page_script.elements_args filter]
        | `Frames -> script t session Browser_page_script.frames []
        | `Text cap ->
          let* cap = Result.map_error (fun detail -> Protocol detail) (Browser_page_script.text_cap (Some cap)) in
          script t session Browser_page_script.text [`Int cap] in
      match data with
      | `Assoc fields -> Ok (`Assoc (["tabId",`Int id;"framePath",`List (List.map (fun s -> `String s) frame_path)] @ fields))
      | _ -> Error (Protocol "invalid contextual observation"))
  | Browser_lane.Page_read { tab_id; max_chars } ->
    let* session = session t in
    with_tab t session tab_id (fun () ->
      let* cap = Result.map_error (fun detail -> Protocol detail) (Browser_page_script.text_cap max_chars) in
      script t session Browser_page_script.text [`Int cap])
  (* A caller's read selects its tab, which also leaves any frame, as the
     other reads do. The idle observer reads without selecting
     ([observe_document_if_idle]). *)
  | Browser_lane.Page_document {tab_id=id} ->
    let* session = session t in
    with_tab t session (Some id) (fun () -> read_document t session id)
  | Browser_lane.Page_interact { tab_id; frame_path; expected_url; action } ->
    let* session = session t in
    with_tab t session (Some tab_id) (fun () ->
      let args = Browser_lane.interaction_args ~tab_id ~frame_path ~expected_url action in
      let action_name = Browser_lane.interaction_verb action in
      (* Inside a frame the script and the native pointer both use the frame's
         own viewport coordinates (probed on Firefox 158 through geckodriver). *)
      let native_action = match enter_frames t session frame_path with
        | Error error -> Error error
        | Ok () ->
          if Browser_interaction.needs_pointer_resolution action then
            let* resolved = script t session (Browser_scene_script.runtime ^ Browser_interaction.pointer_target_script) [args] in
            Result.map_error (fun message -> Protocol message)
              (Browser_interaction.resolve_pointer_input action resolved)
          else Ok (expected_url,action) in
      let* result = match native_action with
        | Error error -> Ok (`Assoc ["interactionFailure",`Assoc
            ["message",`String (error_message error);"effectStarted",`Bool false]])
        | Ok (expected_url,action) ->
        let args = Browser_lane.interaction_args ~tab_id ~frame_path ~expected_url action in
        match action with
        | Browser_lane.Set_zoom _ -> Error (Protocol "set_zoom requires a connected WebExtension browser")
        | Browser_lane.Set_viewport size -> set_viewport t session size args
        | Browser_lane.Double_click _ | Browser_lane.Hover _ | Browser_lane.Drag_to _ | Browser_lane.Click _ | Browser_lane.Click_node _ ->
          Error (Protocol "unresolved semantic pointer target")
        | Browser_lane.Click_target _ | Browser_lane.Fill_target _ | Browser_lane.Hover_target _ | Browser_lane.Double_click_target _ -> Error (Protocol Browser_lane.snapshot_target_refused)
        | Browser_lane.Type_text {text;_} ->
          (match Browser_lane.Keyboard.text_source ~id:"masc-browser-keyboard" text with
           | Error message -> Ok (`Assoc ["interactionFailure", `Assoc ["message",`String message;"effectStarted",`Bool false]])
           | Ok sources -> native_keyboard t session ~args ~action_name sources)
        | Browser_lane.Press_key {key;_} ->
          native_keyboard t session ~args ~action_name
            (Browser_lane.Keyboard.input_source ~id:"masc-browser-keyboard" key)
        | Browser_lane.Double_click_at {point;viewport}
        | Browser_lane.Hover_at {point;viewport}
        | Browser_lane.Click_at {point;viewport;_}
        | Browser_lane.Tap_at {point;viewport}
        | Browser_lane.Scroll_at {point;viewport;_}
        | Browser_lane.Swipe {from=point;viewport;_}
        | Browser_lane.Drag {from=point;viewport;_} ->
          (* The guard runs before any /actions request, so a stale URL or
             viewport cannot have moved the pointer. [execute] turns this
             payload into [Rejected_before_effect]. *)
          (match script t session (Browser_scene_script.runtime ^ Browser_interaction.pointer_guard_script) [args] with
          | Error error ->
            Ok (`Assoc ["interactionFailure", `Assoc
              ["message", `String (error_message error); "effectStarted", `Bool false]])
          | Ok before ->
          let gesture = match action with
            | Browser_lane.Hover_at _ -> Browser_lane.Pointer.Hover
            | Browser_lane.Double_click_at _ -> Browser_lane.Pointer.Double_click
            | Browser_lane.Drag {to_;via;duration_ms;_} -> Browser_lane.Pointer.Drag {via;destination=to_;duration_ms}
            | Browser_lane.Scroll_at {x;y;_} -> Browser_lane.Pointer.Wheel {x;y}
            | Browser_lane.Click_at {button;_} -> Browser_lane.Pointer.Click button
            | Browser_lane.Tap_at _ -> Browser_lane.Pointer.Tap
            | Browser_lane.Swipe {to_;via;duration_ms;_} -> Browser_lane.Pointer.Swipe {via;destination=to_;duration_ms}
            | Browser_lane.Set_zoom _ | Browser_lane.Set_viewport _ | Browser_lane.Double_click _ | Browser_lane.Type_text _ | Browser_lane.Press_key _
            | Browser_lane.Hover _ | Browser_lane.Drag_to _
            | Browser_lane.Activate_tab | Browser_lane.Click _ | Browser_lane.Fill _ | Browser_lane.Select_option _
            | Browser_lane.Scroll _ | Browser_lane.Follow_link _
            | Browser_lane.Click_node _ | Browser_lane.Fill_node _
            | Browser_lane.Click_target _ | Browser_lane.Fill_target _ | Browser_lane.Hover_target _ | Browser_lane.Double_click_target _ -> Browser_lane.Pointer.Click Browser_lane.Pointer.Primary in
          let actions = `Assoc ["actions", Browser_lane.Pointer.input_sources
            ~pointer_id:"masc-browser-pointer" ~wheel_id:"masc-browser-wheel"
            ~viewport ~start:point gesture] in
          (* Release even if transport cancellation interrupts a pressed gesture.
             The enclosing session lock remains held throughout cleanup. *)
          let applied, released = match action with
            | Browser_lane.Hover_at _ | Browser_lane.Scroll_at _ ->
                (* Hover and wheel actions do not press buttons. Session acquisition
                   already recovers any older pending pointer release. *)
                call t session `POST "/actions" (Some actions), Ok ()
            | Browser_lane.Double_click _ | Browser_lane.Set_zoom _ | Browser_lane.Set_viewport _ | Browser_lane.Double_click_at _ | Browser_lane.Type_text _ | Browser_lane.Press_key _
            | Browser_lane.Hover _ | Browser_lane.Drag_to _
            | Browser_lane.Activate_tab | Browser_lane.Click _ | Browser_lane.Fill _ | Browser_lane.Select_option _
            | Browser_lane.Scroll _ | Browser_lane.Click_at _ | Browser_lane.Drag _
            | Browser_lane.Tap_at _ | Browser_lane.Swipe _
            | Browser_lane.Follow_link _ | Browser_lane.Click_node _ | Browser_lane.Fill_node _
            | Browser_lane.Click_target _ | Browser_lane.Fill_target _ | Browser_lane.Hover_target _ | Browser_lane.Double_click_target _ -> let released = ref None in
            let applied = Eio.Switch.run (fun sw ->
              Eio.Switch.on_release sw (fun () ->
                let result = call t session `DELETE "/actions" None in
                (match result with Ok _ -> session.pointer_state <- Released | Error _ -> ());
                released := Some result);
              session.pointer_state <- Release_required;
              call t session `POST "/actions" (Some actions)) in
            applied, (match !released with Some result -> Result.map (fun _ -> ()) result
              | None -> Error (Protocol "pointer cleanup did not run")) in
          let* _ = applied in
          let* _ = released in
          let* after = script t session Browser_interaction.pointer_receipt_script [] in
          let* url_before = string_field "url" before in
          (match after with
           | `Assoc fields -> Ok (`Assoc (("urlBefore",`String url_before) ::
               ("action",`String action_name) :: fields))
           | _ -> Error (Protocol "invalid pointer receipt")))
        | Browser_lane.Activate_tab | Browser_lane.Fill _ | Browser_lane.Select_option _
        | Browser_lane.Scroll _ | Browser_lane.Follow_link _
        | Browser_lane.Fill_node _ -> script t session (Browser_scene_script.runtime ^ Browser_interaction.script) [args]
      in
      match result with
      | `Assoc fields ->
        (* A framed receipt reports the frame chain, because its [url] is the
           innermost frame document's URL, not the tab's. *)
        let framed = if frame_path = [] then []
          else ["framePath", `List (List.map (fun selector -> `String selector) frame_path)] in
        Ok (`Assoc (("tabId", `Int tab_id) :: framed @ fields))
      | _ -> Error (Protocol "invalid interaction response"))
  | Browser_lane.Page_capture {options=Some _;_} ->
    Error (Protocol "native screenshot options require an Ego connection")
  | Browser_lane.Page_capture { tab_id; options=None } ->
    let* session = session t in
    with_tab t session (Some tab_id) (fun () ->
      let* before = page_summary t session in
      let* url = string_field "url" before in
      let* viewport = script t session (Browser_scene_script.runtime ^ "\nreturn browserScene({mode:'viewport'});") [] in
      let* image = call t session `GET "/screenshot" None in
      let* after = page_summary t session in
      let* after_url = string_field "url" after in
      let* after_viewport = script t session (Browser_scene_script.runtime ^ "\nreturn browserScene({mode:'viewport'});") [] in
      if not (String.equal url after_url) || viewport <> after_viewport then Error (Protocol "viewport changed during capture")
      else match image, field "title" after with
      | `String data, Some (`String title) ->
        Ok (`Assoc ["tabId", `Int tab_id; "title", `String title; "url", `String url;
          "mimeType", `String "image/png"; "data", `String data; "viewport",viewport])
      | _ -> Error (Protocol "invalid screenshot response"))
  | Browser_lane.Page_locate _ ->
    (* [execute] runs locate through [execute_locate], outside this lock
       wrapper: its model wait must not hold the session mutex or the active
       count. Reaching here would mean the dispatch was bypassed. *)
    Error (Protocol "browser locate runs outside the session lock")
  | Browser_lane.Page_instruct _ | Browser_lane.Page_extract _ ->
    (* [execute] refuses these before browser I/O. *)
    Error (Protocol Browser_lane.sentence_verbs_refused)
  | Browser_lane.Page_native_workflow _ -> Error (Protocol "native workflows require an ego connection")
  | Browser_lane.Page_snapshot _ -> Error (Protocol Browser_lane.snapshot_refused)
  | Browser_lane.Tabs_list ->
    let* session = session t in
    let* handles = call t session `GET "/window/handles" None in
    let* current = match call t session `GET "/window" None with
      | Error (Remote { code = No_such_window; _ }) -> Ok `Null
      | (Error (Remote { code = (Invalid_session_id | (No_such_alert | (Unexpected_alert_open | Other _)));_}) | Error (Transport _ | Protocol _) | Ok _) as result -> result in
    match current, handles with
    | (`String _ | `Null), `List handles ->
      let original = match current with `String handle -> Some handle | _ -> None in
      (* A window can close while others survive; discovery must remain
         usable even when WebDriver's current window no longer exists. *)
      let target = match original with
        | Some handle when List.mem (`String handle) handles -> Some handle
        | _ -> (match handles with `String handle :: _ -> Some handle | _ -> None) in
      let rec read acc = function
        | [] -> Ok (`List (List.rev acc))
        | `String handle :: rest ->
          let id = tab_id t session handle in
          let* _ = select t session handle |> Result.map_error (error_at_tab id) in
          let* summary = page_summary t session |> Result.map_error (error_at_tab id) in
          (match summary with
           | `Assoc fields ->
             let tab = `Assoc (("id", `Int (tab_id t session handle)) ::
               ("active", `Bool (Some handle = target)) :: fields) in
             read (tab :: acc) rest
           | _ -> Error (Protocol "invalid page summary"))
        | _ -> Error (Protocol "invalid WebDriver window handle")
      in
      let result = read [] handles in
      let restored = match target with
        | None -> Ok `Null
        | Some handle ->
          (match select t session handle with
           | Error (Remote { code = No_such_window; _ }) -> Ok `Null
           | (Error (Remote { code = (Invalid_session_id | (No_such_alert | (Unexpected_alert_open | Other _)));_}) | Error (Transport _ | Protocol _) | Ok _) as result -> result) in
      (match result, restored with
       | Error error, _ | _, Error error -> Error error
       | Ok tabs, Ok _ -> Ok tabs)
    | _ -> Error (Protocol "invalid WebDriver windows response")
(* [Page_locate] answers from two scene reads with a model call between them.
   The model call can outlive the caller's patience, so it must not hold the
   session lock: each read takes the lock for the read alone, and the model
   wait runs with no lock and no active count held. *)
let execute_locate t ~tab_id ~instruction =
  let* locate=Option.to_result ~none:(Protocol "browser locate Exact Output is not selected") t.locate in
  let* max_chars=Browser_page_script.text_cap None |> Result.map_error (fun detail -> Protocol detail) in
  let read () =
    with_session_lock t (fun () ->
      let* json=execute_unlocked t (Browser_lane.Page_scene {tab_id;max_chars;view=Content;scope=None}) in
      let* scene=Browser_scene.of_json json |> Result.map_error (fun detail -> Protocol detail) in
      let ids=List.map (fun (node:Browser_scene.node) -> node.node_id) scene.nodes in
      if List.length ids<>List.length (List.sort_uniq String.compare ids) then Error (Protocol "duplicate locate scene reference")
      else Ok (json,scene)) in
  let* _,original=read () in
  let* matches=locate ~scene:original ~instruction |> Result.map_error (fun detail -> Protocol detail) in
  Eio.Fiber.check ();
  let* json,current=read () in
  let* ()=if original.document_id=current.document_id && original.url=current.url then Ok ()
    else Error (Protocol "locate document changed while waiting for its model; read the original tab again") in
  let* raw_nodes=match field "nodes" json with Some (`List nodes) -> Ok nodes
    | None|Some _ -> Error (Protocol "missing current locate nodes") in
  let* matches=List.fold_right (fun (matched:located_node) acc ->
    let* rest=acc in
    let find scene=List.find_opt (fun (node:Browser_scene.node) -> node.node_id=matched.node_id) scene.Browser_scene.nodes in
    match find original,find current with
    | Some before,Some now when before.kind=now.kind && before.tag=now.tag && before.text=now.text
        && before.ancestor_region=now.ancestor_region && before.source_context=now.source_context ->
        let* observation=List.find_opt (fun node -> field "nodeId" node=Some (`String matched.node_id)) raw_nodes
          |> Option.to_result ~none:(Protocol "missing current locate node") in
        Ok (`Assoc ["target",`Assoc ["documentId",`String current.document_id;"nodeId",`String matched.node_id];
          "observation",observation;"inference",`Assoc ["description",`String matched.description]]::rest)
    | (None|Some _),(None|Some _) -> Error (Protocol "locate target changed or was not observed; read the original tab again")) matches (Ok []) in
  let* viewport=field "viewport" json |> Option.to_result ~none:(Protocol "missing current locate viewport") in
  Ok (`Assoc ["tabId",`Int tab_id;"documentId",`String current.document_id;"url",`String current.url;
    "title",`String current.title;"viewport",viewport;"truncated",`Bool current.truncated;
    "matches",`List matches])
let execute t verb =
  match verb with
  | Browser_lane.Page_locate {tab_id;instruction} ->
    (* A locate command may wait on its model until the caller cancels, so it
       takes no session lock here: [execute_locate] locks each scene read
       alone. Holding the lock across the wait stalled every other command on
       this owned browser and made [observe_document_if_idle] report busy. *)
    if Option.is_none t.locate then
      Browser_lane.Rejected_before_effect "browser locate Exact Output is not selected"
    else
      (match execute_locate t ~tab_id ~instruction with
       | Ok data -> Browser_lane.Answered (`Assoc ["ok", `Bool true; "data", data])
       | Error error -> Browser_lane.Refused (error_message error))
  | Browser_lane.Session_open _ | Browser_lane.Session_close
  | Browser_lane.Session_status | Browser_lane.Tabs_list
  | Browser_lane.Page_read _ | Browser_lane.Page_document _
  | Browser_lane.Page_downloads _ | Browser_lane.Page_console _ | Browser_lane.Page_network _ | Browser_lane.Page_cookies _ | Browser_lane.Page_capture _
  | Browser_lane.Page_scene _ | Browser_lane.Page_snapshot _ | Browser_lane.Page_goto _
  | Browser_lane.Page_elements _ | Browser_lane.Page_act _
  | Browser_lane.Page_context _ | Browser_lane.Page_instruct _
  | Browser_lane.Page_extract _ | Browser_lane.Page_interact _ | Browser_lane.Page_native_workflow _ ->
  with_session_lock t (fun () ->
    match verb with
    | Browser_lane.Page_native_workflow _ -> Browser_lane.Rejected_before_effect "native workflows require an ego connection"
    | Browser_lane.Page_interact {action=Browser_lane.Set_zoom _;_} ->
      Browser_lane.Rejected_before_effect "set_zoom requires a connected WebExtension browser"
    | Browser_lane.Page_interact {action=Browser_lane.Activate_tab;_} ->
      Browser_lane.Rejected_before_effect "activate_tab requires live lane; automation observations already select their explicit tab"
    | Browser_lane.Page_interact {action=(Browser_lane.Click_target _ | Browser_lane.Fill_target _ | Browser_lane.Hover_target _ | Browser_lane.Double_click_target _);_} ->
      Browser_lane.Rejected_before_effect Browser_lane.snapshot_target_refused
    | Browser_lane.Page_instruct _ | Browser_lane.Page_extract _ ->
      Browser_lane.Rejected_before_effect Browser_lane.sentence_verbs_refused
    | Browser_lane.Page_snapshot _ -> Browser_lane.Rejected_before_effect Browser_lane.snapshot_refused
    | Browser_lane.Page_act action ->
      (match execute_action t action with
       | Ok data, _ -> Browser_lane.Answered (`Assoc ["ok", `Bool true; "data", data])
       | Error error, Not_started -> Browser_lane.Rejected_before_effect (error_message error)
       | Error error, Started -> Browser_lane.Refused (error_message error))
    | Browser_lane.Tabs_list | Browser_lane.Page_read _ | Browser_lane.Page_document _
    | Browser_lane.Page_downloads _ | Browser_lane.Page_console _ | Browser_lane.Page_network _ | Browser_lane.Page_cookies _ | Browser_lane.Page_capture _ | Browser_lane.Page_scene _
    | Browser_lane.Page_interact
        { action =
            ( Browser_lane.Set_viewport _ | Browser_lane.Double_click _ | Browser_lane.Double_click_at _ | Browser_lane.Type_text _ | Browser_lane.Press_key _
            | Browser_lane.Click _ | Browser_lane.Fill _ | Browser_lane.Select_option _ | Browser_lane.Scroll _
            | Browser_lane.Hover _ | Browser_lane.Drag_to _
            | Browser_lane.Hover_at _ | Browser_lane.Click_at _
            | Browser_lane.Tap_at _ | Browser_lane.Swipe _
            | Browser_lane.Scroll_at _ | Browser_lane.Drag _
            | Browser_lane.Follow_link _ | Browser_lane.Click_node _
            | Browser_lane.Fill_node _ )
        ; _ }
    | Browser_lane.Session_open _ | Browser_lane.Session_close
    | Browser_lane.Session_status | Browser_lane.Page_goto _ | Browser_lane.Page_elements _
    | Browser_lane.Page_context _ | Browser_lane.Page_locate _ ->
      match execute_unlocked t verb with
      | Ok (`Assoc fields as data) ->
          (match verb, List.assoc_opt "interactionFailure" fields with
           | Browser_lane.Page_interact _, Some (`Assoc failure) ->
               let message = match List.assoc_opt "message" failure with
                 | Some (`String message) -> message | _ -> "invalid interaction failure" in
               (match List.assoc_opt "effectStarted" failure with
                | Some (`Bool false) -> Browser_lane.Rejected_before_effect message
                | _ -> Browser_lane.Refused message)
           | (Browser_lane.Page_interact _, Some (`Null | (`List _ | (`Bool _ | (`Float _ | (`Int _ | (`Intlit _ | `String _)))))))
           | (Browser_lane.Page_interact _, None)
           | ((Browser_lane.Page_native_workflow _ | Browser_lane.Tabs_list | (Browser_lane.Session_close | (Browser_lane.Session_status | (Browser_lane.Page_read _ | (Browser_lane.Page_document _ | (Browser_lane.Page_downloads _ | Browser_lane.Page_console _ | Browser_lane.Page_network _ | Browser_lane.Page_cookies _ | (Browser_lane.Page_capture _ | (Browser_lane.Page_scene _ | Browser_lane.Page_snapshot _ | (Browser_lane.Session_open _ | (Browser_lane.Page_goto _ | (Browser_lane.Page_elements _ | (Browser_lane.Page_act _ | (Browser_lane.Page_context _ | (Browser_lane.Page_instruct _ | (Browser_lane.Page_locate _ | Browser_lane.Page_extract _))))))))))))))), _) -> Browser_lane.Answered (`Assoc ["ok", `Bool true; "data", data]))
      | Ok data -> Browser_lane.Answered (`Assoc ["ok", `Bool true; "data", data])
      | Error error -> Browser_lane.Refused (error_message error))

let observe_document_if_idle t ~tab_id =
  if not (Atomic.compare_and_set t.active 0 1) then
    Browser_lane.Refused "optional_document_observation_busy"
  else
    with_registered_session_lock t (fun () ->
      (* This optional reader must not run [session] recovery, select another
         window, or reset a frame merely to acquire its observation. *)
      let observed = match t.session with
        | None -> Error (Protocol "document observation has no existing browser session")
        | Some session when session.pointer_state = Release_required ->
          Error (Protocol "document observation waits for the existing action owner")
        | Some session ->
          let* current = call t session `GET "/window" None in
          (match current with
           | `String handle when List.assoc_opt handle session.handles = Some tab_id ->
             read_document t session tab_id
           | `String _ -> Error (Protocol "document observation never switches the owner's current tab")
           | _ -> Error (Protocol "invalid current browser window")) in
      match observed with
      | Ok data -> Browser_lane.Answered (`Assoc ["ok", `Bool true; "data", data])
      | Error error -> Browser_lane.Refused (error_message error))
