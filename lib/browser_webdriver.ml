type error = Transport of string | Protocol of string | Remote of { code : string; message : string }
type request = method_:Masc_http_client.Pool.http_method -> path:string -> body:Yojson.Safe.t option -> (Yojson.Safe.t, error) result
type session = { id : string; mutable handles : (string * int) list; mutable next_tab : int }
type t = { request : request; mutex : Eio.Mutex.t; mutable session : session option }
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
let create ~request = { request; mutex = Eio.Mutex.create (); session = None }
let path session suffix = "/session/" ^ Uri.pct_encode session.id ^ suffix
let call t session method_ suffix body =
  let result = t.request ~method_ ~path:(path session suffix) ~body in
  (match result with
   | Error (Remote { code = "invalid session id"; _ }) -> t.session <- None
   | Ok _ | Error _ -> ());
  result
let close_unlocked t = match t.session with
  | None -> Ok ()
  | Some session ->
    let result = call t session `DELETE "" None in
    match result with
    | Ok _ | Error (Remote { code = "invalid session id"; _ }) -> t.session <- None; Ok ()
    | Error error -> Error error
let close t = Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> close_unlocked t)
let session t = match t.session with
  | Some session -> Ok session
  | None -> Error (Protocol "Firefox session is closed; open a browser session first")
let tab_id session handle = match List.assoc_opt handle session.handles with
  | Some id -> id
  | None ->
    let id = session.next_tab in
    session.next_tab <- id + 1;
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
       t.session <- Some { id; handles = []; next_tab = 1 };
       Ok (`Assoc ["opened", `Bool true; "reused", `Bool false; "backend", `String "firefox-webdriver"]))
  | Browser_lane.Session_close ->
    let* () = close_unlocked t in Ok (`Assoc ["closed", `Bool true])
  | Browser_lane.Page_goto { url } ->
    let uri = Uri.of_string url in
    (match Uri.scheme uri, Uri.host uri with
     | Some ("http" | "https"), Some host when host <> "" ->
       let* session = session t in
       let* _ = call t session `POST "/url" (Some (`Assoc ["url", `String url])) in
       page_summary t session
     | _ -> Error (Protocol "navigation requires an absolute HTTP(S) URL"))
  | Browser_lane.Page_read { tab_id; max_chars } ->
    let* session = session t in
    with_tab t session tab_id (fun () ->
      let cap = Option.value ~default:50_000 max_chars in
      if cap < 1 || cap > 100_000 then Error (Protocol "maxChars must be between 1 and 100000")
      else script t session
        "const text=document.body?.innerText ?? ''; const chars=Array.from(text); return {url:location.href,title:document.title,text:chars.slice(0,arguments[0]).join(''),chars:chars.length,truncated:chars.length>arguments[0]};"
        [`Int cap])
  | Browser_lane.Tabs_list ->
    let* session = session t in
    let* current = call t session `GET "/window" None in
    let* handles = call t session `GET "/window/handles" None in
    match current, handles with
    | `String original, `List handles ->
      let rec read acc = function
        | [] -> Ok (`List (List.rev acc))
        | `String handle :: rest ->
          let* _ = select t session handle in
          let* summary = page_summary t session in
          (match summary with
           | `Assoc fields ->
             let tab = `Assoc (("id", `Int (tab_id session handle)) ::
               ("active", `Bool (handle = original)) :: fields) in
             read (tab :: acc) rest
           | _ -> Error (Protocol "invalid page summary"))
        | _ -> Error (Protocol "invalid WebDriver window handle")
      in
      let result = read [] handles in
      let restored = select t session original in
      (match result, restored with
       | Error error, _ | _, Error error -> Error error
       | Ok tabs, Ok _ -> Ok tabs)
    | _ -> Error (Protocol "invalid WebDriver windows response")
let execute t verb =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    match execute_unlocked t verb with
    | Ok data -> Browser_lane.Answered (`Assoc ["ok", `Bool true; "data", data])
    | Error error -> Browser_lane.Refused (error_message error))
