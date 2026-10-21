(* The Stagehand lane end to end in a real Chromium (RFC-browser-lane-stagehand
   §6.2): the installed native browser Add-on, public tool contracts and shared
   Exact Output runner, with a loopback scripted provider, since CI holds no provider
   key. scripts/probe-stagehand.py serves the fixture page and runs this.

   The scripted model answers from what reached it: the page text for
   extract, the element id Stagehand listed for the button for observe and
   act. So a passing run shows the page reached the model and the model's
   choice reached the page, not only that the wire carries messages. *)

open Masc
module R = Lane_addon_runtime
module F = Exact_output_fixture
module Tools = Browser_addon_tools

let failures = ref []
let steps = ref []
let ( let* ) = Result.bind

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

let properties schema =
  match Yojson.Safe.Util.member "properties" schema with
  | `Assoc fields -> List.map fst fields
  | _ -> []
;;

let scripted_value ~schema ~text =
  let props = properties schema in
  if List.mem "heading" props && List.mem "plan_price" props then
    if contains ~sub:"Order form" text && contains ~sub:"42 USD" text then
      Ok (`Assoc ["heading",`String "Order form";"plan_price",`String "42 USD"])
    else Error "page text did not reach the shared model runner"
  else if List.mem "completed" props then Ok (`Assoc ["progress",`String "read";"completed",`Bool true])
  else if List.mem "action" props || List.mem "elements" props then
    (match List.find_map (fun line ->
       if contains ~sub:"button: Submit order" line then element_id line else None)
       (String.split_on_char '\n' text) with
     | None -> Error "no Submit order button in the page the model was shown"
     | Some id ->
       let button=`Assoc ["elementId",`String id;"description",`String "Submit order button";
         "method",`String "click";"arguments",`List []] in
       if List.mem "action" props then Ok (`Assoc ["action",button;"twoStep",`Bool false])
       else Ok (`Assoc ["elements",`List [button]]))
  else Error ("no scripted answer for " ^ String.concat "," props)
;;

let scripted_input body =
  try
    let request=Yojson.Safe.from_string body in
    let open Yojson.Safe.Util in
    if (request |> member "response_format" |> member "type") <> `String "json_object" then
      Error "the shared Exact Output fixture requires its declared JSON mode"
    else
      let messages=request |> member "messages" |> to_list in
      match List.rev messages with
      | [] -> Error "the shared Exact Output request has no schema instruction"
      | instruction::reversed ->
        let text=instruction |> member "content" |> to_string in
        (* This fixture decodes only the public formatter's complete canonical
           instruction. A JSON fragment in page text cannot select a schema.
           JSON mode carries syntax on the wire and schema in this final turn. *)
        let* start=String.index_opt text '{'
          |> Option.to_result ~none:"the schema instruction has no object" in
        let schema=Yojson.Safe.from_string (String.sub text start (String.length text-start)) in
        let requirement=Agent_core.Exact_output.make_output_requirement ~schema
          ~minimum_guarantee:Agent_core.Exact_output.Json_syntax in
        if (instruction |> member "role") <> `String "user"
           || text<>Agent_core.Exact_output.schema_instruction_text requirement then
          Error "the final message is not the shared Exact Output schema instruction"
        else
          let text=List.rev reversed
            |> List.map (fun message -> message |> member "content" |> to_string)
            |> String.concat "\n" in
          Ok (schema,text)
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
    Error "invalid fixture model request"
;;

let scripted_http body =
  match Result.bind (scripted_input body) (fun (schema,text) -> scripted_value ~schema ~text) with
    | Ok value -> `OK,F.openai_response value
    | Error message -> `Bad_request,Yojson.Safe.to_string (`Assoc ["error",`Assoc ["message",`String message]])
;;

let tool name result =
  if Tool_result.is_success result then Ok (Tool_result.data result)
  else Error (name ^ ": " ^ Tool_result.message result)
;;

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

type profile_lifetime = Private | Persistent

let () =
  let chrome = argument "--chrome"
  and extension = argument "--extension"
  and fixture_url = argument "--fixture-url"
  and out = argument "--out" in
  let profile_lifetime=match argument "--profile-mode" with
    | "private" -> Private | "persistent" -> Persistent
    | _ -> failwith "profile mode must be private or persistent" in
  let manifest=Unix.realpath (argument "--manifest") in
  let expected_skill_revision=In_channel.with_open_bin
      (Filename.concat (Filename.dirname manifest) "skills/browser/SKILL.md") In_channel.input_all
    |> Skill_reference.content_revision_of_source_text in
  let base_path=Filename.temp_dir "masc-browser-addon-probe-" "" |> Unix.realpath in
  let config_root=Filename.concat base_path ".masc/config" in
  Fs_compat.mkdir_p config_root;
  Unix.putenv Env_config_core.base_path_env_key base_path;
  Unix.putenv Env_config_core.config_dir_env_key config_root;
  let bin=Filename.concat base_path "bin" in Unix.mkdir bin 0o700;
  List.iter (fun (flag,name) -> Unix.symlink (Unix.realpath (argument flag)) (Filename.concat bin name))
    ["--launcher","masc-native-addon-launcher";"--guardian","masc-browser-process-owner";
     "--worker","masc-browser-addon-worker"];
  Unix.putenv "PATH" (bin ^ ":" ^ Option.value ~default:"" (Sys.getenv_opt "PATH"));
  Unix.mkdir (Filename.concat base_path "fixture-skills") 0o700;
  let runtime_path=Filename.concat config_root "runtime.toml" in
  let profile_path=match profile_lifetime with
    | Private -> None
    | Persistent ->
      let path=Filename.concat base_path "chrome-profile" in
      Unix.mkdir path 0o700;Some path in
  Out_channel.with_open_bin runtime_path (fun channel ->
    output_string channel (F.official_client_runtime_fixture ^ Printf.sprintf
      "\n[skills]\n[[skills.sources]]\nid=\"probe-local\"\nanchor=\"base-path\"\npath=\"fixture-skills\"\naccess=\"read-only\"\n[browser.live]\nenabled=false\n[browser.automation]\nenabled=false\n[browser.stagehand]\nenabled=true\nchrome=%S\nextension=%S\n%s"
      chrome extension (Option.fold ~none:"" ~some:(Printf.sprintf "profile=%S\n") profile_path)));
  (match Runtime.init_default ~config_path:runtime_path with Ok () -> () | Error detail -> failwith detail);
  Mirage_crypto_rng_unix.use_default ();
  let failed = Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env and net=Eio.Stdenv.net env in
  Time_compat.set_clock clock;Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~sw ~clock ~net ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
  let config=Workspace.default_config base_path in
  let access=Lane_addon_sources.Operator_configuration in
  let principal=Lane_addon_call_context.Host_actor "stagehand-probe" in
  let held,resolve_held=Eio.Promise.create () and released,release=Eio.Promise.create () in
  let hold=ref false in
  let provider_responses=ref [] in
  let provider=F.start_server ~sw ~net ~clock (F.Reply_with (fun index body ->
    if !hold then (ignore (Eio.Promise.try_resolve resolve_held ());Eio.Promise.await released);
    let status,response=scripted_http body in
    provider_responses:=`Assoc ["request_index",`Int index;
      "status",`Int (Cohttp.Code.code_of_status status);"body",`String response]::!provider_responses;
    status,response)) in
  ignore (F.publish_registry ~lane_id:"browser/stagehand" ~slot_ids:["probe"]
    (F.resolver_snapshot ~source:base_path [{F.id="probe";base_url=provider.base_url}]) : Runtime_exact_output_registry.t);
  R.register_exact_runner ~validate_request:(Server_lane_addon_exact.validate_request ~base_path)
    (Server_lane_addon_exact.runner ~base_path);
  let directory=R.configuration_directory config in Fs_compat.mkdir_p directory;
  let declaration=Filename.concat directory "browser.toml" in
  let require = function Ok value -> value | Error detail -> failwith detail in
  let inventory ()=R.inventory ~config in
  let rec await f=match f () with Some value -> value | None -> Eio.Time.sleep clock 0.01;await f in
  let observation=Runtime.load_config_observation ~runtime_config_path:runtime_path () |> require in
  let publication=Server_skill_snapshot_runtime.refresh_from_observation ~base_path observation
    |> Result.map_error Server_skill_snapshot_runtime.error_to_string |> require in
  (match publication with
   | Skill_catalog_snapshot_service.Published _|Unchanged _ -> ()
   | Workspace_retired -> failwith "fixture Skill workspace was retired");
  R.register_skill_export_handler Server_skill_snapshot_runtime.publish_lane_skills;
  R.start_configuration_service ~config ~sw ~clock;
  let attach () =
    Out_channel.with_open_bin declaration (fun channel -> output_string channel (Printf.sprintf
      "id=\"browser\"\nrun_id=\"stagehand-probe\"\nmanifest_path=%S\nexact_outputs=[\"stagehand\"]\ntool_hooks=[\"validate_input\",\"validate_output\"]\n[binding]\nsources=[]\n" manifest));
    let report=R.reconcile_configuration ~config ~directory |> require in
    let open Yojson.Safe.Util in
    let declared=report |> member "declarations" |> to_list
      |> List.filter (fun item -> member "id" item=`String "browser") in
    let refused=report |> member "issues" |> to_list in
    if member "complete" report<>`Bool true || List.length declared<>1 || refused<>[] then
      failwith ("browser declaration was not applied: " ^ Yojson.Safe.to_string report);
    await (fun () ->
      let snapshot=inventory () in
      List.iter (fun (item:R.inventory_instance) -> match item.phase with
        | Lane_addon_types.Failed detail -> failwith detail
        | Attached|Observing|Detaching|Detached -> ()) snapshot.instances;
      match R.browser_services ~config ~access with
      | [service] -> Some service
      | [] -> None | _::_::_ -> failwith "ambiguous fixture browser Add-ons") in
  let first=attach () in
  record "the real catalog publishes the browser package Skill"
    (let* catalog=Server_skill_snapshot_runtime.lookup ~base_path
       |> Result.map_error Server_skill_snapshot_runtime.error_to_string in
     match catalog with
     | Server_skill_snapshot_runtime.Ready {snapshot;_} ->
       (match Skill_catalog_snapshot.find_effective_by_name snapshot "browser" with
        | Some entry when
            Skill_reference.identity_source_id_to_string entry.identity=R.skill_source_id (R.Declaration "browser")
            && Skill_reference.identity_package_id_to_string entry.identity="browser"
            && entry.identity.name="browser"
            && entry.directory="browser"
            && Skill_reference.equal_content_revision entry.content_revision expected_skill_revision -> Ok `Null
        | Some entry -> Error ("catalog Skill has unexpected identity or content: " ^
            Yojson.Safe.to_string (Skill_reference.to_yojson (Skill_catalog_snapshot.entry_reference entry)))
        | None -> Error "browser package Skill is absent")
     | Not_registered|Uninitialized -> Error "workspace Skill catalog is unavailable");
  let host=Browser_addon_host.connect ~config ~access ~principal ~reserved:[]
    |> Result.map_error (function R.Unavailable s|Outcome_unknown s -> s
      | Host_refusal _ -> "host refused the fixture principal") |> require in
  let detach id =
    let* _=R.dispatch ~caller:"stagehand-probe" ~access ~config ~operation:R.Detach
      (`Assoc ["instance_id",`String id]) |> Result.map_error R.error_to_string in
    await (fun () -> let snapshot=inventory () in
      match List.find_opt (fun (item:R.inventory_instance) -> item.instance_id=id) snapshot.instances with
      | Some {phase=Lane_addon_types.Detached;_} -> Some (Ok `Null)
      | Some {phase=Failed detail;_} -> Some (Error detail)
      | Some {phase=Attached|Observing|Detaching;_} | None -> None) in
  let args fields = `Assoc fields in
  let lane = "lane", `String "stagehand" in
  let handle tool_name tool_kind fields=tool tool_name (Tools.handle ~config ~access ~principal ~reserved:[]
    ~keeper_name:None ~tool:tool_kind ~tool_name ~start_time:(Tool_timing.start ()) (args fields)) in
  let tabs ()=handle "BrowserTabs" Browser_capabilities.Tabs [lane] in
  let session action=handle "BrowserSession" Browser_capabilities.Session ["action",`String action;lane] in
  let instruct fields=handle "BrowserInstruct" Browser_capabilities.Instruct (lane::fields) in
  let feedback_before=ref None in
  let observation name =
    let path=Filename.concat out (name ^ ".json") in
    if Sys.file_exists path then
      (try Some (Yojson.Safe.from_file path) with Yojson.Json_error _ -> None)
    else None in
  let interact fields =
    feedback_before:=Option.bind (observation "pointer-feedback") (string_at ["requestId"]);
    handle "BrowserInteract" Browser_capabilities.Interact (lane::fields) in
  let capture tab_id =
    Browser_addon_host.issue host ~preference:(Browser_selection.Exact Browser_lane.Stagehand_route)
      (Browser_lane.Page_capture {tab_id}) |> Result.map (fun receipt -> receipt.Browser_addon_host.data)
      |> Result.map_error Tool_result.message in
  let goto_fixture ()=handle "BrowserGoto" Browser_capabilities.Goto ["url",`String fixture_url;lane] in
  let session_state signed_in =
    let url=fixture_url ^ "session" in
    let* _=handle "BrowserGoto" Browser_capabilities.Goto ["url",`String url;lane] in
    let* listed=tabs () in
    let* _,observed=tab_for ~url listed in
    let expected=if signed_in then "MASC fixture signed in" else "MASC fixture signed out" in
    match string_at ["title"] observed with
    | Some title when title=expected -> Ok observed
    | Some title -> Error ("fixture cookie state has title " ^ title ^ ", expected " ^ expected)
    | None -> Error "fixture cookie state has no title" in
  let establish_session () =
    let* _=handle "BrowserGoto" Browser_capabilities.Goto
      ["url",`String (fixture_url ^ "session/login");lane] in
    session_state true in
  let retains_session=match profile_lifetime with Private -> false | Persistent -> true in
  let title_at tab_id expected =
    let* listed = tabs () in
    let* _, observed = tab_for ~url:fixture_url listed in
    match string_at [ "title" ] observed with
    | Some title when String.equal title expected -> Ok observed
    | Some title -> Error (Printf.sprintf "tab %d has title %s, expected %s" tab_id title expected)
    | None -> Error "the tab has no title"
  in
  (* The fixture publishes its own observed events through loopback HTTP.
     This never evaluates arbitrary JavaScript through a separate session. *)
  let await_fixture_scroll () = await (fun () -> match observation "scroll-observed" with
    | Some value when string_at ["url"] value=Some fixture_url -> Some (Ok ())
    | Some _ | None -> None) in
  let observe_actor_feedback () = await (fun () -> match observation "pointer-feedback" with
    | Some value when string_at ["requestId"] value<> !feedback_before
        && string_at ["actor"] value=Some (Lane_addon_call_context.actor_label principal)
        && string_at ["phase"] value=Some "finished" && string_at ["action"] value=Some "click" ->
      let flag name=Yojson.Safe.Util.member name value=`Bool true in
      Some (if List.for_all flag ["observedPointer";"inert";"hidden";"ignoresPointer"]
        then Ok value else Error ("owned native pointer feedback was not observed: " ^ Yojson.Safe.to_string value))
    | Some _ | None -> None) in
  record "open" (session "open");
  let pid =
    match session "status" with
    | Ok status -> Yojson.Safe.Util.(member "pid" status |> to_int_option)
    | Error _ -> None
  in
  record "status names the browser" (Option.to_result ~none:"no pid in status" pid);
  record "the isolated fixture installs and reads its HTTP-only session cookie" (establish_session ());
  record "goto" (goto_fixture ());
  let tab = Result.bind (tabs ()) (tab_for ~url:fixture_url) in
  record "the fixture is a tab" tab;
  (match tab with
   | Error _ -> ()
   | Ok (tab_id, _) ->
     let read mode =
       tool "BrowserRead"
         (Tools.handle ~config ~access ~principal ~reserved:[] ~keeper_name:None
            ~tool:Browser_capabilities.Read ~tool_name:"masc_browser_read" ~start_time:(Tool_timing.start ())
            (args [ lane; "tabId", `Int tab_id; "mode", `String mode ]))
     in
     let observed_viewport () =
       let* capture =
         capture tab_id
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
     record "trusted hover reveals a menu, native click opens it, and observed selection takes effect"
       (let* _ = interact ["action",`String "hover";"tabId",`Int tab_id;
          "expectedUrl",`String fixture_url;"selector",`String "#hover-message"] in
        let* revealed = read "elements" in
        if not (contains ~sub:"Open trusted menu" (Yojson.Safe.to_string revealed))
        then Error "hover menu control was absent from the fresh inventory"
        else
          let* _ = interact ["action",`String "click";"tabId",`Int tab_id;
            "selector",`String "#menu-trigger"] in
          let* opened = read "scene" in
          let open Yojson.Safe.Util in
          let selected = match member "nodes" opened with
            | `List nodes -> List.find_opt (fun node -> member "text" node = `String "Select trusted item") nodes
            | _ -> None in
          match selected with
          | None -> Error "trusted pointerdown menu did not expose its selection"
          | Some node ->
            let* _ = interact ["action",`String "click";"tabId",`Int tab_id;
              "documentId",member "documentId" opened;"nodeId",member "nodeId" node] in
            let* _ = title_at tab_id "trusted-menu-picked" in
            let* selected = read "text" in
            if contains ~sub:"Trusted menu selected" (Yojson.Safe.to_string selected) then Ok selected
            else Error "trusted menu selection was not observed");
     record "owned agent badge and actual pointer are visible without taking input" (observe_actor_feedback ());
     record "reset after trusted hover menu" (goto_fixture ());
     (* A scope from another document makes the scene script throw
        scene_document_changed. Stagehand words an uncaught throw as
        "Uncaught", so this shows the page script's own reason survives. *)
     record "a page script's throw reaches the caller by its reason"
       (match
          tool "BrowserRead"
            (Tools.handle ~config ~access ~principal ~reserved:[] ~keeper_name:None ~tool:Browser_capabilities.Read
            ~tool_name:"masc_browser_read" ~start_time:(Tool_timing.start ())
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
        let* () = await_fixture_scroll () in
        let* _ = title_at tab_id "scrolled" in
        let* data = read "text" in
        match string_at [ "text" ] data with
        | Some text when contains ~sub:"Scroll confirmed" text -> Ok data
        | _ -> Error ("the scroll was absent from BrowserRead: " ^ Yojson.Safe.to_string data));
     record "reset after BrowserInteract scroll_at" (goto_fixture ());
     record "BrowserInteract drag sends native Stagehand pointer input"
       (let* viewport, geometry = observed_viewport () in
        (* Raw pointer input is proved independently of HTML5 drag-and-drop.
           This source captures a trusted press and requires movement followed
           by a trusted release inside the distinct observed destination. *)
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
          let* _ = title_at tab_id "pointer-dragged" in
          let* data = read "text" in
          match string_at [ "text" ] data with
          | Some text when contains ~sub:"Pointer drag completed" text -> Ok data
          | _ -> Error ("the drag was absent from BrowserRead: " ^ Yojson.Safe.to_string data));
     record "reset after BrowserInteract drag" (goto_fixture ());
     record "semantic drag_to accepts a trusted HTML5 drop"
       (let* _ = interact ["action",`String "drag_to";"tabId",`Int tab_id;
          "expectedUrl",`String fixture_url;
          "source",`Assoc ["selector",`String "#html5-source"];
          "destination",`Assoc ["selector",`String "#html5-target"]] in
        let* _ = title_at tab_id "html5-dragged" in
        let* data = read "text" in
        match string_at ["text"] data with
        | Some text when contains ~sub:"HTML5 drag completed" text -> Ok data
        | _ -> Error ("the HTML5 drop was absent from BrowserRead: " ^ Yojson.Safe.to_string data));
     record "reset after semantic HTML5 drag" (goto_fixture ());
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
       (match capture tab_id with
        | Error detail -> Error detail
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
  record "reopen on the original attached worker" (session "open");
  record "browser reopen follows the selected profile's cookie lifetime" (session_state retains_session);
  (* Both retirement boundaries must start with a positively observed cookie.
     In private mode, close/reopen has already discarded the first cookie;
     reusing that empty profile on fresh attach would otherwise go undetected. *)
  record "the reopened browser holds a session before worker retirement" (establish_session ());
  record "navigate after reopen" (goto_fixture ());
  let current_tab=Result.bind (tabs ()) (tab_for ~url:fixture_url) in
  (match current_tab with
   | Error detail -> record "in-flight detach preflight" (Error detail)
   | Ok (tab_id,_) ->
     hold:=true;
     let before=F.post_count provider in
     let pending=Eio.Fiber.fork_promise ~sw (fun () -> instruct ["action",`String "extract";
       "instruction",`String "the page heading and the plan price";"tabId",`Int tab_id;
       "schema",`String {|{"type":"object","properties":{"heading":{"type":"string"},"plan_price":{"type":"string"}},"required":["heading","plan_price"]}|}]) in
     Eio.Promise.await held;
     record "detach cancels an in-flight browser/model command" (detach first.instance_id);
     ignore (Eio.Promise.try_resolve release ());hold:=false;
     record "departed command never reports success" (match Eio.Promise.await_exn pending with
       | Error _ -> Ok `Null | Ok _ -> Error "detached command reported success");
     record "no replay of the held provider request" (if F.post_count provider=before+1 then Ok `Null
       else Error "unexpected provider request after detach"));
  record "stale original browser handle is refused"
    (match Browser_addon_host.issue host ~preference:(Browser_selection.Exact Browser_lane.Stagehand_route) Browser_lane.Tabs_list with
     | Error _ -> Ok `Null | Ok _ -> Error "detached handle reached a browser");
  let replacement=attach () in
  record "reattach owns a fresh incarnation" (if replacement.instance_id<>first.instance_id then Ok `Null
    else Error "reattach reused the retired instance");
  record "open after fresh attach" (session "open");
  record "fresh worker attach follows the selected profile's cookie lifetime" (session_state retains_session);
  record "navigate after fresh attach" (goto_fixture ());
  record "close replacement browser" (session "close");
  record "detach confirms replacement cleanup" (detach replacement.instance_id);
  let proof = `Assoc [
    "profile_mode",`String (match profile_lifetime with Private -> "private" | Persistent -> "persistent");
    "profile_path",(match profile_path with None -> `Null | Some path -> `String path);
    "steps",`List (List.rev_map (fun (name,ok) -> `Assoc ["step",`String name;"ok",`Bool ok]) !steps);
    "model_requests",`Int (F.post_count provider);"isolated_base_path",`String base_path;
    "provider_requests",`List (List.map (fun body -> `String body) (F.request_bodies provider));
    "provider_responses",`List (List.rev !provider_responses);
    "first_instance",`String first.instance_id;"replacement_instance",`String replacement.instance_id;
    "model_transport",`String "shared Exact Output runner through loopback HTTP"] in
  Out_channel.with_open_bin (Filename.concat out "stagehand-proof.json") (fun channel ->
    Out_channel.output_string channel (Yojson.Safe.pretty_to_string proof));
  List.rev !failures)
  in
  match failed with
  | [] -> ()
  | failed ->
    Printf.printf "%d step(s) failed: %s\n%!" (List.length failed) (String.concat ", " failed);
    exit 1
;;
