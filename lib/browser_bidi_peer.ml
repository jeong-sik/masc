let ( let* ) = Result.bind
let field name = function `Assoc xs -> List.assoc_opt name xs | _ -> None
let string name json = match field name json with
  | Some (`String s) when s <> "" -> Ok s | _ -> Error ("BiDi missing " ^ name)
let obj xs = `Assoc xs
let str s = `String s
let required name json = match field name json with Some v -> Ok v | None -> Error ("missing " ^ name)
type failure = Before_effect of string | Outcome_unknown of string
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
type error_code = Session_not_created | Invalid_session_id | Other_error of string
let error_code_of_wire = function
  | "session not created" -> Session_not_created
  | "invalid session id" -> Invalid_session_id
  | code -> Other_error code
let error_code_to_wire = function
  | Session_not_created -> "session not created"
  | Invalid_session_id -> "invalid session id"
  | Other_error code -> code
type refusal = Rejected of error_code | Unanswered of string | Unsent of string
let refusal_message = function
  | Rejected code -> "BiDi command rejected: " ^ error_code_to_wire code
  | Unanswered why | Unsent why -> why
type verb = Browser_info | Tabs_list | Page_read | Page_elements | Page_capture | Page_scene | Page_interact
let verb_to_wire = function
  | Browser_info -> "browser.info" | Tabs_list -> "tabs.list" | Page_read -> "page.read"
  | Page_scene -> "page.scene" | Page_elements -> "page.elements" | Page_capture -> "page.capture"
  | Page_interact -> "page.interact"
let verb_of_wire = function
  | "browser.info" -> Some Browser_info | "tabs.list" -> Some Tabs_list | "page.read" -> Some Page_read
  | "page.scene" -> Some Page_scene | "page.elements" -> Some Page_elements
  | "page.capture" -> Some Page_capture | "page.interact" -> Some Page_interact
  | _ -> None
type session_end_failure = Connection_gone of string | Not_confirmed of string
let session_end_failure_message = function Connection_gone why | Not_confirmed why -> why
type session_failure = Session_refused of string | Session_failed of string
let session_failure_message = function Session_refused why | Session_failed why -> why
type t = { ask : string -> Yojson.Safe.t -> (Yojson.Safe.t,refusal) result;
  session_end : unit -> (unit,session_end_failure) result; mutable session_may_exist : bool;
  mutable contexts : (string * int) list; mutable next_tab : int; mutable version : string option }
let create ~session_end ~command =
  {ask=command;session_end;session_may_exist=false;contexts=[];next_tab=0;version=None}
let command t method_ params = Result.map_error refusal_message (t.ask method_ params)
(* Firefox keeps a session whose socket closed and takes one session at a
   time, so one left behind refuses every later connection until that Firefox
   is restarted. Ending it closes no tab and leaves the browser running. *)
let end_session t =
  if not t.session_may_exist then Ok ()
  else let* () = t.session_end () in t.session_may_exist <- false; Ok ()
let metadata t =
  (* Firefox may hold a session from the moment it is asked for one, whether
     or not its answer arrives. There is none when it refused, and none when
     the request was never written. *)
  t.session_may_exist <- true;
  match t.ask "session.new" (obj ["capabilities",obj []]) with
  | Error (Rejected Session_not_created as refused) ->
    t.session_may_exist <- false; Error (Session_refused (refusal_message refused))
  | Error (Rejected (Invalid_session_id | Other_error _) | Unsent _ as refused) ->
    t.session_may_exist <- false; Error (Session_failed (refusal_message refused))
  | Error (Unanswered _ as unanswered) -> Error (Session_failed (refusal_message unanswered))
  | Ok result ->
    Result.map_error (fun detail -> Session_failed detail)
      (let* caps = required "capabilities" result in
       let* name = string "browserName" caps in
       if name <> "firefox" then Error "BiDi peer must be Firefox"
       else let* version=string "browserVersion" caps in t.version<-Some version;Ok version)
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
let evaluate t context body args =
  let declaration = "function(args) { " ^ Browser_scene_script.runtime
    ^ "\nconst answer = JSON.stringify((function(){" ^ body ^ "}).call(null,args));"
    ^ Printf.sprintf "\nreturn typeof answer === 'string' && answer.length > %d ? answer.length : answer; }"
        script_answer_limit_units in
  let* result = command t "script.callFunction" (obj [
    "functionDeclaration",str declaration;"target",obj ["context",str context];
    "awaitPromise",`Bool false;"arguments",`List [obj ["type",str "string";"value",str (Yojson.Safe.to_string args)]]]) in
  (* Arguments cross the protocol as a JSON string, decoded by the fixed body. *)
  match field "type" result with
  | Some (`String "success") ->
    let* value = required "result" result in
    (match field "type" value, field "value" value with
     | Some (`String "string"), Some (`String encoded) ->
       (try Ok (Yojson.Safe.from_string encoded) with Yojson.Json_error _ -> Error "invalid BiDi script JSON")
     | Some (`String "number"), Some (`Int units) -> Error (answer_too_large units)
     | _ -> Error "invalid BiDi script result")
  | Some (`String "exception") -> Error "Firefox rejected the fixed page script"
  | _ -> Error "invalid BiDi script result"
let script t context body args = evaluate t context ("arguments[0]=JSON.parse(arguments[0]);\n" ^ body) args
let scene t context args = script t context "return browserScene(arguments[0]);" args
let page t context = script t context
  "return {url:location.href,title:document.title,text:document.body?.innerText ?? '',active:document.visibilityState==='visible',scrollX,scrollY};" (obj [])
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
let tree t =
  let* result = command t "browsingContext.getTree" (obj []) in
  match field "contexts" result with
  | Some (`List rows) ->
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | row::rest -> let* context = string "context" row in
        let id = match List.assoc_opt context t.contexts with Some id -> id | None ->
          t.next_tab <- t.next_tab + 1;
          t.contexts <- (context,t.next_tab)::t.contexts; t.next_tab in
        collect ((context,id)::acc) rest in
    collect [] rows
  | _ -> Error "invalid BiDi context tree"
let resolve t args =
  let* current = tree t in
  match field "tabId" args with
  | Some (`Int id) -> (match List.find_opt (fun (_,n) -> n=id) current with
      | Some (context,_) -> Ok (context,id) | None -> Error "browser tab is no longer present")
  | None ->
    let rec active = function
      | [] -> Error "no active browser context"
      | (context,id)::rest -> let* p = page t context in
        (match field "active" p with Some (`Bool true) -> Ok (context,id) | _ -> active rest) in active current
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
type pointer_motion = Hover_pointer | Click_pointer | Drag_pointer of Browser_lane.Pointer.point
  | Wheel_pointer of { x : int; y : int }
let pointer t context args ~(viewport : Browser_lane.Pointer.viewport) ~start motion =
  let before result = Result.map_error (fun e -> Before_effect e) result in
  let unknown result = Result.map_error (fun e -> Outcome_unknown e) result in
  let* observed = before (script t context Browser_interaction.pointer_guard_script args) in
  let coords (p : Browser_lane.Pointer.point) = ["x",`Int (int_of_float (p.x *. viewport.width));"y",`Int (int_of_float (p.y *. viewport.height))] in
  let move p = obj (["type",str "pointerMove";"origin",str "viewport"] @ coords p) in
  let button name = obj ["type",str name;"button",`Int 0] in
  let source = match motion with
    | Hover_pointer ->
      obj ["type",str "pointer";"id",str "masc-pointer";"parameters",obj ["pointerType",str "mouse"];
        "actions",`List [move start]]
    | Wheel_pointer {x;y} ->
      obj ["type",str "wheel";"id",str "masc-wheel";"actions",`List [obj
        (["type",str "scroll";"deltaX",`Int x;"deltaY",`Int y;"origin",str "viewport"] @ coords start)]]
    | Click_pointer | Drag_pointer _ ->
      let middle=match motion with Drag_pointer finish->[move finish]
        | Hover_pointer | Click_pointer | Wheel_pointer _->[] in
      obj ["type",str "pointer";"id",str "masc-pointer";"parameters",obj ["pointerType",str "mouse"];
        "actions",`List ([move start;button "pointerDown"] @ middle @ [button "pointerUp"])] in
  (* No replay after dispatch. Release is itself a protocol action and remains
     bounded by the transport deadline. Protected release cleanup may outlast
     the host command deadline by that bound; failure ends the client. *)
  let released=ref (Ok ()) in
  let applied=Eio.Switch.run (fun sw ->
    (match motion with
    | Hover_pointer | Wheel_pointer _ -> ()
    | Click_pointer | Drag_pointer _ -> Eio.Switch.on_release sw (fun ()->
      released:=Result.map (fun _->()) (command t "input.releaseActions" (obj ["context",str context]))));
    command t "input.performActions" (obj ["context",str context;"actions",`List [source]])) in
  let* _=unknown applied in
  let* ()=unknown !released in
  let* after = unknown (page t context) in
  let* old_url = unknown (string "url" observed) in
  let action=match motion with Hover_pointer->"hover_at"|Click_pointer->"click_at"|Drag_pointer _->"drag"|Wheel_pointer _->"scroll_at" in
  match after with `Assoc fields -> Ok (obj (("action",str action)::("urlBefore",str old_url)::fields))
  | _ -> Error (Outcome_unknown "invalid post-input observation")
let dispatch t ~verb args =
  let pre r = Result.map_error (fun e -> Before_effect e) r in
  let on_tab use = let* context,id=pre (resolve t args) in use context id in
  match verb with
  | Browser_info ->
    (match t.version with Some version->Ok (obj ["name",str "Firefox";"version",str version])
     | None->Error (Before_effect "BiDi session metadata is unavailable"))
  | Tabs_list ->
    let* current = pre (tree t) in
    let rec rows index acc = function
      | [] -> Ok (`List (List.rev acc))
      | (context,id)::rest -> let* p=pre (page t context) in
        let* url=pre (string "url" p) in let* title=pre (required "title" p) in let* active=pre (required "active" p) in
        rows (index+1) (obj ["id",`Int id;"index",`Int index;"url",str url;"title",title;"active",active]::acc) rest in
    rows 0 [] current
  | Page_elements -> on_tab (fun context id -> pre (
        (* The inventory the automation lane reads, so its selectors mean the
           same thing to the DOM interactions below. *)
        let* p=parsed_document t context Browser_page_script.elements (obj []) in with_tab id p))
  | Page_read -> on_tab (fun context id -> pre (let* p=read t context args in with_tab id p))
  | Page_scene -> on_tab (fun context id -> pre (let* fields=match args with `Assoc xs->Ok xs|_->Error "invalid scene arguments" in
        let* p=scene t context (obj (("mode",str "read")::fields)) in with_tab id p))
  | Page_capture -> on_tab (fun context id -> pre (
        let* p=page t context in let* viewport=scene t context (obj ["mode",str "viewport"]) in
        let* png=command t "browsingContext.captureScreenshot" (obj ["context",str context]) in
        let* after=page t context in let* after_viewport=scene t context (obj ["mode",str "viewport"]) in
        let* url=string "url" p in let* after_url=string "url" after in
        if url<>after_url || viewport<>after_viewport then Error "viewport_changed_during_capture" else
        let* title=required "title" after in let* data=string "data" png in
        Ok (obj ["tabId",`Int id;"url",str url;"title",title;"mimeType",str "image/png";"data",str data;"viewport",viewport])))
  | Page_interact -> on_tab (fun context id ->
      let* fields=pre (match args with `Assoc xs->Ok xs|_->Error "invalid interaction") in
      let* request=pre (Browser_interaction.parse (obj (("lane",str Browser_lane.Lane_name.(to_wire Live))::fields))) in
      let* receipt = match request.action with
      | Browser_lane.Hover_at {point;viewport} -> pointer t context args ~viewport ~start:point Hover_pointer
      | Browser_lane.Click_at {point;viewport} -> pointer t context args ~viewport ~start:point Click_pointer
      | Browser_lane.Scroll_at {point;viewport;x;y} -> pointer t context args ~viewport ~start:point (Wheel_pointer {x;y})
      | Browser_lane.Drag {from;to_;viewport} -> pointer t context args ~viewport ~start:from (Drag_pointer to_)
      | Browser_lane.Click _ | Click_node _ | Fill _ | Fill_node _ | Scroll _ | Follow_link _ ->
        (match script t context Browser_interaction.script args with
        | Error e -> Error (Outcome_unknown e)
        | Ok result -> (match field "interactionFailure" result with
            | Some failure -> let message=match string "message" failure with Ok s->s|Error s->s in
              (match field "effectStarted" failure with Some (`Bool false)->Error (Before_effect message)
               | _ -> Error (Outcome_unknown message))
            | None -> Ok result))
      | Browser_lane.Activate_tab -> Error (Before_effect "unsupported BiDi interaction") in
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
            | Some (`String "event"),_->()
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
           | Ok (Error (Rejected (Session_not_created | Other_error _) as declined))->
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
      Ok (create ~session_end ~command) in
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
