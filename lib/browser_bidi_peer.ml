let ( let* ) = Result.bind
let field name = function `Assoc xs -> List.assoc_opt name xs | _ -> None
let string name json = match field name json with
  | Some (`String s) when s <> "" -> Ok s | _ -> Error ("BiDi missing " ^ name)
let obj xs = `Assoc xs
let str s = `String s
let required name json = match field name json with Some v -> Ok v | None -> Error ("missing " ^ name)
type failure = Before_effect of string | Outcome_unknown of string
type t = { command : string -> Yojson.Safe.t -> (Yojson.Safe.t,string) result;
  mutable contexts : (string * int) list; mutable next_tab : int; mutable version : string option }
let create ~command = {command;contexts=[];next_tab=0;version=None}
let metadata t =
  let* result = t.command "session.new" (obj ["capabilities",obj []]) in
  let* caps = required "capabilities" result in
  let* name = string "browserName" caps in
  if name <> "firefox" then Error "BiDi peer must be Firefox"
  else let* version=string "browserVersion" caps in t.version<-Some version;Ok version
let evaluate t context body args =
  let declaration = "function(args) { " ^ Browser_scene_script.runtime
    ^ "\nreturn JSON.stringify((function(){" ^ body ^ "}).call(null,args)); }" in
  let* result = t.command "script.callFunction" (obj [
    "functionDeclaration",str declaration;"target",obj ["context",str context];
    "awaitPromise",`Bool false;"arguments",`List [obj ["type",str "string";"value",str (Yojson.Safe.to_string args)]]]) in
  (* Arguments cross the protocol as a JSON string, decoded by the fixed body. *)
  match field "type" result with
  | Some (`String "success") ->
    let* value = required "result" result in let* encoded = string "value" value in
    (try Ok (Yojson.Safe.from_string encoded) with Yojson.Json_error _ -> Error "invalid BiDi script JSON")
  | Some (`String "exception") -> Error "Firefox rejected the fixed page script"
  | _ -> Error "invalid BiDi script result"
let script t context body args = evaluate t context ("arguments[0]=JSON.parse(arguments[0]);\n" ^ body) args
let scene t context args = script t context "return browserScene(arguments[0]);" args
let page t context = script t context
  "return {url:location.href,title:document.title,text:document.body?.innerText ?? '',active:document.visibilityState==='visible',scrollX,scrollY};" (obj [])
let tree t =
  let* result = t.command "browsingContext.getTree" (obj []) in
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
  | Some (`Bool true) -> Error "BiDi page.read does not support includeHtml; use a bounded scene read"
  | None | Some (`Bool false) -> script t context
      "const chars=Array.from(document.body?.innerText??''); const cap=arguments[0].cap; return {url:location.href,title:document.title,text:chars.slice(0,cap).join(''),chars:chars.length,truncated:chars.length>cap};" (obj ["cap",`Int cap])
  | _ -> Error "invalid includeHtml"
type pointer_motion = Click_pointer | Drag_pointer of Browser_lane.Pointer.point
  | Wheel_pointer of { x : int; y : int }
let pointer t context args ~(viewport : Browser_lane.Pointer.viewport) ~start motion =
  let before result = Result.map_error (fun e -> Before_effect e) result in
  let unknown result = Result.map_error (fun e -> Outcome_unknown e) result in
  let* observed = before (script t context Browser_interaction.pointer_guard_script args) in
  let coords (p : Browser_lane.Pointer.point) = ["x",`Int (int_of_float (p.x *. viewport.width));"y",`Int (int_of_float (p.y *. viewport.height))] in
  let move p = obj (["type",str "pointerMove";"origin",str "viewport"] @ coords p) in
  let button name = obj ["type",str name;"button",`Int 0] in
  let source = match motion with
    | Wheel_pointer {x;y} ->
      obj ["type",str "wheel";"id",str "masc-wheel";"actions",`List [obj
        (["type",str "scroll";"deltaX",`Int x;"deltaY",`Int y;"origin",str "viewport"] @ coords start)]]
    | Click_pointer | Drag_pointer _ ->
      let middle=match motion with Drag_pointer finish->[move finish]
        | Click_pointer | Wheel_pointer _->[] in
      obj ["type",str "pointer";"id",str "masc-pointer";"parameters",obj ["pointerType",str "mouse"];
        "actions",`List ([move start;button "pointerDown"] @ middle @ [button "pointerUp"])] in
  (* No replay after dispatch. Release is itself a protocol action and remains
     bounded by the transport deadline. Protected release cleanup may outlast
     the host command deadline by that bound; failure ends the client. *)
  let released=ref (Ok ()) in
  let applied=Eio.Switch.run (fun sw ->
    (match motion with
    | Wheel_pointer _ -> ()
    | Click_pointer | Drag_pointer _ -> Eio.Switch.on_release sw (fun ()->
      released:=Result.map (fun _->()) (t.command "input.releaseActions" (obj ["context",str context]))));
    t.command "input.performActions" (obj ["context",str context;"actions",`List [source]])) in
  let* _=unknown applied in
  let* ()=unknown !released in
  let* after = unknown (page t context) in
  let* old_url = unknown (string "url" observed) in
  let action=match motion with Click_pointer->"click_at"|Drag_pointer _->"drag"|Wheel_pointer _->"scroll_at" in
  match after with `Assoc fields -> Ok (obj (("action",str action)::("urlBefore",str old_url)::fields))
  | _ -> Error (Outcome_unknown "invalid post-input observation")
let dispatch t ~verb args =
  let pre r = Result.map_error (fun e -> Before_effect e) r in
  if verb="browser.info" then
    (match t.version with Some version->Ok (obj ["name",str "Firefox";"version",str version])
     | None->Error (Before_effect "BiDi session metadata is unavailable"))
  else if verb="tabs.list" then
    let* current = pre (tree t) in
    let rec rows index acc = function
      | [] -> Ok (`List (List.rev acc))
      | (context,id)::rest -> let* p=pre (page t context) in
        let* url=pre (string "url" p) in let* title=pre (required "title" p) in let* active=pre (required "active" p) in
        rows (index+1) (obj ["id",`Int id;"index",`Int index;"url",str url;"title",title;"active",active]::acc) rest in
    rows 0 [] current
  else if not (List.mem verb ["page.read";"page.scene";"page.capture";"page.interact"])
  then Error (Before_effect "unsupported BiDi browser verb")
  else let* context,id=pre (resolve t args) in
    match verb with
    | "page.read" -> pre (let* p=read t context args in with_tab id p)
    | "page.scene" -> pre (let* fields=match args with `Assoc xs->Ok xs|_->Error "invalid scene arguments" in
        let* p=scene t context (obj (("mode",str "read")::fields)) in with_tab id p)
    | "page.capture" -> pre (
        let* p=page t context in let* viewport=scene t context (obj ["mode",str "viewport"]) in
        let* png=t.command "browsingContext.captureScreenshot" (obj ["context",str context]) in
        let* after=page t context in let* after_viewport=scene t context (obj ["mode",str "viewport"]) in
        let* url=string "url" p in let* after_url=string "url" after in
        if url<>after_url || viewport<>after_viewport then Error "viewport_changed_during_capture" else
        let* title=required "title" after in let* data=string "data" png in
        Ok (obj ["tabId",`Int id;"url",str url;"title",title;"mimeType",str "image/png";"data",str data;"viewport",viewport]))
    | "page.interact" ->
      let* fields=pre (match args with `Assoc xs->Ok xs|_->Error "invalid interaction") in
      let* request=pre (Browser_interaction.parse (obj (("lane",str "live")::fields))) in
      (match request.action with
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
      | Browser_lane.Activate_tab -> Error (Before_effect "unsupported BiDi interaction"))
    | _ -> Error (Before_effect "unsupported BiDi browser verb")

module Endpoint = Ws_direct_core.Endpoint
module Message = Ws_direct_core.Connection.Message
let with_connection ~env ~timeout ~url use =
  let* host,port,resource=Browser_bidi_downloads.endpoint url in
  Eio.Switch.run (fun sw ->
    let clock=Eio.Stdenv.clock env and net=Eio.Stdenv.net env in
    let pending=Hashtbl.create 4 and sequence=ref 0 and broken=ref None in
    let disconnect reason =
      if !broken=None then (
        broken:=Some reason;
        Hashtbl.iter (fun _ resolve->Eio.Promise.resolve resolve (Error reason)) pending;
        Hashtbl.clear pending) in
    Eio.Switch.on_release sw (fun ()->disconnect "BiDi connection closed");
    let connect () =
      Crypto_rng.ensure_default ();
      let* addr=match Eio.Net.getaddrinfo_stream net host ~service:(string_of_int port) with
        | first::_->Ok first|[]->Error "BiDi loopback address unavailable" in
      let flow=Eio.Net.connect ~sw net addr in
      let on_message (message:Message.t) =
        match message.kind with
        | Message.Binary->disconnect "unexpected binary BiDi response"
        | Message.Text ->
          (match Yojson.Safe.from_string (Bigstringaf.to_string message.payload) with
          | exception Yojson.Json_error _->disconnect "invalid BiDi JSON"
          | json -> match field "type" json,field "id" json with
            | Some (`String "event"),_->()
            | Some (`String ("success"|"error" as kind)),Some (`Int id)->
              (match Hashtbl.find_opt pending id with
              | None->()
              | Some resolve->Hashtbl.remove pending id;
                let result=if kind="success" then required "result" json else
                  let* code=string "error" json in Error ("BiDi command rejected: " ^ code) in
                Eio.Promise.resolve resolve result)
            | _->disconnect "invalid BiDi response envelope") in
      let builder _=Endpoint.handlers ~on_message
        ~on_close:(fun ~code:_ ~reason:_->disconnect "BiDi peer closed")
        ~on_error:disconnect ~on_eof:(fun ()->disconnect "BiDi EOF") () in
      let authority=(if host="::1" then "[::1]" else host)^":"^string_of_int port in
      let wsd=Ws_direct_eio.Client.connect ~sw ~clock ~host:authority ~resource
        ~max_message:(8*1024*1024) flow builder in
      let command method_ params =
        match !broken with Some e->Error e|None->
          incr sequence;let id= !sequence in
          let reply,resolve=Eio.Promise.create () in Hashtbl.add pending id resolve;
          Endpoint.Wsd.send_text wsd (Yojson.Safe.to_string (obj ["id",`Int id;"method",str method_;"params",params]));
          (try Eio.Time.with_timeout_exn clock timeout (fun ()->Eio.Promise.await reply)
           with Eio.Time.Timeout->
             disconnect "BiDi transport deadline exceeded";
             Error "BiDi transport deadline exceeded") in
      (* The host owns the whole command deadline. A cancelled command ends this
         connection instead of admitting another write behind an unknown one. *)
      Ok (create ~command) in
    try
      let* peer=Eio.Time.with_timeout_exn clock timeout connect in
      use peer
    with
    | Eio.Time.Timeout->Error "BiDi connection or command deadline exceeded"
    | Eio.Cancel.Cancelled _ as exn->raise exn
    | Eio.Io _->Error "BiDi connection failed"
    | End_of_file->Error "BiDi connection EOF")
