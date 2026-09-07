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
let () = run "browser interaction" ["typed boundary", [
  test_case "closed live write actions" `Quick test_typed_actions;
  test_case "malformed or mixed actions rejected" `Quick test_invalid_actions]]
