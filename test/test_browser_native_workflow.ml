open Alcotest
module W = Browser_lane.Native_workflow
module R = Masc.Browser_ego_workflow
let obj fields = `Assoc fields
let str value = `String value
let ok = function Ok value -> value | Error message -> fail message
let base steps = ["tabId",`Int 1;"expectedUrl",str "https://example.test/start";
  "steps",`List steps;"maxChars",`Int 1000]
let step method_ fields = obj (("method",str method_)::fields)
let click = step "click" ["selector",str "@12"]
let wait = step "waitForURL" ["url",str "**/done"]
let request steps = ok (W.of_json (obj (base steps)))
let entry index method_ = obj ["index",`Int index;"method",str method_;"receipt",`Null]
let result ~started ~completed_effect ~completed ~failure = [
  "effectStarted",`Bool started;"completedEffect",`Bool completed_effect;
  "completed",`List completed;"failure",failure]
let snapshot = ["urlBefore",str "https://example.test/start";"url",str "https://example.test/done";"title",str "Done";
  "snapshot",str "native snapshot";"chars",`Int 15;"truncated",`Bool false]
let failure index method_ = obj ["index",`Int index;"method",str method_;"message",str "SDK error"]
let roundtrip () =
  let calls=[click;step "dblclick" ["selector",str "loc=css:#row"];step "hover" ["selector",str "@3"];
    step "fill" ["selector",str "@4";"text",str ""];
    step "press" ["selector",str "@4";"key",str "Enter"];
    step "selectOption" ["selector",str "@5";"values",`List []];
    step "goto" ["url",str "https://example.test/done"];wait;
    step "waitForSelector" ["selector",str "@6";"state",str "hidden";"timeoutMs",`Int 0];
    step "waitForLoadState" ["state",str "networkidle"]] in
  let parsed=request calls in
  check bool "native fields roundtrip unchanged" true (ok (W.of_json (W.to_json parsed))=parsed);
  check int "all methods preserved" (List.length calls) (List.length parsed.steps)
let strict_inputs () =
  List.iter (fun value -> check bool "invalid caller input is rejected" true (Result.is_error (W.of_json value)))
    [obj (("steps",`List [])::base []);
     obj (base [step "evaluate" ["text",str "process.exit()"]]);
     obj (base [step "fill" ["selector",str "#x";"text",str "hi";"url",str "irrelevant"]]);
     obj (base [step "click" ["selector",str "#x";"timeoutMs",`Int (-1)]]);
     obj (base [step "goto" ["url",str "javascript:alert(1)"]]);
     obj (base [step "selectOption" ["selector",str "#x";"values",`List [str "a";str "a"]]])]
let complete () =
  let value=obj (snapshot @ result ~started:true ~completed_effect:true
    ~completed:[entry 0 "click";entry 1 "waitForURL"] ~failure:`Null) in
  match ok (R.decode (request [click;wait]) value) with
  | R.Completed actual -> check bool "native final URL and snapshot returned" true (actual=value)
  | R.Stopped _ -> fail "a complete sequence was stopped"
let progress_and_uncertainty () =
  let assert_stopped request fields ~started ~completed_effect =
    match ok (R.decode request (obj fields)) with
    | R.Stopped observed ->
      check bool "started effect" started observed.effect_started;
      check bool "completed effect" completed_effect observed.completed_effect
    | R.Completed _ -> fail "failed sequence was called complete" in
  assert_stopped (request [wait]) (result ~started:false ~completed_effect:false ~completed:[] ~failure:(failure 0 "waitForURL"))
    ~started:false ~completed_effect:false;
  assert_stopped (request [click]) (result ~started:true ~completed_effect:false ~completed:[] ~failure:(failure 0 "click"))
    ~started:true ~completed_effect:false;
  assert_stopped (request [click;wait]) (result ~started:true ~completed_effect:true ~completed:[entry 0 "click"] ~failure:(failure 1 "waitForURL"))
    ~started:true ~completed_effect:true
let malformed_receipts () =
  let expected=request [click;wait] in
  List.iter (fun value -> check bool "incomplete/mismatched execution is not success" true (Result.is_error (R.decode expected value)))
    [`Null;
     obj (result ~started:true ~completed_effect:true ~completed:[entry 0 "click";entry 1 "waitForURL"] ~failure:`Null);
     obj (snapshot @ result ~started:true ~completed_effect:true ~completed:[entry 0 "click"] ~failure:`Null);
     obj (snapshot @ result ~started:true ~completed_effect:true ~completed:[entry 0 "waitForURL";entry 1 "click"] ~failure:`Null);
     obj (snapshot @ result ~started:false ~completed_effect:false ~completed:[entry 0 "click";entry 1 "waitForURL"] ~failure:`Null)]
let proof path =
  let json=Yojson.Safe.from_file path in
  let request=ok (W.of_json (Yojson.Safe.Util.member "request" json)) in
  (match ok (R.decode request (Yojson.Safe.Util.member "result" json)) with
   | R.Completed _ -> print_endline "Real Ego receipt decoded against its exact request"
   | R.Stopped _ -> fail "real browser fixture did not complete")
let () = if Array.length Sys.argv=3 && Sys.argv.(1)="--proof" then proof Sys.argv.(2)
  else run "native_browser_workflow" ["SDK contract",[
  test_case "native methods preserve values" `Quick roundtrip;
  test_case "invalid methods and fields are refused" `Quick strict_inputs;
  test_case "snapshot completes the exact requested sequence" `Quick complete;
  test_case "failed waits and uncertain effects retain progress" `Quick progress_and_uncertainty;
  test_case "malformed execution never proves success" `Quick malformed_receipts]]
