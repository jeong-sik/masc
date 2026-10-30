module C = Browser_cdp
module B = Browser_stagehand_backend
module P = Browser_extension_protocol
open Result.Syntax
let field name = function `Assoc fields -> List.assoc_opt name fields | _ -> None
let command cdp ?session name value = C.command cdp ?session name value |> Result.map_error (fun _ -> ())
let evaluate cdp ~session ~program arguments =
  let expression="(async()=>{const context=" ^ Yojson.Safe.to_string arguments
    ^ ";const operation=(" ^ program ^ ");return await operation(context);})()" in
  let* value=command cdp ~session "Runtime.evaluate" (`Assoc ["expression",`String expression;
    "awaitPromise",`Bool true;"returnByValue",`Bool true]) in
  match field "exceptionDetails" value, Option.bind (field "result" value) (field "value") with
  | None,Some value -> Ok value
  | (Some _|None),(Some _|None) -> Error ()

let chrome_context cdp ~stagehand ~page_id arguments =
  let* target=command cdp "Target.getTargetInfo" (`Assoc ["targetId",`String page_id]) in
  let* info=match field "targetInfo" target with Some value ->
    C.target_info_of_json value |> Result.map_error (fun _ -> ()) | None -> Error () in
  let uri=Uri.of_string info.url in
  let* ()=match info.kind,Uri.scheme uri,Uri.host uri,Uri.userinfo uri with
    | C.Page,Some "https",Some _,None when info.target_id=page_id -> Ok ()
    | (C.Page|Service_worker|Other_kind _),(Some _|None),(Some _|None),(Some _|None) -> Error () in
  let* value=evaluate cdp ~session:stagehand
    ~program:{|async ({page_id})=>{const targets=await chrome.debugger.getTargets();
const matches=targets.filter(t=>t.type==="page"&&t.id===page_id&&Number.isSafeInteger(t.tabId)&&t.tabId>=0);
if(matches.length!==1) return {unavailable:true};
return {tab_id:matches[0].tabId,url:matches[0].url};}|}
    (`Assoc ["page_id",`String page_id]) in
  match field "tab_id" value,field "url" value with
  | Some (`Int tab_id),Some (`String url) when tab_id>=0 && url=info.url ->
      Ok (`Assoc ["tab_id",`Int tab_id;"page_id",`String page_id;"url",`String url;"arguments",arguments])
  | (Some _|None),(Some _|None) -> Error ()

let worker cdp ~extension_id =
  let changed=Eio.Condition.create () and revision=ref 0 in
  let signal ()=incr revision;Eio.Condition.broadcast changed in
  let unsubscribe=C.subscribe_events cdp (function
    | C.Target_created _|Target_destroyed _|Target_detached _|Connection_ended _ -> signal ()
    | Binding_called _|Malformed_event _|Unobserved _ -> ()) in
  Fun.protect ~finally:unsubscribe (fun () ->
    let* _=command cdp "Target.setDiscoverTargets" (`Assoc ["discover",`Bool true]) in
    let rec find () =
      let seen= !revision in
      let* value=command cdp "Target.getTargets" (`Assoc []) in
      let* targets=match field "targetInfos" value with Some (`List targets) -> Ok targets | Some _|None -> Error () in
      let matches=List.filter_map (fun value -> match C.target_info_of_json value with
        | Ok ({kind=C.Service_worker;url;_} as target) ->
            let uri=Uri.of_string url in
            if Uri.scheme uri=Some "chrome-extension" && Uri.host uri=Some extension_id
              && Uri.userinfo uri=None then Some target else None
        | Ok {kind=(C.Page|Other_kind _);_}|Error _ -> None) targets in
      match matches with
      | [target] -> Ok target.C.target_id
      | _::_::_ -> Error ()
      | [] ->
          Eio.Condition.loop_no_mutex changed (fun () ->
            if !revision<>seen || Option.is_some (C.lost_reason cdp) then Some () else None);
          if Option.is_some (C.lost_reason cdp) then Error () else find () in
    find ())

type link = { cdp:C.t; extension_id:string; directory:string; worker:string; target:string;
  mutable alive:bool; mutable unsubscribe:unit -> unit; fence:unit -> unit }
type 'session bound = { pin:'session B.private_session; tab_id:int; link:link }
type 'session binding = Preparing | Ready of 'session bound | Busy of 'session bound | Released
let create ~sw ~backend ~transport =
  let bindings=Hashtbl.create 4 and links=ref [] in
  Eio.Switch.on_release sw (fun () -> List.iter (fun link -> link.unsubscribe ()) !links;links:=[]);
  let load cdp ~extension_id ~directory ~fence =
    let* directory=Eio_unix.run_in_systhread (fun () ->
      try Ok (Unix.realpath directory) with Unix.Unix_error _ -> Error ()) in
    match List.find_opt (fun link -> link.cdp==cdp && link.extension_id=extension_id) !links with
    | Some link when link.alive && link.directory=directory -> Ok link
    | Some _ -> Error ()
    | None ->
      let* result=command cdp "Extensions.loadUnpacked" (`Assoc ["path",`String directory]) in
      let* ()=if field "id" result=Some (`String extension_id) then Ok () else Error () in
      let* target=worker cdp ~extension_id in
      let* attached=command cdp "Target.attachToTarget" (`Assoc ["targetId",`String target;"flatten",`Bool true]) in
      let* session=match field "sessionId" attached with Some (`String value) when value<>"" -> Ok value | Some _|None -> Error () in
      let link={cdp;extension_id;directory;target;worker=session;alive=true;unsubscribe=(fun () -> ());fence} in
      let retire () =
        link.alive<-false;link.fence ();
        link.unsubscribe ();links:=List.filter (fun current -> current!=link) !links in
      link.unsubscribe<-C.subscribe_events cdp (function
        | C.Target_destroyed {target_id} when target_id=link.target -> retire ()
        | C.Target_detached {session} when session=link.worker -> retire ()
        | C.Connection_ended _ -> retire ()
        | Target_created _|Target_destroyed _|Target_detached _|Binding_called _|Malformed_event _|Unobserved _ -> ());
      links:=link::!links;Ok link in
  let map_error = function B.Private_not_started -> P.Not_started
    | B.Private_session_fenced|B.Private_outcome_unknown -> P.Outcome_unknown in
  let execute bound program arguments =
    B.execute_private backend ~session:bound.pin ~tab_id:bound.tab_id
      ~run:(fun original ~page_id ->
        if not bound.link.alive then Error () else
        transport original (fun cdp ~worker:stagehand ->
          if cdp!=bound.link.cdp then Error () else
          let* context=chrome_context cdp ~stagehand ~page_id arguments in
          let* result=evaluate cdp ~session:bound.link.worker ~program context in
          if bound.link.alive then Ok result else Error ()))
      |> Result.map_error map_error in
  fun request ->
    let* request=P.of_json (P.to_json request) |> Result.map_error (fun () -> P.Not_started) in
    match request with
    | P.Prepare {operation_id;tab_id;extension_id;directory;program;arguments} ->
      if Hashtbl.mem bindings operation_id then Error P.Not_started else (
        Hashtbl.add bindings operation_id Preparing;
        let* pin=match B.capture_private_session backend with
          | Ok pin -> Ok pin
          | Error error -> Hashtbl.replace bindings operation_id Released;Error (map_error error) in
        let selected=ref None in
        let result=B.execute_private backend ~session:pin ~tab_id ~run:(fun original ~page_id ->
          transport original (fun cdp ~worker:stagehand ->
            let* context=chrome_context cdp ~stagehand ~page_id arguments in
            let* link=load cdp ~extension_id ~directory
              ~fence:(fun () -> B.fence_private_session backend ~session:pin) in
            let* value=evaluate cdp ~session:link.worker ~program context in
            if not link.alive || value<>`Assoc ["ready",`Bool true] then Error () else (
              selected:=Some link;Ok (`Assoc ["prepared",`Bool true])))) |> Result.map_error map_error in
        match result,!selected with
        | Ok value,Some link -> Hashtbl.replace bindings operation_id (Ready {pin;tab_id;link});Ok value
        | (Ok _|Error _),(Some _|None) ->
            Hashtbl.replace bindings operation_id Released;
            (match result with Error error -> Error error | Ok _ -> Error P.Outcome_unknown))
    | P.Invoke {operation_id;program;arguments} ->
        (match Hashtbl.find_opt bindings operation_id with
         | Some (Ready bound) ->
           Hashtbl.replace bindings operation_id (Busy bound);
           Fun.protect ~finally:(fun () -> Hashtbl.replace bindings operation_id (Ready bound))
             (fun () -> execute bound program arguments)
         | Some (Preparing|Busy _|Released)|None -> Error P.Not_started)
    | P.Release operation_id ->
        (match Hashtbl.find_opt bindings operation_id with
         | Some (Ready _) -> Hashtbl.replace bindings operation_id Released;Ok (`Assoc ["released",`Bool true])
         | Some (Preparing|Busy _|Released)|None -> Error P.Not_started)
