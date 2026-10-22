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

  let forget_page t page_id =
    match Hashtbl.find_opt t.by_page page_id with
    | None -> ()
    | Some id -> Hashtbl.remove t.by_page page_id; Hashtbl.remove t.by_id id
  ;;

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

let evaluate ~runtime ~send ?(args = `Null) page_id body =
  let* reply = send (Wire.Page_evaluate { page_id; expression = evaluate_expression ~runtime ~body ~args }) in
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

(* A listed tab, or the active page when no tab is named. *)
let page_or_active ~tabs ~call tab_id =
  match tab_id with
  | Some id -> Result.map (fun page_id -> id, page_id) (page_of ~tabs id)
  | None ->
    let* active = Result.bind (send call Wire.Context_active_page) active_of in
    (match active with
     | Some page_id -> Ok (Tabs.id_of_page tabs page_id, page_id)
     | None -> Error (Browser_lane.Rejected_before_effect "no active tab; name a tabId"))
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
  let* _, page_id = page_or_active ~tabs ~call tab_id in
  let* _ = send call (Wire.Page_goto { page_id; url }) in
  let* summary =
    Result.bind (evaluate ~runtime:No_runtime ~send:(send_after_effect call) page_id summary_body) summary_of
  in
  Ok (`Assoc [ "url", `String summary.url; "title", `String summary.title ])
;;

(* Creation and navigation are separate native calls: after creation, every
   failure retains the known tab receipt and can never become a create retry. *)
let created_tab_failure tab_id answer =
  let detail = match answer with
    | Browser_lane.Refused detail | Browser_lane.Rejected_before_effect detail -> detail
    | Browser_lane.Lane_absent -> "Stagehand is unavailable"
    | Browser_lane.Timed_out -> "Stagehand did not answer"
    | Browser_lane.Answered _ -> "invalid created-tab observation" in
  Browser_lane.Answered (`Assoc ["ok",`Bool false;"effectPhase",`String "partial";
    "error",`String (Printf.sprintf
      "A new tab was created as tabId %d on lane stagehand, but navigation or observation failed: %s. List this same owned browser's tabs and inspect the created tab before deciding what to do next; do not open another tab to retry."
      tab_id detail);
    "data",`Assoc ["lane",`String "stagehand";"clientId",`Null;
      "tabId",`Int tab_id;"action",`String "open_tab";"created",`Bool true]])

let open_tab ~tabs ~call url =
  let* () = absolute_http url in
  let* created = send call Wire.Context_new_page in
  let* page_id = page_id_of ~method_:"context.new_page" created in
  let* () = if page_id = "" then Error (malformed "context.new_page" "a nonempty page_id") else Ok () in
  let tab_id = Tabs.id_of_page tabs page_id in
  Result.map_error (created_tab_failure tab_id) (
    let* _ = send_after_effect call (Wire.Page_goto {page_id;url}) in
    let* summary = Result.bind
      (evaluate ~runtime:No_runtime ~send:(send_after_effect call) page_id summary_body) summary_of in
    let* () = match absolute_http summary.url with
      | Ok () -> Ok ()
      | Error _ -> Error (Browser_lane.Refused "created tab did not reach an HTTP(S) page after navigation") in
    Ok (`Assoc ["tabId",`Int tab_id;"action",`String "open_tab";"created",`Bool true;
      "url",`String summary.url;"title",`String summary.title]))
;;

let navigate_tab ~tabs ~call ~tab_id ~name request =
  let* page_id = page_of ~tabs tab_id in
  let* _ = send call (request page_id) in
  let* summary = Result.bind
    (evaluate ~runtime:No_runtime ~send:(send_after_effect call) page_id summary_body) summary_of in
  Ok (`Assoc ["tabId",`Int tab_id;"action",`String name;
    "url",`String summary.url;"title",`String summary.title])
;;

let tab_action ~tabs ~call =
  let unsupported () = Error (Browser_lane.Rejected_before_effect
    "Stagehand BrowserAct serves only open_tab and top-level back, forward, reload, close_tab; use BrowserInteract for supported native input") in
  function
  | Browser_lane.Action.Open_tab url -> open_tab ~tabs ~call url
  | Browser_lane.Action.On_tab {tab_id;frame_path;interaction} ->
    match frame_path with
    | _::_ -> unsupported ()
    | [] -> match interaction with
      | Browser_lane.Action.Back ->
        navigate_tab ~tabs ~call ~tab_id ~name:"back" (fun page_id -> Wire.Page_go_back {page_id})
      | Browser_lane.Action.Forward ->
        navigate_tab ~tabs ~call ~tab_id ~name:"forward" (fun page_id -> Wire.Page_go_forward {page_id})
      | Browser_lane.Action.Reload ->
        navigate_tab ~tabs ~call ~tab_id ~name:"reload" (fun page_id -> Wire.Page_reload {page_id})
      | Browser_lane.Action.Close_tab ->
        let* page_id = page_of ~tabs tab_id in
        let* closed = send call (Wire.Page_close {page_id}) in
        let* () = match field "closed" closed with
          | Some (`Bool true) -> Ok ()
          | Some _ | None -> Error (malformed "page.close" "closed=true") in
        Tabs.forget_page tabs page_id;
        Ok (`Assoc ["tabId",`Int tab_id;"action",`String "close_tab";"closed",`Bool true])
      | Browser_lane.Action.Upload _ | Accept_dialog _ | Dismiss_dialog -> unsupported ()
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

(* The reads run the automation lane's page scripts, so an observation has
   the same shape on every lane. *)
let with_tab_id tab_id method_ = function
  | `Assoc fields -> Ok (`Assoc (("tabId", `Int tab_id) :: fields))
  | _ -> Error (malformed "page.evaluate" method_)
;;

let read_text ~tabs ~call ~tab_id ~max_chars =
  let* cap = Result.map_error (fun detail -> Browser_lane.Rejected_before_effect detail) (Browser_page_script.text_cap max_chars) in
  let* tab_id, page_id = page_or_active ~tabs ~call tab_id in
  let* text = evaluate ~runtime:No_runtime ~send:(send call) ~args:(`Int cap) page_id Browser_page_script.text in
  with_tab_id tab_id "a text observation" text
;;

let read_elements ~tabs ~call ~tab_id ~within =
  let* tab_id, page_id = page_or_active ~tabs ~call tab_id in
  let* elements =
    evaluate ~runtime:No_runtime ~send:(send call) ~args:(Browser_page_script.elements_args within)
      page_id Browser_page_script.elements
  in
  with_tab_id tab_id "an elements observation" elements
;;

let read_scene ~tabs ~call ~tab_id ~max_chars ~view ~scope =
  let* page_id = page_of ~tabs tab_id in
  let* args =
    match Browser_lane.scene_args ~tab_id ~max_chars ~view ~scope with
    | `Assoc fields -> Ok (`Assoc (("mode", `String "read") :: fields))
    | _ -> Error (Browser_lane.Rejected_before_effect "scene arguments must be an object")
  in
  let* scene = evaluate ~runtime:Scene_runtime ~send:(send call) ~args page_id Browser_scene_script.read_call in
  with_tab_id tab_id "a scene" scene
;;

(* A guard only reads the page, so however it fails, nothing took effect. *)
let send_guard call request =
  Result.map_error (fun failure -> Browser_lane.Rejected_before_effect (failure_message failure)) (call request)
;;

let guard_result result =
  Result.map_error
    (function
      | Browser_lane.Refused detail -> Browser_lane.Rejected_before_effect detail
      | (Browser_lane.Lane_absent | Browser_lane.Timed_out | Browser_lane.Answered _ | Browser_lane.Rejected_before_effect _) as answer -> answer)
    result
;;

(* The interaction script reports a refusal in its answer, and whether the
   action had started when it was refused. *)
let interaction_receipt ~tab_id = function
  | `Assoc fields ->
    (match List.assoc_opt "interactionFailure" fields with
     | Some (`Assoc failure) ->
       let message =
         match List.assoc_opt "message" failure with
         | Some (`String message) -> message
         | Some _ | None -> "the interaction was refused without a message"
       in
       (match List.assoc_opt "effectStarted" failure with
        | Some (`Bool false) -> Error (Browser_lane.Rejected_before_effect message)
        | Some _ | None -> Error (Browser_lane.Refused message))
     | Some _ -> Error (malformed "page.evaluate" "a typed interaction failure")
     | None ->
       let receipt = `Assoc fields in
       let* _ = string_field ~method_:"page.evaluate" "action" receipt in
       let* _ = string_field ~method_:"page.evaluate" "urlBefore" receipt in
       let* _ = string_field ~method_:"page.evaluate" "url" receipt in
       let* _ = string_field ~method_:"page.evaluate" "title" receipt in
       Ok (`Assoc (("tabId", `Int tab_id) :: fields)))
  | _ -> Error (malformed "page.evaluate" "an interaction receipt")
;;

let viewport_x (viewport : Browser_lane.Pointer.viewport) (point : Browser_lane.Pointer.point) = point.x *. viewport.width
let viewport_y (viewport : Browser_lane.Pointer.viewport) (point : Browser_lane.Pointer.point) = point.y *. viewport.height

(* A pointer action is native input, as on the automation lane: the guard
   checks the page is the one observed, the browser takes the input, and the
   receipt reads where the page is afterwards. *)
let pointer ?(guard=Browser_interaction.pointer_guard_script) ?(receipt=Browser_interaction.pointer_receipt_script) ~call ~tab_id ~page_id ~args ~name input =
  let* url_before =
    Result.bind
      (evaluate ~runtime:Scene_runtime ~send:(send_guard call) ~args page_id guard)
      (string_field ~method_:"page.evaluate" "url")
    |> guard_result
  in
  let* _ = send call input in
  let* after = evaluate ~runtime:No_runtime ~send:(send_after_effect call) page_id receipt in
  match after with
  | `Assoc fields ->
    let* _ = string_field ~method_:"page.evaluate" "url" after in
    let* _ = string_field ~method_:"page.evaluate" "title" after in
    Ok (`Assoc (("tabId", `Int tab_id) :: ("urlBefore", `String url_before) :: ("action", `String name) :: fields))
  | _ -> Error (malformed "page.evaluate" "a pointer receipt")
;;

let interact ~tabs ~call ~tab_id ~expected_url action =
  let* page_id = page_of ~tabs tab_id in
  let name = Browser_lane.interaction_verb action in
  let args = Browser_lane.interaction_args ~tab_id ~frame_path:[] ~expected_url action in
  let* action, expected_url = match (action : Browser_lane.interaction) with
    | Browser_lane.Drag_to {duration_ms;_} when duration_ms <> 0 ->
      Error (Browser_lane.Rejected_before_effect "drag movement timing requires automation or a live BiDi connection")
    | Browser_lane.Double_click _ | Browser_lane.Hover _ | Browser_lane.Drag_to _ | Browser_lane.Click _ | Browser_lane.Click_node _ ->
      let* resolved = evaluate ~runtime:Scene_runtime ~send:(send_guard call) ~args
          page_id Browser_interaction.pointer_target_script |> guard_result in
      let* action = Browser_interaction.resolve_pointer_action action resolved
        |> Result.map_error (fun detail -> Browser_lane.Rejected_before_effect detail) in
      let* action = match action with
        | Browser_lane.Drag {from;to_;viewport;via;duration_ms} ->
          let* arrival = match field "arrival" resolved with
            | None -> Ok None
            | Some value -> Browser_lane.Pointer.point_of_json value
              |> Result.map Option.some
              |> Result.map_error (fun detail -> Browser_lane.Rejected_before_effect detail) in
          let via = match arrival with
            | None -> via
            | Some arrival ->
              let path = match via with
                | [] -> [Browser_lane.Pointer.{x=(from.x +. to_.x) /. 2.;y=(from.y +. to_.y) /. 2.}]
                | _::_ -> via in
              path @ [arrival] in
          Ok (Browser_lane.Drag {from;to_;viewport;via;duration_ms})
        | Browser_lane.Double_click _ | Browser_lane.Set_zoom _ | Browser_lane.Set_viewport _ | Browser_lane.Double_click_at _ | Browser_lane.Type_text _ | Browser_lane.Press_key _
        | Browser_lane.Activate_tab | Browser_lane.Click _ | Browser_lane.Fill _ | Browser_lane.Select_option _
        | Browser_lane.Scroll _ | Browser_lane.Hover _ | Browser_lane.Drag_to _
        | Browser_lane.Hover_at _ | Browser_lane.Click_at _ | Browser_lane.Scroll_at _
        | Browser_lane.Tap_at _ | Browser_lane.Swipe _
        | Browser_lane.Follow_link _ | Browser_lane.Click_node _ | Browser_lane.Fill_node _ -> Ok action in
      let* url = string_field ~method_:"page.evaluate" "url" resolved |> guard_result in
      Ok (action, Some url)
    | Browser_lane.Set_zoom _ | Browser_lane.Set_viewport _ | Browser_lane.Double_click_at _ | Browser_lane.Type_text _ | Browser_lane.Press_key _
    | Browser_lane.Activate_tab | Browser_lane.Fill _ | Browser_lane.Select_option _
    | Browser_lane.Scroll _ | Browser_lane.Hover_at _ | Browser_lane.Click_at _
    | Browser_lane.Tap_at _ | Browser_lane.Swipe _
    | Browser_lane.Scroll_at _ | Browser_lane.Drag _ | Browser_lane.Follow_link _
    | Browser_lane.Fill_node _ -> Ok (action, expected_url) in
  let args = Browser_lane.interaction_args ~tab_id ~frame_path:[] ~expected_url action in
  match (action : Browser_lane.interaction) with
  | Browser_lane.Set_zoom _ -> Error (Browser_lane.Rejected_before_effect "set_zoom requires a connected WebExtension browser")
  | Browser_lane.Tap_at _ | Browser_lane.Swipe _ ->
    Error (Browser_lane.Rejected_before_effect "touch input requires automation or a live BiDi connection; Stagehand has no touch call")
  | Browser_lane.Set_viewport Browser_lane.Browser_default ->
    Error (Browser_lane.Rejected_before_effect
      "restoring the browser's own viewport size requires a live BiDi connection; Stagehand only sets a size")
  | Browser_lane.Set_viewport (Browser_lane.Fit {width;height}) ->
    pointer ~guard:Browser_interaction.url_guard_script ~receipt:Browser_interaction.viewport_receipt_script
      ~call ~tab_id ~page_id ~args ~name
      (Wire.Page_set_viewport_size {page_id;width;height})
  | Browser_lane.Activate_tab -> Error (Browser_lane.Rejected_before_effect "activate_tab requires live lane")
  | Browser_lane.Double_click _ | Browser_lane.Hover _ | Browser_lane.Drag_to _ | Browser_lane.Click _ | Browser_lane.Click_node _ ->
    Error (Browser_lane.Rejected_before_effect "unresolved semantic pointer target")
  | Browser_lane.Double_click_at {point;viewport} ->
    pointer ~call ~tab_id ~page_id ~args ~name
      (Wire.Page_double_click {page_id;x=viewport_x viewport point;y=viewport_y viewport point})
  | Browser_lane.Type_text {text;_} ->
    let* () = Browser_lane.Keyboard.validate_text text
      |> Result.map_error (fun detail -> Browser_lane.Rejected_before_effect detail) in
    pointer ~guard:Browser_interaction.keyboard_guard_script ~call ~tab_id ~page_id ~args ~name
      (Wire.Page_type {page_id;text})
  | Browser_lane.Press_key {key;_} ->
    let* () = match key.key with
      | Browser_lane.Keyboard.Character value when Uchar.to_int value > 0xffff ->
        Error (Browser_lane.Rejected_before_effect "Stagehand cannot press a supplementary Unicode scalar as a key; use type_text for Unicode text")
      | Browser_lane.Keyboard.Character _ | Browser_lane.Keyboard.Named _ -> Ok () in
    pointer ~guard:Browser_interaction.keyboard_guard_script ~call ~tab_id ~page_id ~args ~name
      (Wire.Page_key_press {page_id;key})
  | Browser_lane.Hover_at {point;viewport} ->
    pointer ~call ~tab_id ~page_id ~args ~name
      (Wire.Page_hover {page_id;x=viewport_x viewport point;y=viewport_y viewport point})
  | Browser_lane.Click_at { point; viewport; button } ->
    pointer ~call ~tab_id ~page_id ~args ~name
      (Wire.Page_click { page_id; x = viewport_x viewport point; y = viewport_y viewport point; button })
  | Browser_lane.Scroll_at { point; viewport; x; y } ->
    pointer ~call ~tab_id ~page_id ~args ~name
      (Wire.Page_scroll
         { page_id; x = viewport_x viewport point; y = viewport_y viewport point
         ; delta_x = float_of_int x; delta_y = float_of_int y })
  | Browser_lane.Drag { from; to_; viewport; via; duration_ms } ->
    if duration_ms <> 0 then
      Error (Browser_lane.Rejected_before_effect "drag movement timing requires automation or a live BiDi connection")
    else
    let from_x = viewport_x viewport from and from_y = viewport_y viewport from in
    let to_x = viewport_x viewport to_ and to_y = viewport_y viewport to_ in
    let route = match via with
      | [] -> [Wire.{x=(from_x +. to_x) /. 2.;y=(from_y +. to_y) /. 2.}]
      | _::_ -> List.map (fun point -> Wire.{x=viewport_x viewport point;y=viewport_y viewport point}) via in
    pointer ~call ~tab_id ~page_id ~args ~name
      (Wire.Page_drag_and_drop
         {page_id;from_x;from_y;to_x;to_y;route})
  | Browser_lane.Fill _ | Browser_lane.Select_option _ | Browser_lane.Scroll _ | Browser_lane.Follow_link _ | Browser_lane.Fill_node _ ->
    let* receipt = evaluate ~runtime:Scene_runtime ~send:(send call) ~args page_id Browser_interaction.script in
    interaction_receipt ~tab_id receipt
;;

let attributed_interact ~tabs ~call ~actor ~tab_id ~expected_url action =
  match actor with
  | None -> interact ~tabs ~call ~tab_id ~expected_url action
  | Some actor ->
    let* page_id = page_of ~tabs tab_id in
    let request_id = Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())) in
    let metadata = ["requestId",`String request_id;"actor",`String actor;
      "action",`String (Browser_lane.interaction_verb action)] in
    let observe body args =
      match evaluate ~runtime:No_runtime ~send:(send call) ~args page_id body with
      | Ok _ | Error _ -> ()
      | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
      | exception _ -> () in
    Eio.Switch.run (fun sw ->
      let phase = ref Browser_pointer_feedback.Unknown in
      (* Switch cleanup is cancellation-protected. Feedback only observes;
         a missing overlay never authorizes or replays the browser input. *)
      Eio.Switch.on_release sw (fun () -> observe Browser_pointer_feedback.finish_script
        (`Assoc (("phase",Browser_pointer_feedback.outcome_to_json !phase)::metadata)));
      observe Browser_pointer_feedback.begin_script (`Assoc metadata);
      let result = interact ~tabs ~call ~tab_id ~expected_url action in
      phase := (match result with
        | Ok _ -> Browser_pointer_feedback.Finished
        | Error (Browser_lane.Rejected_before_effect _) -> Browser_pointer_feedback.Refused
        | Error (Browser_lane.Refused _ | Browser_lane.Timed_out | Browser_lane.Lane_absent | Browser_lane.Answered _) ->
          Browser_pointer_feedback.Unknown);
      result)
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

let execute ~tabs ~call ?actor verb =
  let served =
    match verb with
    | Browser_lane.Tabs_list -> list_tabs ~tabs ~call
    | Browser_lane.Page_goto { url; tab_id } -> goto ~tabs ~call ~url ~tab_id
    | Browser_lane.Page_act action -> tab_action ~tabs ~call action
    | Browser_lane.Page_capture { tab_id } -> capture ~tabs ~call ~tab_id
    | Browser_lane.Page_read { tab_id; max_chars } -> read_text ~tabs ~call ~tab_id ~max_chars
    | Browser_lane.Page_elements { tab_id; within } -> read_elements ~tabs ~call ~tab_id ~within
    | Browser_lane.Page_scene { tab_id; max_chars; view; scope } -> read_scene ~tabs ~call ~tab_id ~max_chars ~view ~scope
    | Browser_lane.Page_interact { frame_path = _ :: _; _ } ->
      Error (Browser_lane.Rejected_before_effect "framePath is not supported on a Stagehand browser yet; the page input runs in the top document only")
    | Browser_lane.Page_interact { tab_id; frame_path = []; expected_url; action } -> attributed_interact ~tabs ~call ~actor ~tab_id ~expected_url action
    | Browser_lane.Page_instruct { tab_id; instruction } ->
      sentence ~tabs ~call ~tab_id ~outcome:act_outcome (fun page_id -> Wire.Act { page_id; instruction; timeout = Wire.sentence_timeout })
    | Browser_lane.Page_locate { tab_id; instruction } ->
      sentence ~tabs ~call ~tab_id ~outcome:reported_as_data (fun page_id -> Wire.Observe { page_id; instruction; timeout = Wire.sentence_timeout })
    | Browser_lane.Page_extract { tab_id; instruction; schema } ->
      sentence ~tabs ~call ~tab_id ~outcome:reported_as_data (fun page_id -> Wire.Extract { page_id; instruction; schema; timeout = Wire.sentence_timeout })
    | Browser_lane.Session_open _ | Browser_lane.Session_close | Browser_lane.Session_status
    | Browser_lane.Page_document _ | Browser_lane.Page_downloads _ | Browser_lane.Page_console _ | Browser_lane.Page_network _ | Browser_lane.Page_cookies _
    | Browser_lane.Page_context _ ->
      Error
        (Browser_lane.Rejected_before_effect
           ("the Stagehand page executor does not serve " ^ Browser_lane.verb_to_string verb))
  in
  match served with
  | Ok data -> Browser_lane.Answered (`Assoc [ "ok", `Bool true; "data", data ])
  | Error answer -> answer
;;

let cdp_failure_message = function
  | Browser_cdp.Command_rejected { code; message } -> Printf.sprintf "rejected (%d): %s" code message
  | Browser_cdp.Connection_lost reason -> "connection lost: " ^ reason
;;

let attach_error_message = function
  | Browser_stagehand_session.Extension_path detail -> "the extension directory has no real path: " ^ detail
  | Browser_stagehand_session.Load_rejected failure -> "Chrome did not load the extension: " ^ cdp_failure_message failure
  | Browser_stagehand_session.Extension_id_mismatch { expected; loaded } ->
    Printf.sprintf "Chrome loaded the extension as %s, not %s, so its origin is not the allowed one" loaded expected
  | Browser_stagehand_session.Service_worker_absent -> "the extension's service worker never appeared"
  | Browser_stagehand_session.Runtime_not_ready -> "the Stagehand runtime was not ready in its service worker"
  | Browser_stagehand_session.Malformed_reply { method_; detail } -> Printf.sprintf "%s answered without what attach needs: %s" method_ detail
  | Browser_stagehand_session.Runtime_marker detail -> "the Stagehand runtime marker is unreadable: " ^ detail
  | Browser_stagehand_session.Runtime_incompatible { found; supported } ->
    Printf.sprintf "the Stagehand runtime speaks protocol %s; masc speaks major %d" found supported
  | Browser_stagehand_session.Init_unanswered seconds -> Printf.sprintf "stagehand.init did not answer within %.0f s" seconds
  | Browser_stagehand_session.Init_failed failure -> "stagehand.init failed: " ^ failure_message failure
  | Browser_stagehand_session.Cdp failure -> "a CDP command failed: " ^ cdp_failure_message failure
  | Browser_stagehand_session.Already_attached -> "the session was already attached"
;;
