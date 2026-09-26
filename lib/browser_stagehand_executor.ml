module Wire = Browser_stagehand_wire
module Session = Browser_stagehand_session

module Tabs = struct
  type t =
    { mutable next : int
    ; by_page : (string, int) Hashtbl.t
    ; by_id : (int, string) Hashtbl.t
    }

  let create () = { next = 0; by_page = Hashtbl.create 8; by_id = Hashtbl.create 8 }

  let id_of_page t page_id =
    match Hashtbl.find_opt t.by_page page_id with
    | Some id -> id
    | None ->
      let id = t.next in
      t.next <- id + 1;
      Hashtbl.replace t.by_page page_id id;
      Hashtbl.replace t.by_id id page_id;
      id
  ;;

  let page_of_id t id = Hashtbl.find_opt t.by_id id

  (* [next] is kept: an id handed out for a page of an earlier session is
     never handed out again. *)
  let forget_pages t =
    Hashtbl.reset t.by_page;
    Hashtbl.reset t.by_id
  ;;
end

type call = Wire.call -> (Yojson.Safe.t, Session.call_failure) result

let failure_message = function
  | Session.Not_attached -> "the Stagehand session is not attached"
  | Session.Detached -> "the Stagehand service worker went away"
  | Session.Connection_gone reason -> "the Stagehand connection ended: " ^ reason
  | Session.Abandoned_call_pending -> "a Stagehand call whose caller left has not answered yet"
  | Session.Not_delivered detail -> "the call did not reach Stagehand: " ^ detail
  | Session.Rejected { code; message } -> Printf.sprintf "Stagehand refused the call (%d): %s" code message
  | Session.Lost detail -> "Stagehand did not answer: " ^ detail
;;

let ( let* ) = Result.bind

let rec traverse f = function
  | [] -> Ok []
  | item :: rest ->
    let* first = f item in
    let* others = traverse f rest in
    Ok (first :: others)
;;

(* A call the extension never took cannot have taken effect. *)
let answer_before_effect failure =
  match failure with
  | Session.Not_attached | Session.Detached | Session.Connection_gone _ | Session.Abandoned_call_pending
  | Session.Not_delivered _ -> Browser_lane.Rejected_before_effect (failure_message failure)
  | Session.Rejected _ | Session.Lost _ -> Browser_lane.Refused (failure_message failure)
;;

(* For calls sent up to and including the verb's effect. *)
let send call request = Result.map_error answer_before_effect (call request)

(* For calls sent after the verb may have taken effect. *)
let send_after_effect call request =
  Result.map_error (fun failure -> Browser_lane.Refused (failure_message failure)) (call request)
;;

let malformed method_ what = Browser_lane.Refused (Printf.sprintf "Stagehand answered %s without %s" method_ what)
let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None

let string_field ~method_ key json =
  match field key json with
  | Some (`String value) -> Ok value
  | Some _ | None -> Error (malformed method_ (key ^ " as a string"))
;;

let page_id_of ~method_ json = string_field ~method_ "page_id" json

let pages_of = function
  | `List refs -> traverse (page_id_of ~method_:"context.pages") refs
  | _ -> Error (malformed "context.pages" "a list of pages")
;;

let active_of = function
  | `Null -> Ok None
  | json -> Result.map Option.some (page_id_of ~method_:"context.active_page" json)
;;

type page_runtime = Scene_runtime | No_runtime

(* The body's result goes back as a JSON string, and a throw as an object
   carrying its message: Stagehand words an uncaught throw by its CDP text,
   which is "Uncaught" for every throw, so the page script's reason
   (page_url_changed, scene_document_changed, ...) would not reach the
   caller. A string and an object cannot be mistaken for each other. *)
let evaluate_expression ~runtime ~body ~args =
  let runtime = match runtime with Scene_runtime -> Browser_scene_script.runtime | No_runtime -> "" in
  Printf.sprintf
    "(function(args) { %s\ntry { return JSON.stringify((function(){ %s }).call(null, args)); } catch (e) { return {thrown: String(e !== null && typeof e === 'object' && 'message' in e ? e.message : e)}; } })(%s)"
    runtime body (Yojson.Safe.to_string args)
;;

let evaluate ~runtime ~send page_id body =
  let* reply = send (Wire.Page_evaluate { page_id; expression = evaluate_expression ~runtime ~body ~args:`Null }) in
  match field "value" reply with
  | Some (`String encoded) ->
    (match Yojson.Safe.from_string encoded with
     | json -> Ok json
     | exception Yojson.Json_error _ -> Error (malformed "page.evaluate" "a JSON result"))
  (* The reason passes through as the automation lane passes it. Whether it
     came before or after the verb's effect is the caller's to say. *)
  | Some (`Assoc [ "thrown", `String reason ]) -> Error (Browser_lane.Refused reason)
  | Some _ | None -> Error (malformed "page.evaluate" "the script's JSON string")
;;

type summary = { url : string; title : string }

let summary_body = "return {url:location.href,title:document.title};"

let summary_of json =
  let* url = string_field ~method_:"page.evaluate" "url" json in
  let* title = string_field ~method_:"page.evaluate" "title" json in
  Ok { url; title }
;;

(* A capture is checked against the page before and after it, as the
   automation lane does: a navigation or a scroll in between is refused
   instead of labelling the image with the other state. *)
let observation_body =
  "return {url:location.href,title:document.title,viewport:browserScene({mode:'viewport'})};"
;;

let observation_of json =
  let* summary = summary_of json in
  match field "viewport" json with
  | Some viewport -> Ok (summary, viewport)
  | None -> Error (malformed "page.evaluate" "viewport")
;;

let page_of ~tabs tab_id =
  match Tabs.page_of_id tabs tab_id with
  | Some page_id -> Ok page_id
  | None -> Error (Browser_lane.Rejected_before_effect "unknown tab id; list tabs again")
;;

let absolute_http url =
  let uri = Uri.of_string url in
  match Uri.scheme uri, Uri.host uri with
  | Some ("http" | "https"), Some host when host <> "" -> Ok ()
  | _ -> Error (Browser_lane.Rejected_before_effect "navigation requires an absolute HTTP(S) URL")
;;

let list_tabs ~tabs ~call =
  let send = send call in
  let* pages = Result.bind (send Wire.Context_pages) pages_of in
  let* active = Result.bind (send Wire.Context_active_page) active_of in
  let* listed =
    traverse
      (fun page_id ->
        let* summary = Result.bind (evaluate ~runtime:No_runtime ~send page_id summary_body) summary_of in
        Ok
          (`Assoc
            [ "id", `Int (Tabs.id_of_page tabs page_id)
            ; "active", `Bool (Option.equal String.equal active (Some page_id))
            ; "title", `String summary.title
            ; "url", `String summary.url
            ]))
      pages
  in
  Ok (`List listed)
;;

let goto ~tabs ~call ~url ~tab_id =
  let* () = absolute_http url in
  let* page_id =
    match tab_id with
    | Some id -> page_of ~tabs id
    | None ->
      let* active = Result.bind (send call Wire.Context_active_page) active_of in
      Option.to_result ~none:(Browser_lane.Rejected_before_effect "no active tab to navigate; name a tabId") active
  in
  let* _ = send call (Wire.Page_goto { page_id; url }) in
  let* summary =
    Result.bind (evaluate ~runtime:No_runtime ~send:(send_after_effect call) page_id summary_body) summary_of
  in
  Ok (`Assoc [ "url", `String summary.url; "title", `String summary.title ])
;;

let capture ~tabs ~call ~tab_id =
  let send = send call in
  let* page_id = page_of ~tabs tab_id in
  let* (before, viewport) = Result.bind (evaluate ~runtime:Scene_runtime ~send page_id observation_body) observation_of in
  let* shot = send (Wire.Page_screenshot { page_id }) in
  let* data = string_field ~method_:"page.screenshot" "data" shot in
  let* (after, viewport_after) =
    Result.bind (evaluate ~runtime:Scene_runtime ~send page_id observation_body) observation_of
  in
  if String.equal before.url after.url && Yojson.Safe.equal viewport viewport_after then
    Ok
      (`Assoc
        [ "tabId", `Int tab_id
        ; "title", `String after.title
        ; "url", `String before.url
        ; (* page.screenshot answers PNG unless asked otherwise; the surface
             checks the bytes. *)
          "mimeType", `String "image/png"
        ; "data", `String data
        ; "viewport", viewport
        ])
  else Error (Browser_lane.Refused "the page moved during capture")
;;

(* Stagehand answers an act it could not carry out (no element matched, the
   action failed) as a normal result with [data.success = false], not as an
   RPC error. The act may already have touched the page, so the failure is
   [Refused], never a pre-effect rejection. Observe and extract report no such
   flag: their data is the answer. *)
let act_outcome data =
  match field "success" data, field "message" data with
  | Some (`Bool true), (Some _ | None) -> Ok ()
  | Some (`Bool false), Some (`String message) ->
    Error (Browser_lane.Refused ("Stagehand act did not succeed: " ^ message))
  | Some (`Bool false), (Some _ | None) -> Error (Browser_lane.Refused "Stagehand act did not succeed")
  | (Some _ | None), (Some _ | None) -> Error (malformed "stagehand.act" "data.success as a boolean")
;;

let sentence ~tabs ~call ~tab_id ~outcome to_call =
  let* page_id = page_of ~tabs tab_id in
  let request = to_call page_id in
  let* result = send call request in
  match field "data" result, field "metadata" result with
  | Some data, Some metadata ->
    let* () = outcome data in
    Ok (`Assoc [ "tabId", `Int tab_id; "data", data; "metadata", metadata ])
  | (Some _ | None), (Some _ | None) -> Error (malformed (Wire.method_name request) "data and metadata")
;;

let reported_as_data (_ : Yojson.Safe.t) = Ok ()

let execute ~tabs ~call verb =
  let served =
    match verb with
    | Browser_lane.Tabs_list -> list_tabs ~tabs ~call
    | Browser_lane.Page_goto { url; tab_id } -> goto ~tabs ~call ~url ~tab_id
    | Browser_lane.Page_capture { tab_id } -> capture ~tabs ~call ~tab_id
    | Browser_lane.Page_instruct { tab_id; instruction } ->
      sentence ~tabs ~call ~tab_id ~outcome:act_outcome (fun page_id -> Wire.Act { page_id; instruction; timeout = Wire.sentence_timeout })
    | Browser_lane.Page_locate { tab_id; instruction } ->
      sentence ~tabs ~call ~tab_id ~outcome:reported_as_data (fun page_id -> Wire.Observe { page_id; instruction; timeout = Wire.sentence_timeout })
    | Browser_lane.Page_extract { tab_id; instruction; schema } ->
      sentence ~tabs ~call ~tab_id ~outcome:reported_as_data (fun page_id -> Wire.Extract { page_id; instruction; schema; timeout = Wire.sentence_timeout })
    | Browser_lane.Session_open _ | Browser_lane.Session_close | Browser_lane.Session_status | Browser_lane.Page_read _
    | Browser_lane.Page_document _ | Browser_lane.Page_downloads _ | Browser_lane.Page_scene _
    | Browser_lane.Page_interact _ | Browser_lane.Page_elements _ | Browser_lane.Page_act _ | Browser_lane.Page_context _ ->
      Error
        (Browser_lane.Rejected_before_effect
           ("the Stagehand page executor does not serve " ^ Browser_lane.verb_to_string verb))
  in
  match served with
  | Ok data -> Browser_lane.Answered (`Assoc [ "ok", `Bool true; "data", data ])
  | Error answer -> answer
;;
