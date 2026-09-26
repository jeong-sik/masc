(* The Stagehand lane end to end in a real Chromium (RFC-browser-lane-stagehand
   §6.2): the server's own opener, backend, executor and Keeper tool handlers,
   with a scripted model in place of a provider, since CI holds no provider
   key. scripts/probe-stagehand.py serves the fixture page and runs this.

   The scripted model answers from what reached it: the page text for
   extract, the element id Stagehand listed for the button for observe and
   act. So a passing run shows the page reached the model and the model's
   choice reached the page, not only that the wire carries messages. *)

module Model = Masc.Browser_stagehand_model
module Wire = Masc.Browser_stagehand_wire
module Session = Masc.Browser_stagehand_session
module Backend = Masc.Browser_stagehand_backend
module Tools = Masc.Tool_misc_browser_lane

let failures = ref []
let steps = ref []

let record name outcome =
  steps := (name, Result.is_ok outcome) :: !steps;
  match outcome with
  | Ok _ -> Printf.printf "ok   %s\n%!" name
  | Error detail ->
    failures := name :: !failures;
    Printf.printf "FAIL %s: %s\n%!" name detail
;;

let argument name =
  let rec find = function
    | flag :: value :: _ when String.equal flag name -> value
    | _ :: rest -> find rest
    | [] -> failwith ("missing " ^ name)
  in
  find (Array.to_list Sys.argv)
;;

let contains ~sub text =
  let n = String.length sub and m = String.length text in
  let rec at i = i + n <= m && (String.equal (String.sub text i n) sub || at (i + 1)) in
  at 0
;;

(* "[0-18] button: Submit order" -> "0-18" *)
let element_id line =
  match String.index_opt line '[', String.index_opt line ']' with
  | Some open_, Some close when close > open_ + 1 ->
    let id = String.sub line (open_ + 1) (close - open_ - 1) in
    if String.for_all (function '0' .. '9' | '-' -> true | _ -> false) id then Some id else None
  | Some _, (Some _ | None) | None, (Some _ | None) -> None
;;

let prompt_text (request : Model.request) =
  request.messages
  |> List.concat_map (fun (message : Model.message) ->
    List.filter_map (function Model.Text text -> Some text | Model.Unserved _ -> None) message.content)
  |> String.concat "\n"
;;

let properties schema =
  match Yojson.Safe.Util.member "properties" schema with
  | `Assoc fields -> List.map fst fields
  | _ -> []
;;

let answer value =
  Ok
    (`Assoc
      [ "role", `String "assistant"
      ; "content", `Assoc [ "type", `String "text"; "text", `String (Yojson.Safe.to_string value) ]
      ; "output_format", `String "json_schema"
      ; "structured_content", value
      ])
;;

let refuse message = Error { Wire.code = Wire.host_refused; message }
let model_requests = ref 0

let scripted_model params =
  incr model_requests;
  match Model.parse_params params with
  | Error detail -> refuse ("probe model: " ^ detail)
  | Ok request ->
    let text = prompt_text request in
    (match request.generation with
     | Model.Structured { schema; _ } ->
       let props = properties schema in
       if List.mem "heading" props && List.mem "plan_price" props then
         if contains ~sub:"Order form" text && contains ~sub:"42 USD" text then
           answer (`Assoc [ "heading", `String "Order form"; "plan_price", `String "42 USD" ])
         else refuse "probe model: the page text did not reach the model"
       else if List.mem "completed" props then answer (`Assoc [ "progress", `String "read"; "completed", `Bool true ])
       else if List.mem "action" props || List.mem "elements" props then (
         match
           List.find_map
             (fun line -> if contains ~sub:"button: Submit order" line then element_id line else None)
             (String.split_on_char '\n' text)
         with
         | Some id ->
           let button =
             `Assoc
               [ "elementId", `String id
               ; "description", `String "Submit order button"
               ; "method", `String "click"
               ; "arguments", `List []
               ]
           in
           (* act asks for one action; observe for the elements that match. *)
           if List.mem "action" props then answer (`Assoc [ "action", button; "twoStep", `Bool false ])
           else answer (`Assoc [ "elements", `List [ button ] ])
         | None -> refuse "probe model: no Submit order button in the page the model was shown")
       else refuse ("probe model: no scripted answer for " ^ String.concat "," props)
     | Model.Text_generation | Model.Tool_generation _ -> refuse "probe model: only structured requests are scripted")
;;

let tool name result =
  if Tool_result.is_success result then Ok (Tool_result.data result)
  else Error (name ^ ": " ^ Tool_result.message result)
;;

let ( let* ) = Result.bind
let string_at keys json =
  List.fold_left (fun json key -> Yojson.Safe.Util.member key json) json keys
  |> Yojson.Safe.Util.to_string_option

let tab_for ~url tabs_data =
  match Yojson.Safe.Util.member "tabs" tabs_data with
  | `List tabs ->
    List.find_map
      (fun tab ->
        match string_at [ "url" ] tab, Yojson.Safe.Util.member "id" tab with
        | Some tab_url, `Int id when String.equal tab_url url -> Some (id, tab)
        | _ -> None)
      tabs
    |> Option.to_result ~none:("no tab at " ^ url)
  | _ -> Error "BrowserTabs answered without tabs"
;;

let alive pid =
  match Unix.kill pid 0 with
  | () -> true
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false
;;

let () =
  let chrome = argument "--chrome"
  and extension = argument "--extension"
  and fixture_url = argument "--fixture-url"
  and out = argument "--out" in
  let masc_root = Filename.concat out "masc-root" in
  let failed = Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Time_compat.set_clock clock;
  Eio.Switch.run
  @@ fun sw ->
  let config = { Masc.Browser_configuration.chrome; extension; profile = None } in
  let backend =
    Backend.create ~sw ~clock
      ~open_session:(fun ~sw ~headless ~log ->
        Server_browser_stagehand.open_ ~sw ~env ~masc_root ~config ~headless ~model:scripted_model ~log)
      ~call:(fun stagehand -> Session.call (Server_browser_stagehand.session stagehand))
      ~pid:Server_browser_stagehand.pid ~log:Server_browser_stagehand.log_event
  in
  Browser_lane.install_stagehand_executor (Some (Backend.execute backend));
  let args fields = `Assoc fields in
  let lane = "lane", `String "stagehand" in
  let tabs () = tool "BrowserTabs" (Tools.handle_tabs ~base_path:out ~tool_name:"masc_browser_tabs" ~start_time:0.0 (args [ lane ])) in
  let session action = tool "BrowserSession" (Tools.handle_session ~tool_name:"masc_browser_session" ~start_time:0.0 (args [ "action", `String action; lane ])) in
  let instruct fields = tool "BrowserInstruct" (Tools.handle_instruct ~tool_name:"masc_browser_instruct" ~start_time:0.0 (args fields)) in
  let interact fields =
    tool "BrowserInteract"
      (Tools.handle_interact ~base_path:out ~tool_name:"masc_browser_interact" ~start_time:0.0 (args (lane :: fields)))
  in
  let goto_fixture () =
    tool "BrowserGoto"
      (Tools.handle_goto ~tool_name:"masc_browser_goto" ~start_time:0.0 (args [ "url", `String fixture_url; lane ]))
  in
  let title_at tab_id expected =
    let* listed = tabs () in
    let* _, observed = tab_for ~url:fixture_url listed in
    match string_at [ "title" ] observed with
    | Some title when String.equal title expected -> Ok observed
    | Some title -> Error (Printf.sprintf "tab %d has title %s, expected %s" tab_id title expected)
    | None -> Error "the tab has no title"
  in
  record "open" (session "open");
  let pid =
    match session "status" with
    | Ok status -> Yojson.Safe.Util.(member "pid" status |> to_int_option)
    | Error _ -> None
  in
  record "status names the browser" (Option.to_result ~none:"no pid in status" pid);
  record "goto" (goto_fixture ());
  let tab = Result.bind (tabs ()) (tab_for ~url:fixture_url) in
  record "the fixture is a tab" tab;
  (match tab with
   | Error _ -> ()
   | Ok (tab_id, _) ->
     let read mode =
       tool "BrowserRead"
         (Tools.handle_read ~base_path:out ~tool_name:"masc_browser_read" ~start_time:0.0
            (args [ lane; "tabId", `Int tab_id; "mode", `String mode ]))
     in
     let observed_viewport () =
       let* capture =
         match Masc.Browser_surface.capture
                 { Masc.Browser_surface.route = Browser_lane.Stagehand_route
                 ; tab_id = Some tab_id }
         with
         | Ok data -> Ok data
         | Error failure -> Error (Masc.Browser_surface.failure_message failure)
       in
       let viewport = Yojson.Safe.Util.member "viewport" capture in
       let* geometry = Browser_lane.Pointer.viewport_of_json viewport in
       Ok (viewport, geometry)
     in
     record "BrowserRead text reads the page"
       (let* data = read "text" in
        match string_at [ "text" ] data, Yojson.Safe.Util.member "tabId" data with
        | Some text, `Int observed_id when observed_id = tab_id && contains ~sub:"Order form" text -> Ok data
        | _ -> Error ("the text read answered " ^ Yojson.Safe.to_string data));
     record "BrowserRead scene reads the page"
       (let* data = read "scene" in
        if contains ~sub:"Order form" (Yojson.Safe.to_string data) then Ok data
        else Error ("the scene read answered " ^ Yojson.Safe.to_string data));
     record "BrowserRead elements lists the page's controls"
       (let* data = read "elements" in
        if contains ~sub:"Submit order" (Yojson.Safe.to_string data) then Ok data
        else Error ("the elements read answered " ^ Yojson.Safe.to_string data));
     (* A scope from another document makes the scene script throw
        scene_document_changed. Stagehand words an uncaught throw as
        "Uncaught", so this shows the page script's own reason survives. *)
     record "a page script's throw reaches the caller by its reason"
       (match
          tool "BrowserRead"
            (Tools.handle_read ~base_path:out ~tool_name:"masc_browser_read" ~start_time:0.0
               (args
                  [ lane; "tabId", `Int tab_id; "mode", `String "scene"
                  ; "scope", `Assoc [ "documentId", `String "stale-document"; "nodeId", `String "n0" ]
                  ]))
        with
        | Error detail when contains ~sub:"scene_document_changed" detail -> Ok (`String detail)
        | Error detail -> Error ("the stale scope was refused without the script's reason: " ^ detail)
        | Ok data -> Error ("a scope from another document was read: " ^ Yojson.Safe.to_string data));
     record "extract reads the page through the model"
       (let* data =
          instruct
            [ "action", `String "extract"; "instruction", `String "the page heading and the plan price"
            ; "tabId", `Int tab_id
            ; "schema", `String {|{"type":"object","properties":{"heading":{"type":"string"},"plan_price":{"type":"string"}},"required":["heading","plan_price"]}|}
            ]
        in
        match string_at [ "data"; "heading" ] data, string_at [ "data"; "plan_price" ] data with
        | Some "Order form", Some "42 USD" -> Ok data
        | _ -> Error ("extract answered " ^ Yojson.Safe.to_string data));
     record "BrowserInteract fill runs the page script and input event"
       (let* _ = interact
          [ "action", `String "fill"; "selector", `String "#email"
          ; "text", `String "probe@example.test"; "tabId", `Int tab_id
          ]
        in
        title_at tab_id "filled");
     record "reset after BrowserInteract fill" (goto_fixture ());
     record "BrowserInteract click_at sends native Stagehand input"
       (let* viewport, geometry = observed_viewport () in
        (* The fixture's fixed button starts at 20vw/20vh and is 100×40 CSS
           pixels; this point is its centre in the observed viewport. *)
        let x = 0.2 +. (50. /. geometry.width)
        and y = 0.2 +. (20. /. geometry.height) in
        if x >= 1. || y >= 1. then Error "the viewport is too small for the fixture button"
        else
          let* _ = interact
            [ "action", `String "click_at"; "tabId", `Int tab_id
            ; "expectedUrl", `String fixture_url
            ; "viewport", viewport
            ; "point", `Assoc [ "x", `Float x; "y", `Float y ]
            ]
          in
          title_at tab_id "clicked");
     record "reset after BrowserInteract click_at" (goto_fixture ());
     record "BrowserInteract scroll_at sends native Stagehand wheel input"
       (let* viewport, _ = observed_viewport () in
        let* _ = interact
          [ "action", `String "scroll_at"; "tabId", `Int tab_id
          ; "expectedUrl", `String fixture_url; "viewport", viewport
          ; "point", `Assoc [ "x", `Float 0.5; "y", `Float 0.45 ]
          ; "x", `Int 0; "y", `Int 240
          ]
        in
        let* _ = title_at tab_id "scrolled" in
        let* data = read "text" in
        match string_at [ "text" ] data with
        | Some text when contains ~sub:"Scroll confirmed" text -> Ok data
        | _ -> Error ("the scroll was absent from BrowserRead: " ^ Yojson.Safe.to_string data));
     record "reset after BrowserInteract scroll_at" (goto_fixture ());
     record "BrowserInteract drag sends native Stagehand pointer input"
       (let* viewport, geometry = observed_viewport () in
        (* Source and target are fixed boxes with distinct centres. The page
           changes title only after a drop or a pointer release on target. *)
        let from_x = 0.2 +. (35. /. geometry.width)
        and from_y = 0.55 +. (20. /. geometry.height)
        and to_x = 0.45 +. (50. /. geometry.width)
        and to_y = 0.55 +. (30. /. geometry.height) in
        if from_x >= 1. || from_y >= 1. || to_x >= 1. || to_y >= 1.
        then Error "the viewport is too small for the drag fixture"
        else
          let* _ = interact
            [ "action", `String "drag"; "tabId", `Int tab_id
            ; "expectedUrl", `String fixture_url; "viewport", viewport
            ; "from", `Assoc [ "x", `Float from_x; "y", `Float from_y ]
            ; "to", `Assoc [ "x", `Float to_x; "y", `Float to_y ]
            ]
          in
          let* _ = title_at tab_id "dragged" in
          let* data = read "text" in
          match string_at [ "text" ] data with
          | Some text when contains ~sub:"Drag completed" text -> Ok data
          | _ -> Error ("the drag was absent from BrowserRead: " ^ Yojson.Safe.to_string data));
     record "reset after BrowserInteract drag" (goto_fixture ());
     record "observe locates the button the model chose"
       (let* data =
          instruct [ "action", `String "observe"; "instruction", `String "the Submit order button"; "tabId", `Int tab_id ]
        in
        if contains ~sub:"Submit order" (Yojson.Safe.to_string data) then Ok data
        else Error ("observe answered " ^ Yojson.Safe.to_string data));
     record "act clicks the button the model chose"
       (let* _ = instruct [ "action", `String "act"; "instruction", `String "click the Submit order button"; "tabId", `Int tab_id ] in
        let* tabs = tabs () in
        let* _, clicked = tab_for ~url:fixture_url tabs in
        match string_at [ "title" ] clicked with
        | Some "clicked" -> Ok clicked
        | Some title -> Error ("the page title after act is " ^ title)
        | None -> Error "the tab has no title after act");
     record "screenshot passes the surface"
       (match Masc.Browser_surface.capture { Masc.Browser_surface.route = Browser_lane.Stagehand_route; tab_id = Some tab_id } with
        | Error failure -> Error (Masc.Browser_surface.failure_message failure)
        | Ok data ->
          (match string_at [ "data" ] data with
           | Some image ->
             (match string_at [ "url" ] data, string_at [ "title" ] data with
              | Some url, Some "clicked" when String.equal url fixture_url ->
                let path = Filename.concat out "stagehand.png" in
                Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel (Base64.decode_exn image));
                Ok data
              | _ -> Error "capture did not name the clicked fixture")
           | None -> Error "capture without data")));
  record "close" (session "close");
  record "the browser stopped"
    (match pid with
     | Some pid when alive pid -> Error (Printf.sprintf "Chromium pid %d still runs" pid)
     | Some _ | None -> Ok `Null);
  let proof =
    `Assoc
      [ "steps", `List (List.rev_map (fun (name, ok) -> `Assoc [ "step", `String name; "ok", `Bool ok ]) !steps)
      ; "model_requests", `Int !model_requests
      ]
  in
  Out_channel.with_open_bin (Filename.concat out "stagehand-proof.json") (fun channel ->
    Out_channel.output_string channel (Yojson.Safe.pretty_to_string proof));
  Browser_lane.install_stagehand_executor None;
  List.rev !failures
  in
  match failed with
  | [] -> ()
  | failed ->
    Printf.printf "%d step(s) failed: %s\n%!" (List.length failed) (String.concat ", " failed);
    exit 1
;;
