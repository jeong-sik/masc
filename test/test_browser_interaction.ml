open Alcotest
module Interaction = Masc.Browser_interaction
let fields action = ["tabId", `Int 7; "action", `String action]
let parsed fields = match Interaction.parse (`Assoc fields) with
  | Ok request -> request | Error error -> fail error
let test_typed_actions () =
  let request = parsed (fields "fill" @ ["selector", `String "#query"; "text", `String "";
    "expectedUrl", `String "https://example.org/form"]) in
  check bool "empty text clears without introducing a submission action" true
    (request.action = Browser_lane.Fill {selector="#query"; text=""});
  check bool "page observation precondition retained" true
    (request.expected_url = Some "https://example.org/form");
  let scroll = parsed (fields "scroll" @ ["x", `Int (-10); "y", `Int 200]) in
  let verb = Browser_lane.Page_interact {tab_id=scroll.tab_id;
    expected_url=scroll.expected_url; action=scroll.action} in
  check bool "live interactions admitted" true (Browser_lane.verb_allowed_on_live verb);
  check bool "interactions are writes" false (Browser_lane.verb_is_read verb);
  check string "closed wire verb" "page.interact" (Browser_lane.verb_to_string verb)
let test_native_keyboard_parser () =
  let bound = ["expectedUrl",`String "https://example.org";"documentId",`String "d1"] in
  let cases = [fields "type_text" @ bound @ ["text",`String "한글🙂"];
    fields "press_key" @ bound @ ["key",`String "a";"modifiers",`List [`String "Meta"]];
    fields "double_click" @ ["expectedUrl",`String "https://example.org";"selector",`String "#editor"]] in
  List.iter (fun args -> let request=parsed args in
    let wire=Browser_lane.interaction_args ~tab_id:request.tab_id ~expected_url:request.expected_url request.action in
    check bool "native input round trips closed action" true ((parsed Yojson.Safe.Util.(to_assoc wire)).action=request.action)) cases;
  List.iter (fun args -> check bool "bad keyboard or unobserved focus rejected" true
    (Result.is_error (Interaction.parse (`Assoc args))))
    [fields "type_text" @ ["text",`String "hello"];fields "press_key" @ bound @ ["key",`String "ab"];
     fields "press_key" @ bound @ ["key",`String "a";"modifiers",`List [`String "Meta";`String "Meta"]];
     fields "fill" @ ["selector",`String "#input";"text",`String "ok";"key",`String "Enter"];
     fields "type_text" @ bound @ ["text",`String "ok";"nodeId",`String "n"]]
let test_browser_zoom_boundary () =
  let base=fields "set_zoom" @ ["clientId",`String "00000000-0000-4000-8000-000000000001";
    "expectedUrl",`String "https://example.org/form"] in
  let request=parsed (base @ ["factor",`Float 1.5]) in
  check bool "explicit factor is carried as browser zoom" true
    (request.action=Browser_lane.Set_zoom {factor=1.5});
  let wire=Browser_lane.interaction_args ~tab_id:request.tab_id ~expected_url:request.expected_url request.action in
  check bool "native host receives the requested scale" true
    (Yojson.Safe.Util.member "factor" wire=`Float 1.5);
  List.iter (fun factor -> check bool "invalid browser API factor never enters a request" true
    (Result.is_error (Interaction.parse (`Assoc (base @ ["factor",factor])))))
    [`Int 0;`Float 0.29;`Float 5.01;`Float nan;`Float infinity;`String "1.5"];
  check bool "zoom requires URL ownership" true
    (Result.is_error (Interaction.parse (`Assoc (fields "set_zoom" @ ["factor",`Int 1]))));
  check bool "zoom cannot borrow a selector or geometry" true
    (Result.is_error (Interaction.parse (`Assoc (base @ ["factor",`Int 1;"selector",`String "#other"]))))
let test_activate_tab () =
  let args = fields "activate_tab" @ ["lane",`String "live";"expectedUrl",`String "https://example.org"] in
  let request = parsed args in
  check bool "activation is a typed live action" true (request.action=Browser_lane.Activate_tab);
  let wire = Browser_lane.interaction_args ~tab_id:7 ~expected_url:request.expected_url request.action in
  check bool "wire pins tab URL and activation only" true
    (wire = `Assoc ["tabId",`Int 7;"action",`String "activate_tab";"expectedUrl",`String "https://example.org"]);
  List.iter (fun input -> check bool "activation rejects missing URL, unrelated inputs and automation" true
    (Result.is_error (Interaction.parse (`Assoc input))))
    [fields "activate_tab"; args @ ["selector",`String "button"];
     fields "activate_tab" @ ["lane",`String "automation";"expectedUrl",`String "https://example.org"]]
let test_scene_reference () =
  let target : Browser_lane.node_ref = {document_id="doc";node_id="node"} in
  let reference = ["documentId",`String "doc";"nodeId",`String "node"] in
  let request = parsed (fields "click" @ reference) in
  check bool "observed identity is a typed target" true (request.action = Browser_lane.Click_node target);
  let request = parsed (fields "fill" @ reference @ ["text",`String "별빛\n"]) in
  check bool "reference fill retains literal text" true
    (request.action = Browser_lane.Fill_node {target;text="별빛\n"});
  List.iter (fun input -> check bool "mixed or incomplete references rejected" true
    (Result.is_error (Interaction.parse (`Assoc input))))
    [fields "click" @ reference @ ["selector",`String "button"];
     fields "click" @ ["nodeId",`String "node"];
     fields "click" @ ["documentId",`String "doc"];
     fields "scroll" @ reference @ ["x",`Int 0;"y",`Int 10]]
let test_semantic_pointer_actions () =
  let observed = ["documentId",`String "doc";"nodeId",`String "source"] in
  let base = ["expectedUrl",`String "https://example.org"] in
  let hover = parsed (fields "hover" @ base @ observed) in
  check bool "hover pins observed node" true
    (hover.action = Browser_lane.Hover (Browser_lane.Scene_node {document_id="doc";node_id="source"}));
  let drag = parsed (fields "drag_to" @ base @ ["source",`Assoc observed;
    "destination",`Assoc ["selector",`String "#target"]]) in
  let wire = Browser_lane.interaction_args ~tab_id:7 ~expected_url:drag.expected_url drag.action in
  check bool "semantic drag round trips typed targets" true
    ((match Interaction.parse wire with Ok request -> request.action = drag.action | Error _ -> false));
  List.iter (fun input -> check bool "semantic target rejects mixed, missing and unrelated fields" true
    (Result.is_error (Interaction.parse (`Assoc input))))
    [fields "hover" @ observed;
     fields "hover" @ base @ observed @ ["selector",`String "#source"];
     fields "drag_to" @ base @ ["source",`Assoc observed];
     fields "drag_to" @ base @ ["source",`Assoc (observed @ ["selector",`String "#source"]);
       "destination",`Assoc ["selector",`String "#target"]];
     fields "click" @ ["selector",`String "button";"source",`Assoc observed]]
let test_drag_options () =
  let viewport = `Assoc ["documentId",`String "doc";"width",`Int 800;"height",`Int 600;
    "scrollX",`Int 0;"scrollY",`Int 0] in
  let point x y = `Assoc ["x",`Float x;"y",`Float y] in
  let via = `List [point 0.3 0.2;point 0.4 0.7] in
  let cases = [
    fields "drag" @ ["expectedUrl",`String "https://example.org";"viewport",viewport;
      "from",point 0.1 0.2;"to",point 0.8 0.7];
    fields "drag_to" @ ["expectedUrl",`String "https://example.org";
      "source",`Assoc ["selector",`String "#source"];"destination",`Assoc ["selector",`String "#drop"]]] in
  List.iter (fun base ->
    let request = parsed (base @ ["via",via;"durationMs",`Int 120]) in
    let wire = Browser_lane.interaction_args ~tab_id:request.tab_id
      ~expected_url:request.expected_url request.action in
    check bool "ordered path and timing survive round trip" true
      ((parsed (Yojson.Safe.Util.to_assoc wire)).action = request.action);
    List.iter (fun bad -> check bool "invalid drag geometry or timing is refused before dispatch" true
      (Result.is_error (Interaction.parse (`Assoc (base @ bad)))))
      [["durationMs",`Int (-1)];["durationMs",`Float 1.5];["via",`List [point 1.0 0.2]];
       ["via",`List [`Assoc ["x",`Float 0.2;"y",`Float 0.2;"x",`Float 0.3]]]]) cases;
  check bool "drag options are rejected on other actions" true
    (Result.is_error (Interaction.parse (`Assoc (fields "click" @ ["selector",`String "#button";"durationMs",`Int 1]))))

let test_invalid_actions () =
  List.iter (fun input -> check bool "invalid action rejected before dispatch" true
    (Result.is_error (Interaction.parse (`Assoc input))))
    [["action", `String "click"; "selector", `String "#query"];
     fields "click" @ ["selector", `String "  "];
     fields "fill" @ ["selector", `String "#query"];
     fields "fill" @ ["selector", `String "#query"; "text", `String "ok"; "x", `Int 2];
     fields "scroll" @ ["x", `Int 0; "y", `Float 2.];
     fields "scroll" @ ["x", `Int 0; "y", `Int 2; "selector", `String "#other"];
     fields "click" @ ["selector", `String "#query"; "script", `String "arbitrary()"];
     fields "click" @ ["selector", `String "#query"; "tabId", `Int 9];
     fields "evaluate"]
let test_source_context () =
  let module Source = Masc.Browser_source_context in
  let fields = ["schema",`String "masc.source.v1";"file",`String "dashboard/src/demo.ts";
    "line",`Int 12;"column",`Int 4;"kind",`String "template";"digest",`String (String.make 64 'a')] in
  (match Source.of_json (`Assoc fields) with
   | Source.Located location -> check int "original template line" 12 location.line
   | _ -> fail "valid development source context refused");
  check bool "external page is explicitly unmapped" true (Source.of_json `Null = Source.Unmapped);
  List.iter (fun path -> match Source.of_json (`Assoc (("file",`String path)::List.remove_assoc "file" fields)) with
    | Source.Invalid _ -> () | _ -> fail ("unsafe source path accepted: " ^ path))
    ["../secret";"/etc/passwd";"dashboard/../../secret";"C:\\secret";"dashboard//x";"dashboard/./x"];
  (match Source.of_json (`Assoc (("line",`Int 4)::fields)) with
   | Source.Invalid _ -> () | _ -> fail "duplicate source field accepted")
let test_pointer_actions () =
  let viewport = `Assoc ["documentId",`String "fixture";"width",`Int 800;
    "height",`Int 600;"scrollX",`Int 0;"scrollY",`Int 0] in
  let point = `Assoc ["x",`Float 0.25;"y",`Float 0.5] in
  let base = ["expectedUrl",`String "https://example.org";"viewport",viewport] in
  List.iter (fun (name,geometry) ->
    let input = fields name @ base @ geometry in
    let request = parsed input in
    let wire = Browser_lane.interaction_args ~tab_id:request.tab_id
      ~expected_url:request.expected_url request.action in
    ignore (match Interaction.parse wire with Ok _ -> () | Error e -> fail e);
    check bool "pointer action requires its observed URL" true
      (Result.is_error (Interaction.parse (`Assoc (List.remove_assoc "expectedUrl" input)))))
    ["hover_at",["point",point];"click_at",["point",point];"drag",["from",point;"to",point];
     "scroll_at",["point",point;"x",`Int 0;"y",`Int 120]];
  List.iter (fun bad ->
    check bool "invalid screenshot coordinates rejected before dispatch" true
      (Result.is_error (Interaction.parse (`Assoc
        (fields "click_at" @ base @ ["point",bad])))))
    [`Assoc ["x",`Float 1.;"y",`Float 0.];
     `Assoc ["x",`Float (-0.1);"y",`Float 0.];
     `Assoc ["x",`Float nan;"y",`Float 0.];
     `Assoc ["x",`Int 0;"y",`Int 0;"x",`Int 0]]
let test_click_button () =
  let viewport = `Assoc ["documentId",`String "fixture";"width",`Int 800;
    "height",`Int 600;"scrollX",`Int 0;"scrollY",`Int 0] in
  let point = `Assoc ["x",`Float 0.25;"y",`Float 0.5] in
  let click extra = fields "click_at" @ ["expectedUrl",`String "https://example.org";
    "viewport",viewport;"point",point] @ extra in
  let button_of extra = match (parsed (click extra)).action with
    | Browser_lane.Click_at {button;_} -> button
    | _ -> fail "click_at parsed as another action" in
  check bool "no button means the primary one" true
    (button_of [] = Browser_lane.Pointer.Primary);
  List.iter (fun (raw,expected) ->
    check bool ("button " ^ raw) true (button_of ["button",`String raw] = expected);
    let request = parsed (click ["button",`String raw]) in
    let wire = Browser_lane.interaction_args ~tab_id:request.tab_id
      ~expected_url:request.expected_url request.action in
    check bool ("button " ^ raw ^ " survives the wire round trip") true
      ((parsed Yojson.Safe.Util.(to_assoc wire)).action = request.action))
    ["primary",Browser_lane.Pointer.Primary;"middle",Browser_lane.Pointer.Middle;
     "secondary",Browser_lane.Pointer.Secondary];
  List.iter (fun bad ->
    check bool "unknown or mistyped button rejected" true
      (Result.is_error (Interaction.parse (`Assoc (click ["button",bad])))))
    [`String "left";`String "";`String "Middle";`Int 1;`Null];
  check bool "button is refused on an action that has no button" true
    (Result.is_error (Interaction.parse (`Assoc (fields "hover_at"
      @ ["expectedUrl",`String "https://example.org";"viewport",viewport;"point",point;
         "button",`String "middle"]))))
let test_click_button_capability () =
  let click button = Browser_lane.Page_interact {tab_id=1; expected_url=Some "https://example.org";
    action=Browser_lane.Click_at {point={x=0.5;y=0.5};
      viewport={document_id="d";width=100.;height=100.;scroll_x=0.;scroll_y=0.}; button}} in
  check bool "primary click keeps the plain pointer capability" true
    (Browser_lane.live_capability (click Browser_lane.Pointer.Primary) = Some Browser_lane.Point_click);
  List.iter (fun button ->
    check bool "middle and secondary ask for the button capability" true
      (Browser_lane.live_capability (click button) = Some Browser_lane.Trusted_button_click))
    [Browser_lane.Pointer.Middle;Browser_lane.Pointer.Secondary];
  check bool "the extension cannot serve a non-primary button" false
    (Browser_lane.live_transport_serves Browser_lane.Web_extension Browser_lane.Trusted_button_click);
  check bool "a live BiDi connection serves it" true
    (Browser_lane.live_transport_serves Browser_lane.Webdriver_bidi Browser_lane.Trusted_button_click)
let test_click_button_wire_numbers () =
  let viewport : Browser_lane.Pointer.viewport =
    {document_id="d";width=100.;height=100.;scroll_x=0.;scroll_y=0.} in
  let numbers button =
    let sources = Browser_lane.Pointer.input_sources ~pointer_id:"p" ~wheel_id:"w" ~viewport
      ~start:{x=0.5;y=0.5} (Browser_lane.Pointer.Click button) in
    match sources with
    | `List [source] ->
      Yojson.Safe.Util.(source |> member "actions" |> to_list
        |> List.filter_map (fun action -> match member "type" action with
          | `String ("pointerDown" | "pointerUp") -> Some (member "button" action |> to_int)
          | _ -> None))
    | _ -> fail "one pointer source required" in
  check (list int) "primary presses and releases button 0" [0;0] (numbers Browser_lane.Pointer.Primary);
  check (list int) "middle presses and releases button 1" [1;1] (numbers Browser_lane.Pointer.Middle);
  check (list int) "secondary presses and releases button 2" [2;2] (numbers Browser_lane.Pointer.Secondary)
let () = run "browser interaction" ["typed boundary", [
  test_case "browser zoom boundary" `Quick test_browser_zoom_boundary;
  test_case "native keyboard and double click parser" `Quick test_native_keyboard_parser;
  test_case "observed semantic pointer targets" `Quick test_semantic_pointer_actions;
  test_case "drag path and timing contract" `Quick test_drag_options;
  test_case "explicit live tab activation" `Quick test_activate_tab;
  test_case "screenshot pointer actions" `Quick test_pointer_actions;
  test_case "click button parses and round trips" `Quick test_click_button;
  test_case "click button picks the live capability" `Quick test_click_button_capability;
  test_case "click button uses the WebDriver button numbers" `Quick test_click_button_wire_numbers;
  test_case "source hints preserve scope and reject malformed paths" `Quick test_source_context;
  test_case "observed node reference contract" `Quick test_scene_reference;
  test_case "closed live write actions" `Quick test_typed_actions;
  test_case "malformed or mixed actions rejected" `Quick test_invalid_actions]]
