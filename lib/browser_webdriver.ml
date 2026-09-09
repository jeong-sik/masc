type error = Transport of string | Protocol of string | Remote of { code : string; message : string }
type request = method_:Masc_http_client.Pool.http_method -> path:string -> body:Yojson.Safe.t option -> (Yojson.Safe.t, error) result
type pointer_state = Released | Release_required
type session = { mutable pointer_state : pointer_state; uploads : Browser_lane.Upload_lease.owner; id : string; mutable handles : (string * int) list; mutable download_contexts : (string * int) list; mutable downloads : (Browser_downloads.connection, string) result }
type t = { start_downloads : Browser_downloads.start; binary : string option; request : request; mutex : Eio.Mutex.t; mutable session : session option; mutable next_tab : int }
let ( let* ) = Result.bind
let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None
let string_field key json = match field key json with
  | Some (`String value) when value <> "" -> Ok value
  | _ -> Error (Protocol ("missing string field: " ^ key))
let error_message = function
  | Transport message | Protocol message -> message
  | Remote { code; message } -> code ^ ": " ^ message
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
      Error (Remote { code; message })
let create ?binary ~start_downloads ~request () = { start_downloads; binary; request; mutex = Eio.Mutex.create (); session = None; next_tab = 1 }
let path session suffix = "/session/" ^ Uri.pct_encode session.id ^ suffix
let release_resources session =
  Result.iter (fun (d : Browser_downloads.connection) -> d.close ()) session.downloads;
  Browser_lane.Upload_lease.release_owner session.uploads
let call t session method_ suffix body =
  let result = t.request ~method_ ~path:(path session suffix) ~body in
  (match result with
   | Error (Remote { code = "invalid session id"; _ }) -> t.session <- None; release_resources session
   | Ok _ | Error _ -> ());
  result
(* State changes below never yield: cancellation can interrupt remote I/O but
   cannot leave a half-written local session. Explicit ownership releases the
   lock on cancellation without poisoning it as [use_rw] would. *)
let with_session_lock t f =
  Eio.Switch.run (fun sw ->
    Eio.Mutex.lock t.mutex;
    Eio.Switch.on_release sw (fun () -> Eio.Mutex.unlock t.mutex);
    f ())
let close_unlocked ?request t = match t.session with
  | None -> Ok ()
  | Some session ->
    let request = Option.value ~default:t.request request in
    let result = request ~method_:`DELETE ~path:(path session "") ~body:None in
    match result with
    | Ok _ | Error (Remote { code = "invalid session id"; _ }) -> t.session <- None; release_resources session; Ok ()
    | Error error -> Error error
let close ?request t = with_session_lock t (fun () -> close_unlocked ?request t)
let session t = match t.session with
  | Some session ->
    let* () = match session.pointer_state with
      | Released -> Ok ()
      | Release_required ->
        let* _ = call t session `DELETE "/actions" None in
        session.pointer_state <- Released;
        Ok () in
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
let dialog_text t session =
  match call t session `GET "/alert/text" None with
  | Ok (`String text) -> Ok (`Assoc ["open",`Bool true;"text",`String text])
  | Error (Remote {code="no such alert";_}) -> Ok (`Assoc ["open",`Bool false])
  | Ok _ -> Error (Protocol "invalid dialog text response")
  | Error error -> Error error
let element_call perform_effect id suffix body =
  perform_effect `POST ("/element/" ^ Uri.pct_encode id ^ suffix) (Some body)
let interact t session ~perform_effect = function
  | Browser_lane.Action.Click selector ->
    let* id = element_id t session selector in element_call perform_effect id "/click" (`Assoc [])
  | Browser_lane.Action.Fill {selector;text} ->
    let* id = element_id t session selector in
    let* _ = element_call perform_effect id "/clear" (`Assoc []) in
    if text = "" then Ok `Null
    else element_call perform_effect id "/value" (`Assoc ["text",`String text])
  | Browser_lane.Action.Press {selector;key} ->
    let* id = element_id t session selector in
    element_call perform_effect id "/value" (`Assoc ["text",`String (Browser_lane.Action.webdriver_key key)])
  | Browser_lane.Action.Select {selector;value} ->
    let* id = element_id t session selector in
    (* Resolve the option under this exact select, then use a native click. *)
    let element = `Assoc ["element-6066-11e4-a52e-4f735466cecf",`String id] in
    let* option = script t session
      "const el=arguments[0]; if(el.localName!=='select') throw new Error('target is not a select'); const options=Array.from(el.options).filter(o=>o.value===arguments[1]); if(options.length!==1) throw new Error('option value must match exactly once'); return options[0];"
      [element;`String value] in
    let* id = string_field "element-6066-11e4-a52e-4f735466cecf" option in
    element_call perform_effect id "/click" (`Assoc [])
  | Browser_lane.Action.Scroll {x;y} ->
    perform_effect `POST "/execute/sync" (Some (`Assoc ["script", `String "window.scrollBy({left:arguments[0],top:arguments[1],behavior:'instant'}); return {x:window.scrollX,y:window.scrollY};"
      ; "args", `List [`Int x;`Int y]]))
  | Browser_lane.Action.Upload {selector;paths} ->
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
  | Browser_lane.Action.Open_tab url ->
    let* () = absolute_http_url url in
    let* session = session t in
    let* _ = match call t session `GET "/window" None with
      | Error (Remote {code="no such window";_}) ->
        let* handles = call t session `GET "/window/handles" None in
        (match handles with
         | `List (`String handle :: _) -> select t session handle
         | _ -> Error (Protocol "no surviving browser window; reopen the session"))
      | result -> result in
    let* created = perform_effect session `POST "/window/new" (Some (`Assoc ["type",`String "tab"])) in
    let* handle = string_field "handle" created in
    let id = tab_id t session handle in
    let navigate () =
      let* _ = select t session handle in
      let* _ = call t session `POST "/url" (Some (`Assoc ["url",`String url])) in
      page_summary t session in
    (match navigate () with
     | Ok summary -> Ok (`Assoc ["tabId",`Int id;"page",summary])
     | Error (Remote {code="unexpected alert open";_}) ->
       (* The tab was created, and its document is waiting on a user prompt.
          Retain the identity without claiming that navigation completed. *)
       Ok (`Assoc ["tabId",`Int id;"navigation",`String "blocked_by_dialog";"requested_url",`String url])
     | Error error -> Error (error_at_tab id error))
  | Browser_lane.Action.On_tab {tab_id=id;frame_path;interaction} ->
    let* session = session t in
    with_tab t session (Some id) (fun () ->
      let* () = enter_frames t session frame_path in
      let* result = interact t session ~perform_effect:(perform_effect session) interaction in
      match interaction with
      | Browser_lane.Action.Close_tab ->
        session.handles <- List.filter (fun (_,known) -> known <> id) session.handles;
        (match result with `List [] -> t.session <- None; release_resources session | _ -> ());
        Ok (`Assoc ["tabId",`Int id;"closed",`Bool true])
      | _ ->
        (* Do not issue another fallible browser request after an effect.
           The caller observes the resulting page with a separate read. *)
        Ok (`Assoc ["tabId",`Int id;"performed",`Bool true;"result",result]))
  in result, !phase
let execute_unlocked t = function
  | Browser_lane.Session_open { headless } ->
    (match t.session with
     | Some _ -> let* _ = session t in Ok (`Assoc ["opened", `Bool true; "reused", `Bool true])
     | None ->
       let args = if Option.value ~default:true headless then [`String "-headless"] else [] in
       let caps = `Assoc ["capabilities", `Assoc ["alwaysMatch", `Assoc
         ["browserName", `String "firefox";
          "webSocketUrl", `Bool true;
          "unhandledPromptBehavior", `String "ignore";
          "moz:firefoxOptions", `Assoc (("args", `List args) ::
            (Option.map (fun path -> "binary", `String path) t.binary |> Option.to_list))]]] in

       let* result = t.request ~method_:`POST ~path:"/session" ~body:(Some caps) in
       let* id = string_field "sessionId" result in
       let owned = { pointer_state = Released; id; handles = []; uploads = Browser_lane.Upload_lease.create_owner (); download_contexts = []; downloads = Error "BiDi setup incomplete; close this session before retrying" } in
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
         let* websocket_url = string_field "webSocketUrl" capabilities in
         let* downloads = Result.map_error (fun detail -> Protocol ("Firefox download setup failed: " ^ detail))
           (t.start_downloads ~session_id:id ~websocket_url) in
         owned.downloads <- Ok downloads;
         committed := true;
         Ok (`Assoc ["opened", `Bool true; "reused", `Bool false; "backend", `String "firefox-webdriver"])))
  | Browser_lane.Session_close ->
    let* () = close_unlocked t in Ok (`Assoc ["closed", `Bool true])
  | Browser_lane.Session_status ->
    (* Reports the backend's own record. No request is issued, so this answers
       whether or not a session exists, and cannot itself fail on a closed one.
       [downloads] is reported because a session can be open with BiDi setup
       incomplete, and every later download call refuses with that detail. *)
    (match t.session with
     | None -> Ok (`Assoc ["open", `Bool false])
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
  | Browser_lane.Page_elements {tab_id=target_tab_id} ->
    let* session = session t in
    with_tab t session target_tab_id (fun () ->
      let* handle = call t session `GET "/window" None in
      let* handle = match handle with `String value -> Ok value | _ -> Error (Protocol "invalid current window") in
      let* data = script t session Browser_page_script.elements [] in
      match data with
      | `Assoc fields -> Ok (`Assoc (("tabId",`Int (tab_id t session handle)) :: fields))
      | _ -> Error (Protocol "malformed elements observation"))
  | Browser_lane.Page_context {tab_id=id;frame_path;mode} ->
    let* session = session t in
    with_tab t session (Some id) (fun () ->
      let* () = enter_frames t session frame_path in
      let* data = match mode with
        | `Dialog -> dialog_text t session
        | `Elements -> script t session Browser_page_script.elements []
        | `Frames -> script t session Browser_page_script.frames []
        | `Text cap ->
          if cap < 1 || cap > 100_000 then Error (Protocol "maxChars must be between 1 and 100000")
          else script t session
            "const text=document.body?.innerText ?? ''; const chars=Array.from(text); return {url:location.href,title:document.title,text:chars.slice(0,arguments[0]).join(''),chars:chars.length,truncated:chars.length>arguments[0]};" [`Int cap] in
      match data with
      | `Assoc fields -> Ok (`Assoc (["tabId",`Int id;"framePath",`List (List.map (fun s -> `String s) frame_path)] @ fields))
      | _ -> Error (Protocol "invalid contextual observation"))
  | Browser_lane.Page_read { tab_id; max_chars } ->
    let* session = session t in
    with_tab t session tab_id (fun () ->
      let cap = Option.value ~default:50_000 max_chars in
      if cap < 1 || cap > 100_000 then Error (Protocol "maxChars must be between 1 and 100000")
      else script t session
        "const text=document.body?.innerText ?? ''; const chars=Array.from(text); return {url:location.href,title:document.title,text:chars.slice(0,arguments[0]).join(''),chars:chars.length,truncated:chars.length>arguments[0]};"
        [`Int cap])
  | Browser_lane.Page_interact { tab_id; expected_url; action } ->
    let* session = session t in
    with_tab t session (Some tab_id) (fun () ->
      let args = Browser_lane.interaction_args ~tab_id ~expected_url action in
      let* result = match action with
        | Browser_lane.Click_at {point;viewport}
        | Browser_lane.Scroll_at {point;viewport;_}
        | Browser_lane.Drag {from=point;viewport;_} ->
          let* before = script t session (Browser_scene_script.runtime ^ Browser_interaction.pointer_guard_script) [args] in
          let move (point : Browser_lane.Pointer.point) = `Assoc [
            "type",`String "pointerMove"; "duration",`Int 0; "origin",`String "viewport";
            "x",`Int (int_of_float (point.x *. viewport.width));
            "y",`Int (int_of_float (point.y *. viewport.height))] in
          let button kind = `Assoc ["type",`String kind; "button",`Int 0] in
          let moves = match action with
            | Browser_lane.Drag {to_;_} -> [move to_]
            | _ -> [] in
          let pointer_actions = `Assoc ["actions",`List [`Assoc [
            "type",`String "pointer"; "id",`String "masc-browser-pointer";
            "parameters",`Assoc ["pointerType",`String "mouse"];
            "actions",`List ([move point;button "pointerDown"] @ moves @ [button "pointerUp"])]]] in
          let actions = match action with
            | Browser_lane.Scroll_at {x;y;_} -> `Assoc ["actions",`List [`Assoc [
                "type",`String "wheel";"id",`String "masc-browser-wheel";
                "actions",`List [`Assoc ["type",`String "scroll";"duration",`Int 0;
                  "origin",`String "viewport";
                  "x",`Int (int_of_float (point.x *. viewport.width));
                  "y",`Int (int_of_float (point.y *. viewport.height));
                  "deltaX",`Int x;"deltaY",`Int y]]]]]
            | _ -> pointer_actions in
          (* Release even if transport cancellation interrupts a pressed gesture.
             The enclosing session lock remains held throughout cleanup. *)
          let applied, released = match action with
            | Browser_lane.Scroll_at _ ->
                (* Wheel actions do not press buttons. Session acquisition
                   already recovers any older pending pointer release. *)
                call t session `POST "/actions" (Some actions), Ok ()
            | _ ->
            let released = ref None in
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
          let* after = script t session "return {url:location.href,title:document.title,scrollX,scrollY};" [] in
          let* url_before = string_field "url" before in
          (match after with
           | `Assoc fields -> Ok (`Assoc (("urlBefore",`String url_before) ::
               ("action",`String (match action with Browser_lane.Click_at _ -> "click_at" | Browser_lane.Scroll_at _ -> "scroll_at" | _ -> "drag")) :: fields))
           | _ -> Error (Protocol "invalid pointer receipt"))
        | _ -> script t session (Browser_scene_script.runtime ^ Browser_interaction.script) [args]
      in
      match result with
      | `Assoc fields -> Ok (`Assoc (("tabId", `Int tab_id) :: fields))
      | _ -> Error (Protocol "invalid interaction response"))
  | Browser_lane.Page_capture { tab_id } ->
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
  | Browser_lane.Tabs_list ->
    let* session = session t in
    let* handles = call t session `GET "/window/handles" None in
    let* current = match call t session `GET "/window" None with
      | Error (Remote { code = "no such window"; _ }) -> Ok `Null
      | result -> result in
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
           | Error (Remote { code = "no such window"; _ }) -> Ok `Null
           | result -> result) in
      (match result, restored with
       | Error error, _ | _, Error error -> Error error
       | Ok tabs, Ok _ -> Ok tabs)
    | _ -> Error (Protocol "invalid WebDriver windows response")
let execute t verb =
  with_session_lock t (fun () ->
    match verb with
    | Browser_lane.Page_act action ->
      (match execute_action t action with
       | Ok data, _ -> Browser_lane.Answered (`Assoc ["ok", `Bool true; "data", data])
       | Error error, Not_started -> Browser_lane.Rejected_before_effect (error_message error)
       | Error error, Started -> Browser_lane.Refused (error_message error))
    | _ ->
      match execute_unlocked t verb with
      | Ok data -> Browser_lane.Answered (`Assoc ["ok", `Bool true; "data", data])
      | Error error -> Browser_lane.Refused (error_message error))
