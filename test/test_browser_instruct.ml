(* BrowserInstruct through a fake Stagehand executor: which verb a call
   becomes, what reaches the lane, and whether a failure may have acted. *)
open Alcotest
module Lane = Browser_lane
module Tools = Masc.Tool_misc_browser_lane

let sent = ref []

let with_executor answer f =
  sent := [];
  Eio_main.run
  @@ fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Lane.install_stagehand_executor
    (Some
       (fun verb ->
         sent := verb :: !sent;
         answer));
  Fun.protect ~finally:(fun () -> Lane.install_stagehand_executor None) f
;;

let served = Lane.Answered (`Assoc [ "ok", `Bool true; "data", `Assoc [ "tabId", `Int 3 ] ])
let args fields = `Assoc fields
let instruct fields = Tools.handle_instruct_with_phase ~tool_name:"masc_browser_instruct" ~start_time:0.0 (args fields)
let verb_name = function [ verb ] -> Lane.verb_to_string verb | verbs -> Printf.sprintf "%d verbs" (List.length verbs)

let test_extension_deadline_precedes_lane_deadline () =
  let extension_s =
    float_of_int (Masc.Browser_stagehand_wire.timeout_ms Masc.Browser_stagehand_wire.sentence_timeout) /. 1000.
  in
  check bool "the extension and model can answer before the lane abandons the call" true
    (Tools.instruct_timeout_sec > extension_s)
;;

let test_actions_become_sentence_verbs () =
  with_executor served
  @@ fun () ->
  List.iter
    (fun (fields, expected) ->
      sent := [];
      let result, _ = instruct fields in
      check bool (expected ^ " served") true (Tool_result.is_success result);
      check string expected expected (verb_name !sent))
    [ [ "action", `String "act"; "instruction", `String "click Buy"; "tabId", `Int 3 ], "page.instruct";
      [ "action", `String "observe"; "tabId", `Int 3 ], "page.locate";
      [ "action", `String "extract"; "instruction", `String "the price"; "tabId", `Int 3;
        "schema", `String {|{"type":"object"}|} ], "page.extract" ];
  match !sent with
  | [ Lane.Page_extract { schema = Some (`Assoc _); _ } ] -> ()
  | _ -> fail "the schema text reaches extract as JSON"
;;

let test_bad_input_sends_nothing () =
  with_executor served
  @@ fun () ->
  List.iter
    (fun (name, fields) ->
      let result, phase = instruct fields in
      check bool name false (Tool_result.is_success result);
      check bool (name ^ ": before effect") true (phase = Tool_result.Proven_pre_effect))
    [ "act without an instruction", [ "action", `String "act"; "tabId", `Int 3 ];
      "a schema on act", [ "action", `String "act"; "instruction", `String "x"; "tabId", `Int 3; "schema", `String "{}" ];
      "schema that is not JSON", [ "action", `String "extract"; "instruction", `String "x"; "tabId", `Int 3; "schema", `String "{" ];
      "no tab", [ "action", `String "observe" ];
      "an unknown action", [ "action", `String "click"; "tabId", `Int 3 ];
      "an unknown argument", [ "action", `String "observe"; "tabId", `Int 3; "lane", `String "stagehand" ] ];
  let unknown, _ =
    instruct
      [ "action", `String "observe"; "tabId", `Int 3; "lane", `String "stagehand" ]
  in
  check bool "unknown lane argument is named with the stagehand-only rule" true
    (String.starts_with
       ~prefix:"Invalid browser arguments: unknown browser instruct argument: lane; BrowserInstruct is stagehand only and takes no lane"
       (Tool_result.message unknown));
  check int "nothing reached the lane" 0 (List.length !sent)
;;

let test_a_failed_act_may_have_acted () =
  let phase_of fields = snd (instruct fields) in
  with_executor (Lane.Refused "Stagehand did not answer")
  @@ fun () ->
  check bool "act" true
    (phase_of [ "action", `String "act"; "instruction", `String "click Buy"; "tabId", `Int 3 ]
     = Tool_result.Effect_outcome_unknown);
  check bool "extract reads" true
    (phase_of [ "action", `String "extract"; "instruction", `String "the price"; "tabId", `Int 3 ]
     = Tool_result.Proven_pre_effect)
;;

(* Stagehand 4.1.0 answers an act it could not carry out as a normal result
   with data.success = false. Through the real executor, BrowserInstruct
   reports that act as a failed tool call that may have acted. *)
let test_an_unsuccessful_act_is_a_failure () =
  let module Wire = Masc.Browser_stagehand_wire in
  let module Executor = Masc.Browser_stagehand_executor in
  let page = `Assoc [ "page_id", `String "P1"; "url", `String "http://127.0.0.1:1/" ] in
  let call = function
    | Wire.Context_pages -> Ok (`List [ page ])
    | Wire.Context_active_page -> Ok page
    | Wire.Page_evaluate _ -> Ok (`Assoc [ "value", `String {|{"url":"http://127.0.0.1:1/","title":"Shop"}|} ])
    | Wire.Act _ ->
      Ok
        (`Assoc
          [ "data", `Assoc [ "success", `Bool false; "message", `String "no element matched" ]; "metadata", `Assoc [] ])
    | request -> failf "the executor sent %s" (Wire.method_name request)
  in
  let tabs = Executor.Tabs.create () in
  Eio_main.run
  @@ fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Lane.install_stagehand_executor (Some (Executor.execute ~tabs ~call));
  Fun.protect ~finally:(fun () -> Lane.install_stagehand_executor None)
  @@ fun () ->
  (match Executor.execute ~tabs ~call Lane.Tabs_list with
   | Lane.Answered _ -> ()
   | Lane.Lane_absent | Lane.Timed_out | Lane.Refused _ | Lane.Rejected_before_effect _ -> fail "the tabs were listed");
  let result, phase = instruct [ "action", `String "act"; "instruction", `String "click Buy"; "tabId", `Int 0 ] in
  check bool "the tool call failed" false (Tool_result.is_success result);
  check bool "the act may have acted" true (phase = Tool_result.Effect_outcome_unknown);
  check bool "Stagehand's message reaches the Keeper" true
    (let message = Tool_result.message result and needle = "no element matched" in
     let rec has i =
       i + String.length needle <= String.length message
       && (String.equal (String.sub message i (String.length needle)) needle || has (i + 1))
     in
     has 0)
;;

let () =
  run "browser_instruct" [
    "input", [
      test_case "the sentence deadline precedes the lane deadline" `Quick test_extension_deadline_precedes_lane_deadline;
      test_case "each action becomes its sentence verb" `Quick test_actions_become_sentence_verbs;
      test_case "bad input reaches no browser" `Quick test_bad_input_sends_nothing;
    ];
    "effects",
    [ test_case "a failed act may have acted, a failed read did not" `Quick test_a_failed_act_may_have_acted;
      test_case "an act Stagehand did not carry out is a failure" `Quick test_an_unsuccessful_act_is_a_failure
    ];
  ]
;;
