type error = Transport of string | Protocol of string | Remote of { code : string; message : string }
type request = method_:Masc_http_client.Pool.http_method -> path:string -> body:Yojson.Safe.t option -> (Yojson.Safe.t, error) result
type session = { id : string; mutable handles : (string * int) list }
type t = { request : request; mutex : Eio.Mutex.t; mutable session : session option; mutable next_tab : int }
let ( let* ) = Result.bind
let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None
let string_field key json = match field key json with
  | Some (`String value) when value <> "" -> Ok value
  | _ -> Error (Protocol ("missing string field: " ^ key))
let error_message = function
  | Transport message | Protocol message -> message
  | Remote { code; message } -> code ^ ": " ^ message
let decode_response ~status body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error detail -> Error (Protocol detail)
  | json ->
    match field "value" json with
    | None -> Error (Protocol "WebDriver response has no value")
    | Some value when status >= 200 && status < 300 -> Ok value
    | Some value ->
      let* code = string_field "error" value in
      let* message = string_field "message" value in
      Error (Remote { code; message })
let create ~request = { request; mutex = Eio.Mutex.create (); session = None; next_tab = 1 }
let path session suffix = "/session/" ^ Uri.pct_encode session.id ^ suffix
let call t session method_ suffix body =
  let result = t.request ~method_ ~path:(path session suffix) ~body in
  (match result with
   | Error (Remote { code = "invalid session id"; _ }) -> t.session <- None
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
    | Ok _ | Error (Remote { code = "invalid session id"; _ }) -> t.session <- None; Ok ()
    | Error error -> Error error
let close ?request t = with_session_lock t (fun () -> close_unlocked ?request t)
let session t = match t.session with
  | Some session -> Ok session
  | None -> Error (Protocol "Firefox session is closed; open a browser session first")
let tab_id t session handle = match List.assoc_opt handle session.handles with
  | Some id -> id
  | None ->
    let id = t.next_tab in
    t.next_tab <- id + 1;
    session.handles <- (handle, id) :: session.handles;
    id
let select t session handle =
  call t session `POST "/window" (Some (`Assoc ["handle", `String handle]))
let with_tab t session tab_id f =
  match tab_id with
  | None -> f ()
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
    let* created = perform_effect session `POST "/window/new" (Some (`Assoc ["type",`String "tab"])) in
    let* handle = string_field "handle" created in
    let id = tab_id t session handle in
    let* _ = select t session handle in
    let* _ = call t session `POST "/url" (Some (`Assoc ["url",`String url])) in
    let* summary = page_summary t session in
    Ok (`Assoc ["tabId",`Int id;"page",summary])
  | Browser_lane.Action.On_tab {tab_id=id;interaction} ->
    let* session = session t in
    with_tab t session (Some id) (fun () ->
      let* result = interact t session ~perform_effect:(perform_effect session) interaction in
      match interaction with
      | Browser_lane.Action.Close_tab ->
        session.handles <- List.filter (fun (_,known) -> known <> id) session.handles;
        (match result with `List [] -> t.session <- None | _ -> ());
        Ok (`Assoc ["tabId",`Int id;"closed",`Bool true])
      | _ ->
        (* Do not issue another fallible browser request after an effect.
           The caller observes the resulting page with a separate read. *)
        Ok (`Assoc ["tabId",`Int id;"performed",`Bool true;"result",result]))
  in result, !phase
let execute_unlocked t = function
  | Browser_lane.Session_open { headless } ->
    (match t.session with
     | Some _ -> Ok (`Assoc ["opened", `Bool true; "reused", `Bool true])
     | None ->
       let args = if Option.value ~default:true headless then [`String "-headless"] else [] in
       let caps = `Assoc ["capabilities", `Assoc ["alwaysMatch", `Assoc
         ["browserName", `String "firefox";
          "moz:firefoxOptions", `Assoc ["args", `List args]]]] in
       let* result = t.request ~method_:`POST ~path:"/session" ~body:(Some caps) in
       let* id = string_field "sessionId" result in
       t.session <- Some { id; handles = [] };
       Ok (`Assoc ["opened", `Bool true; "reused", `Bool false; "backend", `String "firefox-webdriver"]))
  | Browser_lane.Session_close ->
    let* () = close_unlocked t in Ok (`Assoc ["closed", `Bool true])
  | Browser_lane.Page_goto { url; tab_id } ->
    let* () = absolute_http_url url in
    let* session = session t in
    with_tab t session tab_id (fun () ->
      let* _ = call t session `POST "/url" (Some (`Assoc ["url", `String url])) in
      page_summary t session)
  | Browser_lane.Page_act action -> fst (execute_action t action)
  | Browser_lane.Page_elements {tab_id=target_tab_id} ->
    let* session = session t in
    with_tab t session target_tab_id (fun () ->
      let* handle = call t session `GET "/window" None in
      let* handle = match handle with `String value -> Ok value | _ -> Error (Protocol "invalid current window") in
      let* data = script t session Browser_page_script.elements [] in
      match data with
      | `Assoc fields -> Ok (`Assoc (("tabId",`Int (tab_id t session handle)) :: fields))
      | _ -> Error (Protocol "malformed elements observation"))
  | Browser_lane.Page_read { tab_id; max_chars } ->
    let* session = session t in
    with_tab t session tab_id (fun () ->
      let cap = Option.value ~default:50_000 max_chars in
      if cap < 1 || cap > 100_000 then Error (Protocol "maxChars must be between 1 and 100000")
      else script t session
        "const text=document.body?.innerText ?? ''; const chars=Array.from(text); return {url:location.href,title:document.title,text:chars.slice(0,arguments[0]).join(''),chars:chars.length,truncated:chars.length>arguments[0]};"
        [`Int cap])
  | Browser_lane.Page_capture { tab_id } ->
    let* session = session t in
    with_tab t session (Some tab_id) (fun () ->
      let* before = page_summary t session in
      let* url = string_field "url" before in
      let* image = call t session `GET "/screenshot" None in
      let* after = page_summary t session in
      let* after_url = string_field "url" after in
      if not (String.equal url after_url) then Error (Protocol "tab navigated during capture")
      else match image, field "title" after with
      | `String data, Some (`String title) ->
        Ok (`Assoc ["tabId", `Int tab_id; "title", `String title; "url", `String url;
          "mimeType", `String "image/png"; "data", `String data])
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
          let* _ = select t session handle in
          let* summary = page_summary t session in
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
