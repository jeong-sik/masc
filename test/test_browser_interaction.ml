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
    ["click_at",["point",point];"drag",["from",point;"to",point];
     "scroll_at",["point",point;"x",`Int 0;"y",`Int 120]];
  List.iter (fun bad ->
    check bool "invalid screenshot coordinates rejected before dispatch" true
      (Result.is_error (Interaction.parse (`Assoc
        (fields "click_at" @ base @ ["point",bad])))))
    [`Assoc ["x",`Float 1.;"y",`Float 0.];
     `Assoc ["x",`Float (-0.1);"y",`Float 0.];
     `Assoc ["x",`Float nan;"y",`Float 0.];
     `Assoc ["x",`Int 0;"y",`Int 0;"x",`Int 0]]
let () = run "browser interaction" ["typed boundary", [
  test_case "explicit live tab activation" `Quick test_activate_tab;
  test_case "screenshot pointer actions" `Quick test_pointer_actions;
  test_case "source hints preserve scope and reject malformed paths" `Quick test_source_context;
  test_case "observed node reference contract" `Quick test_scene_reference;
  test_case "closed live write actions" `Quick test_typed_actions;
  test_case "malformed or mixed actions rejected" `Quick test_invalid_actions]]
