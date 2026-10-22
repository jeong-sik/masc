let ( let* ) = Result.bind
let field name = function `Assoc xs -> List.assoc_opt name xs | _ -> None
let string name json = match field name json with
  | Some (`String s) when s <> "" -> Ok s | _ -> Error ("BiDi missing " ^ name)
let obj xs = `Assoc xs
let str s = `String s
let required name json = match field name json with Some v -> Ok v | None -> Error ("missing " ^ name)
type partial_failure = { tab_id : int; message : string; receipt : Yojson.Safe.t }
type failure = Before_effect of string | Partial_failure of partial_failure | Outcome_unknown of string
(* The error codes Firefox answers that this host acts on, read once where
   the answer arrives; any other code is kept as Firefox wrote it.
   "session not created": Firefox will not serve a [session.new]. It takes
   one session at a time, and 157.0.1 answers a second connection's request
   with this ("Maximum number of active sessions") for as long as the first
   is there, also after the socket that asked for it has closed.
   "invalid session id": a session command on a connection that has no
   session. Firefox 157.0.1 answers [session.end] with it before any
   [session.new], after a [session.new] it refused, and it closes the socket
   once it has ended one. *)
type error_code = Session_not_created | Invalid_session_id | No_such_alert | Unexpected_alert_open | Other_error of string
let error_code_of_wire = function
  | "session not created" -> Session_not_created
  | "invalid session id" -> Invalid_session_id
  | "no such alert" -> No_such_alert
  | "unexpected alert open" -> Unexpected_alert_open
  | code -> Other_error code
let error_code_to_wire = function
  | Session_not_created -> "session not created"
  | Invalid_session_id -> "invalid session id"
  | No_such_alert -> "no such alert"
  | Unexpected_alert_open -> "unexpected alert open"
  | Other_error code -> code
type refusal = Rejected of error_code | Unanswered of string | Unsent of string
let refusal_message = function
  | Rejected code -> "BiDi command rejected: " ^ error_code_to_wire code
  | Unanswered why | Unsent why -> why
type verb = Browser_info | Tabs_list | Page_read | Page_elements | Page_capture | Page_scene | Page_interact | Page_act
  | Page_goto
let verb_to_wire = function
  | Browser_info -> "browser.info" | Tabs_list -> "tabs.list" | Page_read -> "page.read"
  | Page_scene -> "page.scene" | Page_elements -> "page.elements" | Page_capture -> "page.capture"
  | Page_interact -> "page.interact" | Page_act -> "page.act" | Page_goto -> "page.goto"
let verb_of_wire = function
  | "browser.info" -> Some Browser_info | "tabs.list" -> Some Tabs_list | "page.read" -> Some Page_read
  | "page.scene" -> Some Page_scene | "page.elements" -> Some Page_elements
  | "page.capture" -> Some Page_capture | "page.interact" -> Some Page_interact | "page.act" -> Some Page_act
  | "page.goto" -> Some Page_goto
  | _ -> None
type session_end_failure = Connection_gone of string | Not_confirmed of string
let session_end_failure_message = function Connection_gone why | Not_confirmed why -> why
type session_failure = Session_refused of string | Session_failed of string
let session_failure_message = function Session_refused why | Session_failed why -> why
type t = { ask : string -> Yojson.Safe.t -> (Yojson.Safe.t,refusal) result;
  session_end : unit -> (unit,session_end_failure) result; mutable session_may_exist : bool;
  mutable contexts : (string * int) list; mutable next_tab : int;
  (* BiDi's window IDs, numbered in the order this connection first sees them, as tab IDs are. *)
  mutable windows : (string * int) list;
  (* The tab IDs this connection created. It closes these and no others. *)
  mutable opened : int list;
  (* The contexts this connection gave a viewport size. Firefox keeps that size after the session ends
     (probed 2026-10-22, Firefox 158), so ending the session gives each of them its own size back. *)
  mutable sized : string list; mutable version : string option;
  mutable profile : string option; mutable process_id : int option;
  (* The dialog each context is blocked on, from the browser's own events. The session keeps prompts open
     (unhandledPromptBehavior ignore), so a person or this host answers them. *)
  prompts : (string, Browser_surface.dialog) Hashtbl.t }
let create ~session_end ~command =
  {ask=command;session_end;session_may_exist=false;contexts=[];next_tab=0;windows=[];opened=[];sized=[];version=None;profile=None;process_id=None;
   prompts=Hashtbl.create 4}
(* A malformed prompt event cannot be tracked and is not counted: the tab row then shows no dialog, and an
   answer to it gets the browser's own refusal. *)
let note_event t json =
  match field "method" json, field "params" json with
  | Some (`String "browsingContext.userPromptOpened"), Some params ->
    (match field "context" params, field "type" params, field "message" params with
     | Some (`String context), Some (`String kind), Some (`String message) when context <> "" ->
       (match Browser_surface.dialog_kind_of_wire kind with
        | None -> ()
        | Some kind ->
          let default_value = match field "defaultValue" params with Some (`String value) -> Some value | _ -> None in
          Hashtbl.replace t.prompts context {Browser_surface.kind;message;default_value})
     | _ -> ())
  | Some (`String "browsingContext.userPromptClosed"), Some params ->
    (match field "context" params with Some (`String context) -> Hashtbl.remove t.prompts context | _ -> ())
  | _ -> ()
let command t method_ params = Result.map_error (fun refusal -> method_ ^ ": " ^ refusal_message refusal) (t.ask method_ params)
(* Firefox keeps a session whose socket closed and takes one session at a
   time, so one left behind refuses every later connection until that Firefox
   is restarted. Ending it closes no tab and leaves the browser running. *)
let end_session t =
  if not t.session_may_exist then Ok ()
  else begin
    (* Best effort: a tab that is gone, or a command that gets no answer, must not keep the session open. *)
    List.iter (fun context ->
      ignore (t.ask "browsingContext.setViewport" (obj ["context",str context;"viewport",`Null]))) t.sized;
    t.sized <- [];
    let* () = t.session_end () in t.session_may_exist <- false; Ok ()
  end
let metadata t =
  (* Firefox may hold a session from the moment it is asked for one, whether
     or not its answer arrives. There is none when it refused, and none when
     the request was never written. *)
  t.version <- None;t.profile <- None;t.process_id <- None;
  t.session_may_exist <- true;
  (* The browser answers a page's alert, confirm and prompt by itself unless the session says to leave them
     open (probed 2026-10-22, Firefox 158: confirm() returned false at once for a session made with empty
     capabilities). A person using this browser must still get the dialog. *)
  let capabilities = obj ["alwaysMatch",obj ["unhandledPromptBehavior",obj ["default",str "ignore"]]] in
  match t.ask "session.new" (obj ["capabilities",capabilities]) with
  | Error (Rejected Session_not_created as refused) ->
    t.session_may_exist <- false; Error (Session_refused (refusal_message refused))
  | Error (Rejected (Invalid_session_id | No_such_alert | Unexpected_alert_open | Other_error _) | Unsent _ as refused) ->
    t.session_may_exist <- false; Error (Session_failed (refusal_message refused))
  | Error (Unanswered _ as unanswered) -> Error (Session_failed (refusal_message unanswered))
  | Ok result ->
    Result.map_error (fun detail -> Session_failed detail)
      (let* caps = required "capabilities" result in
       let* name = string "browserName" caps in
       if name <> "firefox" then Error "BiDi peer must be Firefox"
       else let* version=string "browserVersion" caps in t.version<-Some version;
         t.profile <- Result.to_option (string "moz:profile" caps);
         t.process_id <- (match field "moz:processID" caps with
           | Some (`Int pid) when pid>1 -> Some pid
           | None | Some _ -> None);
         let* _ = Result.map_error (fun refusal -> "session.subscribe: " ^ refusal_message refusal)
           (t.ask "session.subscribe" (obj ["events",`List [str "browsingContext.userPromptOpened";
             str "browsingContext.userPromptClosed"]])) in
         Ok version)
let profile t = t.profile
let process_id t = t.process_id
let close_browser t = Result.map (fun _ -> ()) (t.ask "browser.close" (obj []))
(* Firefox 157.0.1 reports the profile path as it was given, a link left as
   a link (2026-10-09), so both paths are resolved before they are compared.
   A path that cannot be resolved is compared as written. *)
let resolved path = match Unix.realpath path with resolved -> resolved | exception Unix.Unix_error _ -> path
type profile_refusal = Profile_unsaid | Runs_profile of string

let runs_profile t ~expected =
  match t.profile with
  | None -> Error Profile_unsaid
  | Some actual when String.equal (resolved actual) (resolved expected) -> Ok ()
  | Some actual -> Error (Runs_profile actual)

let profile_refusal_message ~expected = function
  | Profile_unsaid ->
    Printf.sprintf "Firefox did not say which profile it runs (moz:profile), so it cannot be told to run %s"
      expected
  | Runs_profile actual -> Printf.sprintf "this Firefox runs the profile %s, not %s" actual expected
(* The socket takes one message of at most this many bytes; a larger one ends
   the connection, and with it this client. *)
let reply_limit_bytes = 8 * 1024 * 1024
(* A page script's answer crosses the socket as a JSON string inside the BiDi
   envelope, where one UTF-16 unit of the answer is at most three bytes: an
   escaped quote or backslash is two, a BMP character three, and
   JSON.stringify has already spelled control characters and lone surrogates
   in ASCII. An answer of at most a quarter of the limit in units therefore
   fits with room left for the envelope. A longer one is refused in the page,
   which answers with its length as a number instead of the string. *)
let script_answer_limit_units = reply_limit_bytes / 4
let answer_too_large units =
  Printf.sprintf "page_answer_exceeds_bidi_reply_limit: %d UTF-16 units, at most %d cross this connection"
    units script_answer_limit_units
type evaluation_failure = Rpc_failed of refusal | Page_failed of string
let evaluate_typed t context body args =
  let declaration = "function(args) { " ^ Browser_scene_script.runtime
    ^ "\nconst answer = JSON.stringify((function(){" ^ body ^ "}).call(null,args));"
    ^ Printf.sprintf "\nreturn typeof answer === 'string' && answer.length > %d ? answer.length : answer; }"
        script_answer_limit_units in
  let* result = Result.map_error (fun reason -> Rpc_failed reason) (t.ask "script.callFunction" (obj [
    "functionDeclaration",str declaration;"target",obj ["context",str context];
    "awaitPromise",`Bool false;"arguments",`List [obj ["type",str "string";"value",str (Yojson.Safe.to_string args)]]])) in
  (* Arguments cross the protocol as a JSON string, decoded by the fixed body. *)
  Result.map_error (fun message -> Page_failed message) (match field "type" result with
  | Some (`String "success") ->
    let* value = required "result" result in
    (match field "type" value, field "value" value with
     | Some (`String "string"), Some (`String encoded) ->
       (try Ok (Yojson.Safe.from_string encoded) with Yojson.Json_error _ -> Error "invalid BiDi script JSON")
     | Some (`String "number"), Some (`Int units) -> Error (answer_too_large units)
     | _ -> Error "invalid BiDi script result")
  | Some (`String "exception") ->
    let detail = match field "exceptionDetails" result with
      | Some details -> (match field "text" details with Some (`String text) -> Some text | _ -> None)
      | None -> None in
    Error ("Firefox rejected the fixed page script" ^ (match detail with Some text -> ": " ^ text | None -> ""))
  | _ -> Error "invalid BiDi script result")
let evaluation_failure_message = function
  | Rpc_failed refusal -> "script.callFunction: " ^ refusal_message refusal
  | Page_failed message -> message
let evaluate t context body args =
  Result.map_error evaluation_failure_message (evaluate_typed t context body args)
let script t context body args = evaluate t context ("arguments[0]=JSON.parse(arguments[0]);\n" ^ body) args
let scene t context args = script t context "return browserScene(arguments[0]);" args
let tab_metadata t context = script t context
  "return {url:location.href,title:document.title,active:document.visibilityState==='visible'};" (obj [])
(* Capture guards need document identity and geometry, never page text. Read
   the URL and viewport in the same script on each side of the screenshot. *)
let capture_state t context = script t context
  "return {url:location.href,title:document.title,viewport:browserScene({mode:'viewport'})};" (obj [])
(* A read that answers for the whole document. The extension runs its reads
   once the parser is done; nothing waits for the parser here, so a document
   still being parsed is refused instead of answered with the part that
   exists so far. *)
let parsed_document t context body args =
  let* answer = script t context
    ("if (document.readyState === 'loading') return {documentLoading:true};\n" ^ body) args in
  if Option.is_some (field "documentLoading" answer)
  then Error "the document is still loading; read it again"
  else Ok answer
let remember_context t context =
  match List.assoc_opt context t.contexts with
  | Some id -> id
  | None -> t.next_tab <- t.next_tab + 1;
    t.contexts <- (context,t.next_tab)::t.contexts; t.next_tab

let remember_window t window =
  match List.assoc_opt window t.windows with
  | Some id -> id
  | None -> let id = List.length t.windows in t.windows <- t.windows @ [window, id]; id

let open_tab t url =
  let invalid () = Error (Before_effect "open_tab requires an absolute HTTP(S) URL") in
  let* () = match Uri.of_string url with
    | uri -> (match Uri.scheme uri,Uri.host uri with
        | Some ("http"|"https"),Some host when host <> "" -> Ok ()
        | _ -> invalid ())
    | exception Failure _ -> invalid () in
  (* Only a fresh context is navigated. A protected existing start page does
     not need a script realm and is never replaced to make this work. *)
  let* created = match t.ask "browsingContext.create" (obj ["type",str "tab";"background",`Bool true]) with
    | Ok created -> Ok created
    | Error (Rejected _ | Unsent _ as refusal) ->
      Error (Before_effect ("browsingContext.create: " ^ refusal_message refusal))
    | Error (Unanswered _ as refusal) ->
      Error (Outcome_unknown ("browsingContext.create: " ^ refusal_message refusal ^ "; inspect this connection before opening another tab")) in
  let* context = string "context" created |> Result.map_error (fun reason ->
    Outcome_unknown (reason ^ "; tab creation was dispatched; inspect the connection before opening another tab")) in
  let id = remember_context t context in
  t.opened <- id :: t.opened;
  let message reason =
    Printf.sprintf "New tab was created as tabId %d on this connection. %s. Do not open another tab to retry." id reason in
  let partial reason = Partial_failure {tab_id=id;message=message reason ^
    " Inspect it using this same clientId and tabId.";
    receipt=obj ["action",str "open_tab";"created",`Bool true;"tabId",`Int id]} in
  let rpc_failure = function
    | Rejected (Other_error _ | No_such_alert | Unexpected_alert_open) as refusal -> partial (refusal_message refusal)
    | Rejected (Session_not_created | Invalid_session_id) | Unanswered _ | Unsent _ as refusal ->
      Outcome_unknown (message (refusal_message refusal) ^
        " This connection cannot be reused. Re-list connections and tabs, then use newly observed IDs to inspect it; the old tabId does not identify a tab on a replacement connection.") in
  let* _ = Result.map_error rpc_failure (t.ask "browsingContext.navigate"
    (obj ["context",str context;"url",str url;"wait",str "complete"])) in
  let* summary = Result.map_error (function
    | Rpc_failed refusal -> rpc_failure refusal
    | Page_failed reason -> partial reason)
    (evaluate_typed t context
      "arguments[0]=JSON.parse(arguments[0]);\nreturn {url:location.href,title:document.title,active:document.visibilityState==='visible'};" (obj [])) in
  match summary with
  | `Assoc fields -> Ok (obj (("tabId",`Int id)::("action",str "open_tab")::("created",`Bool true)::fields))
  | _ -> Error (partial "invalid new-tab summary")

type tab_context = { context : string; id : int; url : string option; window : int option }

let tree t =
  let* result = command t "browsingContext.getTree" (obj []) in
  match field "contexts" result with
  | Some (`List rows) ->
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | row::rest -> let* context = string "context" row in
        let id = remember_context t context in
        let* url = match field "url" row with
          | None -> Ok None
          | Some (`String url) -> Ok (Some url)
          | Some _ -> Error "invalid BiDi context URL" in
        let window = match field "clientWindow" row with
          | Some (`String window) -> Some (remember_window t window)
          | None | Some _ -> None in
        collect ({context;id;url;window}::acc) rest in
    collect [] rows
  | _ -> Error "invalid BiDi context tree"
let resolve t args =
  let* current = tree t in
  match field "tabId" args with
  | Some (`Int id) -> (match List.find_opt (fun tab -> tab.id=id) current with
      | Some {context;_} -> Ok (context,id) | None -> Error "browser tab is no longer present")
  | None ->
    let rec active unavailable = function
      | [] -> Error (String.concat "; " ("no active browser context" :: List.rev unavailable))
      | {context;id;url=_;window=_}::rest ->
        (match tab_metadata t context with
         | Error detail -> active (Printf.sprintf "tab %d: %s" id detail :: unavailable) rest
         | Ok p -> match field "active" p with
           | Some (`Bool true) -> Ok (context,id)
           | _ -> active unavailable rest) in
    active [] current
  | _ -> Error "invalid tabId"
let with_tab id = function `Assoc fields -> Ok (obj (("tabId",`Int id)::fields)) | _ -> Error "invalid page object"
let read t context args =
  let* cap = match field "maxChars" args with None -> Ok 50000
    | Some (`Int n) when n > 0 && n <= 100000 -> Ok n | _ -> Error "invalid maxChars" in
  match field "includeHtml" args with
  (* The automation lane's document helper: it drops HTML over 1 MiB and says
     so, instead of returning a cut document. *)
  | Some (`Bool true) ->
    parsed_document t context (Browser_lane.Document.runtime ^ "\nreturn browserDocument();") (obj [])
  | None | Some (`Bool false) -> script t context
      "const chars=Array.from(document.body?.innerText??''); const cap=arguments[0].cap; return {url:location.href,title:document.title,text:chars.slice(0,cap).join(''),chars:chars.length,truncated:chars.length>cap};" (obj ["cap",`Int cap])
  | _ -> Error "invalid includeHtml"
type pointer_motion = Hover_pointer | Click_pointer of Browser_lane.Pointer.button | Double_click_pointer | Drag_pointer of { destination : Browser_lane.Pointer.point; via : Browser_lane.Pointer.point list; duration_ms : int }
  | Wheel_pointer of { x : int; y : int }
  | Tap_pointer
  | Swipe_pointer of { destination : Browser_lane.Pointer.point; via : Browser_lane.Pointer.point list; duration_ms : int }
let pointer t context args ~(viewport : Browser_lane.Pointer.viewport) ~start motion =
  let before result = Result.map_error (fun e -> Before_effect e) result in
  let unknown result = Result.map_error (fun e -> Outcome_unknown e) result in
  let* observed = before (script t context Browser_interaction.pointer_guard_script args) in
  let gesture = match motion with
    | Hover_pointer -> Browser_lane.Pointer.Hover
    | Click_pointer button -> Browser_lane.Pointer.Click button
    | Double_click_pointer -> Browser_lane.Pointer.Double_click
    | Drag_pointer {destination;via;duration_ms} -> Browser_lane.Pointer.Drag {via;destination;duration_ms}
    | Wheel_pointer {x;y} -> Browser_lane.Pointer.Wheel {x;y}
    | Tap_pointer -> Browser_lane.Pointer.Tap
    | Swipe_pointer {destination;via;duration_ms} -> Browser_lane.Pointer.Swipe {via;destination;duration_ms} in
  let sources = Browser_lane.Pointer.input_sources ~pointer_id:"masc-pointer"
    ~wheel_id:"masc-wheel" ~viewport ~start gesture in
  (* No replay after dispatch. Release is itself a protocol action and remains
     bounded by the transport deadline. Protected release cleanup may outlast
     the host command deadline by that bound; failure ends the client. *)
  let released=ref (Ok ()) in
  let applied=Eio.Switch.run (fun sw ->
    (match motion with
    | Hover_pointer | Wheel_pointer _ -> ()
    | Click_pointer _ | Double_click_pointer | Drag_pointer _ | Tap_pointer | Swipe_pointer _ -> Eio.Switch.on_release sw (fun ()->
      released:=Result.map (fun _->()) (command t "input.releaseActions" (obj ["context",str context]))));
    command t "input.performActions" (obj ["context",str context;"actions",sources])) in
  let* _=unknown applied in
  let* ()=unknown !released in
  let* after = unknown (script t context Browser_interaction.pointer_receipt_script (obj [])) in
  let* old_url = unknown (string "url" observed) in
  let action=match motion with Hover_pointer->"hover_at"|Click_pointer _->"click_at"|Double_click_pointer->"double_click_at"|Drag_pointer _->"drag"|Wheel_pointer _->"scroll_at"|Tap_pointer->"tap_at"|Swipe_pointer _->"swipe" in
  match after with `Assoc fields -> Ok (obj (("action",str action)::("urlBefore",str old_url)::fields))
  | _ -> Error (Outcome_unknown "invalid post-input observation")
let keyboard t context args ~sources ~name =
  let pre result = Result.map_error (fun detail -> Before_effect detail) result in
  let unknown result = Result.map_error (fun detail -> Outcome_unknown detail) result in
  let* observed = pre (script t context Browser_interaction.keyboard_guard_script args) in
  let released = ref (Ok ()) in
  let applied = Eio.Switch.run (fun sw ->
    Eio.Switch.on_release sw (fun () -> released := Result.map (fun _ -> ())
      (command t "input.releaseActions" (obj ["context",str context])));
    command t "input.performActions" (obj ["context",str context;"actions",sources])) in
  let* _ = unknown applied in
  let* () = unknown !released in
  let* after = unknown (script t context Browser_interaction.pointer_receipt_script (obj [])) in
  let* old_url = unknown (string "url" observed) in
  match after with
  | `Assoc fields -> Ok (obj (("action",str name)::("urlBefore",str old_url)::fields))
  | _ -> Error (Outcome_unknown "invalid post-keyboard observation")
(* All four act only on tabs this connection opened: a tab the operator opened holds pages and unsaved state
   this host never saw, and these actions carry no expectedUrl to say which page the caller observed. Of
   Firefox's refusals, only [codes_before_acting] mean nothing happened. A reload or a history step waits for
   the document, and one that lands on an error page is answered with an error after the tab moved, so any
   other error, like a command that got no answer, may have had an effect: a navigation step reads the tab
   again ([settle_navigation]) and a close stays [Outcome_unknown]. *)
let codes_before_acting = ["no such history entry"; "invalid argument"; "no such frame"]
let ask_on_tab ?(before=codes_before_acting) t method_ params = match t.ask method_ params with
  | Ok result -> Ok result
  | Error (Unsent _ as refusal) -> Error (Before_effect (method_ ^ ": " ^ refusal_message refusal))
  | Error (Rejected (Other_error code) as refusal) when List.mem code before ->
    Error (Before_effect (method_ ^ ": " ^ refusal_message refusal))
  | Error (Rejected No_such_alert) -> Error (Before_effect "no dialog is open in this tab")
  | Error (Rejected (Other_error _ | Session_not_created | Invalid_session_id | Unexpected_alert_open) | Unanswered _ as refusal) ->
    Error (Outcome_unknown (method_ ^ ": " ^ refusal_message refusal ^ "; inspect the tab before repeating"))
let tab_receipt t context id name =
  let* summary = Result.map_error (fun e -> Outcome_unknown e)
    (script t context "return {url:location.href,title:document.title};" (obj [])) in
  match summary with
  | `Assoc fields -> Ok (obj (("tabId",`Int id)::("action",str name)::fields))
  | _ -> Error (Outcome_unknown ("invalid post-" ^ name ^ " observation"))
(* A navigation step Firefox answered with an error may have moved the tab
   already, onto an error page or part way. Reading the tab again settles
   where it is, so the step is a known partial effect and the connection
   stays; only a tab that cannot be read leaves the outcome unknown. *)
let settle_navigation t context id name = function
  | Ok _ -> tab_receipt t context id name
  | Error (Outcome_unknown message) ->
    (match tab_receipt t context id name with
     | Ok receipt -> Error (Partial_failure {tab_id=id;message;receipt})
     | Error _ -> Error (Outcome_unknown message))
  | Error (Before_effect _ | Partial_failure _ as failure) -> Error failure
let tab_action t ~tab_id interaction =
  let ask = ask_on_tab t in
  let* () = match interaction with
    | (Browser_lane.Action.Close_tab | Browser_lane.Action.Back | Browser_lane.Action.Forward
      | Browser_lane.Action.Reload) when not (List.mem tab_id t.opened) ->
      Error (Before_effect "a connected browser's back, forward, reload and close_tab act only on tabs this connection opened")
    | (Browser_lane.Action.Accept_dialog _ | Browser_lane.Action.Dismiss_dialog) when not (List.mem tab_id t.opened) ->
      Error (Before_effect "a connected browser's dialogs are answered only on tabs this connection opened; the person using the browser answers a dialog on their own tab")
    | Browser_lane.Action.Close_tab | Browser_lane.Action.Back | Browser_lane.Action.Forward
    | Browser_lane.Action.Reload
    | Browser_lane.Action.Upload _ | Browser_lane.Action.Accept_dialog _ | Browser_lane.Action.Dismiss_dialog -> Ok () in
  let* context,id = Result.map_error (fun e -> Before_effect e) (resolve t (obj ["tabId",`Int tab_id])) in
  (* The dialog is read before it is answered: the answer closes it, and the receipt says which one was
     answered. *)
  let answer_dialog ~accept text =
    let known = Hashtbl.find_opt t.prompts context in
    let* _ = ask "browsingContext.handleUserPrompt"
      (obj (["context",str context;"accept",`Bool accept]
        @ match text with Some text -> ["userText",str text] | None -> [])) in
    Hashtbl.remove t.prompts context;
    Ok (obj (["tabId",`Int id;"action",str (if accept then "accept_dialog" else "dismiss_dialog")]
      @ match known with Some dialog -> ["dialog",Browser_surface.dialog_json dialog] | None -> [])) in
  match interaction with
  | Browser_lane.Action.Back ->
    settle_navigation t context id "back"
      (ask "browsingContext.traverseHistory" (obj ["context",str context;"delta",`Int (-1)]))
  | Browser_lane.Action.Forward ->
    settle_navigation t context id "forward"
      (ask "browsingContext.traverseHistory" (obj ["context",str context;"delta",`Int 1]))
  | Browser_lane.Action.Reload ->
    settle_navigation t context id "reload"
      (ask "browsingContext.reload" (obj ["context",str context;"wait",str "complete"]))
  | Browser_lane.Action.Close_tab ->
    let* _ = ask "browsingContext.close" (obj ["context",str context;"promptUnload",`Bool false]) in
    t.opened <- List.filter (fun opened -> opened <> id) t.opened;
    Ok (obj ["tabId",`Int id;"action",str "close_tab";"closed",`Bool true])
  | Browser_lane.Action.Accept_dialog text -> answer_dialog ~accept:true text
  | Browser_lane.Action.Dismiss_dialog -> answer_dialog ~accept:false None
  | Browser_lane.Action.Upload _ ->
    Error (Before_effect "live BiDi page.act supports open_tab, back, forward, reload, close_tab, accept_dialog and dismiss_dialog only")

(* A URL navigation follows the rule of the history steps above: only a tab
   this connection opened, so a tab the operator opened is refused before any
   effect. The URL comes from the caller, so only an absolute HTTP(S) URL is
   sent to Firefox. *)
let goto t args =
  let refuse reason = Error (Before_effect reason) in
  let* url = match field "url" args with
    | Some (`String url) ->
      let uri = Uri.of_string url in
      (match Uri.scheme uri, Uri.host uri with
       | Some ("http" | "https"), Some host when host <> "" -> Ok url
       | (None | Some _), (None | Some _) -> refuse "page.goto requires an absolute HTTP(S) URL")
    | Some _ | None -> refuse "page.goto requires an absolute HTTP(S) URL" in
  let* tab_id = match field "tabId" args with
    | Some (`Int id) when List.mem id t.opened -> Ok id
    | Some _ | None ->
      refuse "a connected browser navigates only a tab this connection opened with open_tab; pass that tabId" in
  let* context,id = Result.map_error (fun e -> Before_effect e) (resolve t (obj ["tabId",`Int tab_id])) in
  settle_navigation t context id "goto"
    (ask_on_tab t "browsingContext.navigate" (obj ["context",str context;"url",str url;"wait",str "complete"]))

(* Firefox brings the tab to the front and gives it focus; the W3C
   specification extends that to the system focus of its window, which the
   extension's activation does not take. The observed URL is checked first, so
   a tab that moved on is refused before any effect. Each error Firefox
   documents for this command is one it answers before acting. *)
let activation_refusals = ["invalid argument"; "no such frame"; "unsupported operation"]
let activate t context id args =
  let* observed = Result.map_error (fun e -> Before_effect e)
    (script t context Browser_interaction.url_guard_script args) in
  let* old_url = Result.map_error (fun e -> Before_effect e) (string "url" observed) in
  let receipt after = obj (["tabId",`Int id;"action",str "activate_tab";"urlBefore",str old_url]
    @ List.filter_map (fun key -> Option.map (fun value -> key,value) (field key after)) ["url";"active";"title"]) in
  (* Whatever Firefox answered, the tab is read again: once it is read, what is
     in front is known and the connection stays. *)
  let settle message = match tab_metadata t context with
    | Ok after -> Error (Partial_failure {tab_id=id;message;receipt=receipt after})
    | Error _ -> Error (Outcome_unknown message) in
  match ask_on_tab ~before:activation_refusals t "browsingContext.activate" (obj ["context",str context]) with
  | Error (Before_effect _ | Partial_failure _ as failure) -> Error failure
  | Error (Outcome_unknown message) -> settle message
  | Ok _ ->
    match tab_metadata t context with
    | Error message -> Error (Outcome_unknown message)
    | Ok after -> match field "url" after, field "active" after with
      | Some (`String url), Some (`Bool true) when String.equal url old_url ->
        Ok (obj ["urlBefore",str old_url;"url",str url;"active",`Bool true;
          "title",Option.value (field "title" after) ~default:`Null])
      | (Some _ | None), (Some _ | None) ->
        Error (Partial_failure {tab_id=id;receipt=receipt after;
          message="Firefox activated the tab, but the observed page is not in the foreground; inspect it before repeating"})

(* The override stays on the tab until a later [Browser_default] clears it, so a refusal before the
   command leaves the viewport as it was. *)
let set_viewport t context args size =
  let before result = Result.map_error (fun e -> Before_effect e) result in
  let unknown result = Result.map_error (fun e -> Outcome_unknown e) result in
  let* observed = before (script t context Browser_interaction.url_guard_script args) in
  let viewport = match size with
    | Browser_lane.Fit {width;height} -> obj ["width",`Int width;"height",`Int height]
    | Browser_lane.Browser_default -> `Null in
  let* _ = unknown (command t "browsingContext.setViewport" (obj ["context",str context;"viewport",viewport])) in
  t.sized <- (match size with
    | Browser_lane.Fit _ -> if List.mem context t.sized then t.sized else context :: t.sized
    | Browser_lane.Browser_default -> List.filter (fun sized -> not (String.equal sized context)) t.sized);
  let* after = unknown (script t context Browser_interaction.viewport_receipt_script (obj [])) in
  let* old_url = unknown (string "url" observed) in
  match after with
  | `Assoc fields -> Ok (obj (("action",str "set_viewport")::("urlBefore",str old_url)::fields))
  | _ -> Error (Outcome_unknown "invalid post-resize observation")
let dispatch ?actor ?request_id t ~verb args =
  let pre r = Result.map_error (fun e -> Before_effect e) r in
  let on_tab use =
    let* context,id=pre (resolve t args) in
    match verb,request_id with
    | Page_interact,Some request_id ->
      let action = match field "action" args with Some (`String name) -> name | _ -> "interaction" in
      let metadata = ["requestId",str request_id;"actor",(match actor with Some name->str name|None->`Null);"action",str action] in
      (* Feedback is observational. A page refusing its overlay must not replay
         or prevent the authoritative interaction. Cleanup cannot mask input. *)
      let _ = script t context Browser_pointer_feedback.begin_script (obj metadata) in
      Eio.Switch.run (fun sw ->
        let phase = ref Browser_pointer_feedback.Unknown in
        Eio.Switch.on_release sw (fun () ->
          let _ = script t context Browser_pointer_feedback.finish_script
            (obj (("phase",Browser_pointer_feedback.outcome_to_json !phase)::metadata)) in ());
        let result = use context id in
        phase := (match result with Ok _ -> Browser_pointer_feedback.Finished | Error (Before_effect _) -> Browser_pointer_feedback.Refused | Error (Partial_failure _ | Outcome_unknown _) -> Browser_pointer_feedback.Unknown);
        result)
    | (Browser_info|Tabs_list|Page_read|Page_elements|Page_capture|Page_scene|Page_act|Page_goto), (None|Some _)
    | Page_interact,None -> use context id in
  match verb with
  | Page_goto -> goto t args
  | Page_act ->
    let* action = pre (Browser_lane.Action.parse args) in
    (match action with
     | Browser_lane.Action.Open_tab url -> open_tab t url
     | Browser_lane.Action.On_tab {tab_id; interaction; _} -> tab_action t ~tab_id interaction)
  | Browser_info ->
    (match t.version with Some version->Ok (obj ["name",str "Firefox";"version",str version])
     | None->Error (Before_effect "BiDi session metadata is unavailable"))
  | Tabs_list ->
    let* current = pre (tree t) in
    let rec rows index acc unavailable = function
      | [] ->
        let tabs = `List (List.rev acc) in
        Ok (match unavailable with
          | [] -> tabs
          | _ :: _ -> obj ["tabs",tabs;"complete",`Bool false;
              "unavailableTabs",`List (List.rev unavailable)])
      | {context;id;url;window}::rest ->
        let window_field = (match window with Some window -> ["windowId",`Int window] | None -> [])
          @ (match Hashtbl.find_opt t.prompts context with
             | Some dialog -> ["dialog",Browser_surface.dialog_json dialog] | None -> []) in
        (match tab_metadata t context with
         | Error detail ->
           rows (index+1) acc
             (obj (["id",`Int id;"index",`Int index;"error",str detail]
               @ window_field
               @ match url with Some url -> ["url",str url] | None -> [])::unavailable) rest
         | Ok p ->
           let* url=pre (string "url" p) in
           let* title=pre (required "title" p) in
           let* active=pre (required "active" p) in
           rows (index+1)
             (obj (["id",`Int id;"index",`Int index;"url",str url;"title",title;"active",active]
               @ window_field)::acc)
             unavailable rest)
    in
    rows 0 [] [] current
  | Page_elements -> on_tab (fun context id -> pre (
        (* The inventory the automation lane reads, so its selectors mean the
           same thing to the DOM interactions below. *)
        let* within=Browser_page_script.within_of_json (field "within" args) in
        let* p=parsed_document t context Browser_page_script.elements
            (Browser_page_script.elements_args within) in with_tab id p))
  | Page_read -> on_tab (fun context id -> pre (let* p=read t context args in with_tab id p))
  | Page_scene -> on_tab (fun context id -> pre (let* fields=match args with `Assoc xs->Ok xs|_->Error "invalid scene arguments" in
        let* p=scene t context (obj (("mode",str "read")::fields)) in with_tab id p))
  | Page_capture -> on_tab (fun context id -> pre (
        let* p=capture_state t context in let* viewport=required "viewport" p in
        let* png=command t "browsingContext.captureScreenshot" (obj ["context",str context]) in
        let* after=capture_state t context in let* after_viewport=required "viewport" after in
        let* url=string "url" p in let* after_url=string "url" after in
        if url<>after_url || viewport<>after_viewport then Error "viewport_changed_during_capture" else
        let* title=required "title" after in let* data=string "data" png in
        Ok (obj ["tabId",`Int id;"url",str url;"title",title;"mimeType",str "image/png";"data",str data;"viewport",viewport])))
  | Page_interact -> on_tab (fun context id ->
      let* fields=pre (match args with `Assoc xs->Ok xs|_->Error "invalid interaction") in
      let* request=pre (Browser_interaction.parse (obj (("lane",str Browser_lane.Lane_name.(to_wire Live))::fields))) in
      let* expected_url,action = match request.action with
        | Browser_lane.Double_click _ | Browser_lane.Hover _ | Browser_lane.Drag_to _ | Browser_lane.Click _ | Browser_lane.Click_node _ ->
          let* resolved = pre (script t context Browser_interaction.pointer_target_script args) in
          let* action = pre (Browser_interaction.resolve_pointer_action request.action resolved) in
          let* url = pre (string "url" resolved) in
          Ok (Some url,action)
        | Browser_lane.Set_zoom _ | Browser_lane.Set_viewport _ | Browser_lane.Double_click_at _ | Browser_lane.Type_text _ | Browser_lane.Press_key _
        | Browser_lane.Activate_tab | Browser_lane.Fill _ | Browser_lane.Select_option _
        | Browser_lane.Scroll _ | Browser_lane.Hover_at _ | Browser_lane.Click_at _
        | Browser_lane.Tap_at _ | Browser_lane.Swipe _
        | Browser_lane.Scroll_at _ | Browser_lane.Drag _ | Browser_lane.Follow_link _
        | Browser_lane.Fill_node _ -> Ok (request.expected_url,request.action) in
      let args = Browser_lane.interaction_args ~tab_id:id ~expected_url action in
      let* receipt = match action with
      | Browser_lane.Double_click _ | Browser_lane.Hover _ | Browser_lane.Drag_to _ | Browser_lane.Click _ | Browser_lane.Click_node _ ->
        Error (Before_effect "unresolved semantic pointer target")
      | Browser_lane.Double_click_at {point;viewport} -> pointer t context args ~viewport ~start:point Double_click_pointer
      | Browser_lane.Type_text {text;_} ->
        let* sources = pre (Browser_lane.Keyboard.text_source ~id:"masc-keyboard" text) in
        keyboard t context args ~sources ~name:"type_text"
      | Browser_lane.Press_key {key;_} ->
        keyboard t context args ~sources:(Browser_lane.Keyboard.input_source ~id:"masc-keyboard" key) ~name:"press_key"
      | Browser_lane.Hover_at {point;viewport} -> pointer t context args ~viewport ~start:point Hover_pointer
      | Browser_lane.Click_at {point;viewport;button} -> pointer t context args ~viewport ~start:point (Click_pointer button)
      | Browser_lane.Scroll_at {point;viewport;x;y} -> pointer t context args ~viewport ~start:point (Wheel_pointer {x;y})
      | Browser_lane.Tap_at {point;viewport} -> pointer t context args ~viewport ~start:point Tap_pointer
      | Browser_lane.Swipe {from;to_;viewport;via;duration_ms} -> pointer t context args ~viewport ~start:from (Swipe_pointer {destination=to_;via;duration_ms})
      | Browser_lane.Drag {from;to_;viewport;via;duration_ms} -> pointer t context args ~viewport ~start:from (Drag_pointer {destination=to_;via;duration_ms})
      | Browser_lane.Fill _ | Browser_lane.Select_option _ | Fill_node _ | Scroll _ | Follow_link _ ->
        (match script t context Browser_interaction.script args with
        | Error e -> Error (Outcome_unknown e)
        | Ok result -> (match field "interactionFailure" result with
            | Some failure -> let message=match string "message" failure with Ok s->s|Error s->s in
              (match field "effectStarted" failure with Some (`Bool false)->Error (Before_effect message)
               | _ -> Error (Outcome_unknown message))
            | None -> Ok result))
      | Browser_lane.Set_viewport size -> set_viewport t context args size
      | Browser_lane.Set_zoom _ -> Error (Before_effect "set_zoom requires a connected WebExtension browser")
      | Browser_lane.Activate_tab -> activate t context id args in
      let receipt = match receipt with
        | `Assoc fields -> obj (("action",str (Browser_lane.interaction_verb request.action))
            :: List.remove_assoc "action" fields)
        | other -> other in
      Result.map_error (fun detail -> Outcome_unknown detail) (with_tab id receipt))

(* How long a finishing connection waits for Firefox to end the session. A
   Firefox that is there answers at once; the window only bounds one that is
   not, so stopping the host does not wait on it. *)
let session_end_window_sec = 2.
module Endpoint = Ws_direct_core.Endpoint
module Message = Ws_direct_core.Connection.Message
exception Peer_finished of (unit, string) result
let with_connection ~env ~timeout ~url use =
  let* host,port,resource=Browser_bidi_downloads.endpoint url in
  try Eio.Switch.run (fun sw ->
    let clock=Eio.Stdenv.clock env and net=Eio.Stdenv.net env in
    let pending=Hashtbl.create 4 and sequence=ref 0 and broken=ref None and shut=ref None in
    let ended,set_ended=Eio.Promise.create () in
    (* No further page command is carried. The socket may still be open: this
       side stops trusting a connection whose command got no reply. *)
    let disconnect reason =
      if !broken=None then (
        broken:=Some reason;
        Eio.Promise.resolve set_ended reason);
      Hashtbl.iter (fun _ resolve->Eio.Promise.resolve resolve (Error (Unanswered reason))) pending;
      Hashtbl.clear pending in
    (* The socket itself is gone; nothing more can be sent. *)
    let closed reason = if !shut=None then shut:=Some reason; disconnect reason in
    Eio.Switch.on_release sw (fun ()->disconnect "BiDi connection closed");
    let connect () =
      Crypto_rng.ensure_default ();
      let* addr=match Eio.Net.getaddrinfo_stream net host ~service:(string_of_int port) with
        | first::_->Ok first|[]->Error "BiDi loopback address unavailable" in
      let flow=Eio.Net.connect ~sw net addr in
      let on_event = ref (fun (_ : Yojson.Safe.t) -> ()) in
      let settle id result = match Hashtbl.find_opt pending id with
        | None->()
        | Some resolve->Hashtbl.remove pending id;Eio.Promise.resolve resolve result in
      let on_message (message:Message.t) =
        match message.kind with
        | Message.Binary->disconnect "unexpected binary BiDi response"
        | Message.Text ->
          (match Yojson.Safe.from_string (Bigstringaf.to_string message.payload) with
          | exception Yojson.Json_error _->disconnect "invalid BiDi JSON"
          | json -> match field "type" json,field "id" json with
            | Some (`String "event"),_-> !on_event json
            | Some (`String "success"),Some (`Int id)->
              settle id (Result.map_error (fun detail->Unanswered detail) (required "result" json))
            | Some (`String "error"),Some (`Int id)->
              settle id (match string "error" json with
                | Ok code->Error (Rejected (error_code_of_wire code)) | Error detail->Error (Unanswered detail))
            | _->disconnect "invalid BiDi response envelope") in
      let builder _=Endpoint.handlers ~on_message
        ~on_close:(fun ~code:_ ~reason:_->closed "BiDi peer closed")
        ~on_error:closed ~on_eof:(fun ()->closed "BiDi EOF") () in
      let authority=(if host="::1" then "[::1]" else host)^":"^string_of_int port in
      (* ws-direct reports an upgrade the peer refused, or a head that did not
         arrive in its own window, as [Failure]. That is this connection's
         error, not an exception for the native host, which catches [Eio.Io]
         alone and would exit without a log line. *)
      let* wsd=match Ws_direct_eio.Client.connect ~sw ~clock ~host:authority ~resource
          ~max_message:reply_limit_bytes flow builder with
        | wsd->Ok wsd
        | exception Failure detail->Error ("BiDi connection: " ^ detail) in
      (* One command and its reply. A reply that arrived as the window
         closed is the reply. *)
      let exchange ~window method_ params =
        incr sequence;let id= !sequence in
        let reply,resolve=Eio.Promise.create () in Hashtbl.add pending id resolve;
        Endpoint.Wsd.send_text wsd (Yojson.Safe.to_string (obj ["id",`Int id;"method",str method_;"params",params]));
        Watched_work.run
          ~watcher:(fun ()->Eio.Time.sleep clock window; Error `Deadline_exceeded)
          (fun ()->Ok (Eio.Promise.await reply)) in
      let command method_ params =
        match !broken with Some e->Error (Unsent e)|None->
          (* The connection is ended only for a command that got no reply. *)
          (match exchange ~window:timeout method_ params with
           | Ok reply->reply
           | Error `Deadline_exceeded->
             disconnect "BiDi transport deadline exceeded";
             Error (Unanswered "BiDi transport deadline exceeded")
           (* The caller gave up on a command already written. Its reply is
              unknown, so nothing more is written behind it. *)
           | exception (Eio.Cancel.Cancelled _ as cancelled)->
             disconnect "BiDi command cancelled";
             raise cancelled) in
      (* Ending the session is not a page command. It is sent on a connection
         this side stopped trusting too, for as long as the socket is open: a
         page whose script hung is not a browser that is gone. *)
      let session_end () =
        match !shut with Some reason->Error (Connection_gone reason)|None->
          (match exchange ~window:session_end_window_sec "session.end" (obj []) with
           | Ok (Ok _)->Ok ()
           (* A session asked for and never confirmed, which Firefox says it
              does not have: there is none to end. *)
           | Ok (Error (Rejected Invalid_session_id))->Ok ()
           (* Firefox's own answer stays its answer when the socket closes
              right behind it. *)
           | Ok (Error (Rejected (Session_not_created | No_such_alert | Unexpected_alert_open | Other_error _) as declined))->
             Error (Not_confirmed (refusal_message declined))
           (* No answer: the socket closing under the request is the
              connection going, not Firefox declining. *)
           | Ok (Error (Unanswered _ | Unsent _ as lost))->
             (match !shut with
              | Some reason->Error (Connection_gone reason)
              | None->Error (Not_confirmed (refusal_message lost)))
           | Error `Deadline_exceeded->Error (Not_confirmed "no answer to session.end in time")) in
      (* The host owns the whole command deadline. A cancelled command ends this
         connection instead of admitting another write behind an unknown one. *)
      let peer = create ~session_end ~command in
      on_event := note_event peer;
      Ok peer in
    try
      (* A connection established as the deadline passed is the connection. *)
      let peer=match
          Watched_work.run
            ~watcher:(fun ()->
              Eio.Time.sleep clock timeout;
              Error "BiDi connection or command deadline exceeded")
            connect
        with
        | Ok peer->peer | Error reason->raise (Peer_finished (Error reason)) in
      (* ws-direct forks its reader/writer on [sw]. Returning normally would
         wait for that open socket before release hooks run. Exit the scope
         exceptionally to cancel both driver fibers, then recover only our
         private completion marker outside the switch. No close handshake or
         remote browser/tab command is required to stop an unresponsive peer. *)
      let result=use ~ended peer in
      raise (Peer_finished result)
    with
    | Eio.Cancel.Cancelled _ as exn->raise exn
    | Eio.Io _->raise (Peer_finished (Error "BiDi connection failed"))
    | End_of_file->raise (Peer_finished (Error "BiDi connection EOF")))
  with Peer_finished result->result
