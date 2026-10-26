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
  "effectStarted",`Bool started;"completedEffect",`Bool completed_effect;"inputReleased",`Bool true;
  "completed",`List completed;"failure",failure]
let snapshot = ["urlBefore",str "https://example.test/start";"url",str "https://example.test/done";"title",str "Done";
  "snapshot",str "native snapshot";"chars",`Int 15;"truncated",`Bool false]
let failure index method_ = obj ["index",`Int index;"method",str method_;"message",str "SDK error"]
let roundtrip () =
  let calls=[click;step "dblclick" ["selector",str "loc=css:#row"];step "hover" ["selector",str "@3"];
    step "fill" ["selector",str "@4";"text",str ""];
    step "press" ["selector",str "@4";"key",str "Enter"];
    step "focus" ["selector",str "#editor";"options",obj ["timeout",`Int 0]];
    step "keyboard.type" ["text",str "typed";"options",obj ["delay",`Float 1.5]];
    step "keyboard.insertText" ["text",str "한글 😀"];
    step "keyboard.paste" ["text",str "Name\tStatus";"html",str "<table><tr><td>Name</td><td>Status</td></tr></table>"];
    step "keyboard.paste" ["text",str ""];
    step "keyboard.press" ["key",str "ControlOrMeta+A";"options",obj ["delay",`Int 0]];
    step "reload" [];
    step "selectOption" ["selector",str "@5";"selectionJson",str "[]"];
    step "goto" ["url",str "https://example.test/done";"options",obj ["waitUntil",str "commit";
      "referer",str "https://example.test/"]];wait;
    step "waitForSelector" ["selector",str "@6";"state",str "hidden";"options",obj ["timeout",`Int 0]];
    step "waitForLoadState" ["state",str "networkidle";"options",obj ["idleMs",`Int 0]];
    step "waitForLoadState" [];
    step "evaluate" ["source",str "document.title"];
    step "evaluate" ["source",str "value => value";"argumentJson",str "null"];
    step "waitForFunction" ["source",str "arg => window.ready === arg";"argumentJson",str "true";
      "options",obj ["polling",`Int 0;"timeout",`Int 120_000]];
    step "fetch" ["url",str "/api/data";"options",obj [
      "method",str "POST";"headers",obj ["Content-Type",str "text/plain"];
      "body",str "한글 😀";"cache",str "no-store";"credentials",str "same-origin";
      "keepalive",`Bool false;"mode",str "cors";"redirect",str "error";"referrerPolicy",str "no-referrer"]];
    step "fetch" ["url",str ""];
    step "click" ["selector",str "@1";"options",obj ["button",str "right";"clickCount",`Int 2;
      "delay",`Float 0.5;"position",obj ["x",`Int (-1);"y",`Int 4];"force",`Bool false;"label",str "Open row menu"]];
    step "dragAndDrop" ["selector",str "#source";"destination",str "#target";"options",obj ["button",str "middle";
      "sourcePosition",obj ["x",`Int 2;"y",`Float 3.5];"targetPosition",obj ["x",`Int 6;"y",`Int 9];"force",`Bool false]];
    step "mouse.click" ["x",`Float 0.5;"y",`Int 42;"options",obj ["button",str "left";"delay",`Int 0]];
    step "mouse.move" ["x",`Int 3;"y",`Int 4;"options",obj ["steps",`Int 2;"label",str "Point at editor"]];
    step "mouse.wheel" ["x",`Int 0;"y",`Int 120;"options",obj ["label",str "Read next rows"]]]
    @ [step "url" [];step "title" [];step "info" [];step "events" [];
      step "waitForTimeout" ["milliseconds",`Float 0.5];
      step "snapshot" [];
      step "snapshot" ["options",obj ["includeActionMarks",`Bool false;"includeStableLocator",`Bool true]];
      step "snapshot" ["options",obj ["scope",str "subtree";"root",str "@21"]]]
    @ List.map (fun selection -> step "selectOption" ["selector",str "#select";"selectionJson",str selection])
      ["null";"\"B\"";"{\"label\":\"B\"}";"{\"index\":0}";"[{\"value\":\"b\"},\"a\",\"a\"]"] in
  let parsed=request calls in
  check bool "native fields roundtrip unchanged" true (ok (W.of_json (W.to_json parsed))=parsed);
  check int "all methods preserved" (List.length calls) (List.length parsed.steps);
  let explicit = step "hover" ["selector",str "@1";"options",obj ["timeout",`Int 120_000]] in
  let longer = request (List.init 20 (fun _ -> explicit)) in
  check int "known sequence has no invented step cap" 20 (List.length longer.steps);
  check bool "SDK timeout survives unchanged" true
    (List.for_all (fun step -> Yojson.Safe.Util.(step |> member "options" |> member "timeout")=`Int 120_000)
      Yojson.Safe.Util.(W.to_json longer |> member "steps" |> to_list))
let strict_inputs () =
  List.iter (fun value -> check bool "invalid caller input is rejected" true (Result.is_error (W.of_json value)))
    [obj (("steps",`List [])::base []);
     obj (base [step "evaluate" ["text",str "process.exit()"]]);
     obj (base [step "fill" ["selector",str "#x";"text",str "hi";"url",str "irrelevant"]]);
     obj (base [step "click" ["selector",str "#x";"timeoutMs",`Int (-1)]]);
     obj (base [step "click" ["selector",str "#x";"timeoutMs",`Int 9007199254740992]]);
     obj (base [step "goto" ["url",str "javascript:alert(1)"]]);
     obj (base [step "keyboard.paste" ["text",str "x";"html",`Null]]);
     obj (base [step "keyboard.type" ["text",str "x";"timeoutMs",`Int 0]]);
     obj (base [step "keyboard.insertText" ["text",str "x";"selector",str "#other"]]);
     obj (base [step "keyboard.press" ["key",str ""]]);
     obj (base [step "evaluate" ["source",str "document.title";"timeoutMs",`Int 1]]);
     obj (base [step "evaluate" ["source",str "arg => arg";"argumentJson",str "NaN"]]);
     obj (base [step "evaluate" ["source",str "arg => arg";"argumentJson",str "{\"x\":1,\"x\":2}"]]);
     obj (base [step "waitForFunction" ["source",str "true";"pollingMs",`Int (-1)]]);
     obj (base [step "fetch" ["url",str "file:///private/data"]]);
     obj (base [step "fetch" ["url",str "/api";"options",obj ["saveAs",str "/tmp/leak"]]]);
     obj (base [step "fetch" ["url",str "/api";"options",obj ["mode",str "fallback"]]]);
     obj (base [step "fetch" ["url",str "/api";"options",obj ["headers",obj ["X",`Int 1]]]]);
     obj (base [step "click" ["selector",str "@1";"options",obj ["force",`Int 1]]]);
     obj (base [step "click" ["selector",str "@1";"options",obj ["timeout",`Int (-1)]]]);
     obj (base [step "click" ["selector",str "@1";"options",obj ["position",obj ["x",`Float Float.nan;"y",`Int 0]]]]);
     obj (base [step "keyboard.type" ["text",str "x";"options",obj ["label",str "not an SDK option"]]]);
     obj (base [step "keyboard.insertText" ["text",str "x";"options",obj []]]);
     obj (base [step "url" ["options",obj []]]);
     obj (base [step "title" ["source",str "document.title"]]);
     obj (base [step "events" ["options",obj ["timeout",`Int 1]]]);
     obj (base [step "waitForTimeout" ["milliseconds",`Int (-1)]]);
     obj (base [step "waitForTimeout" ["milliseconds",`Float Float.infinity]]);
     obj (base [step "waitForTimeout" ["milliseconds",`Int 0;"options",obj []]]);
     obj (base [step "snapshot" ["options",obj ["scope",str "viewport"]]]);
     obj (base [step "snapshot" ["options",obj ["scope",str "subtree"]]]);
     obj (base [step "snapshot" ["options",obj ["root",str "@21"]]]);
     obj (base [step "snapshot" ["options",obj ["scope",str "full_page";"root",str "@21"]]]);
     obj (base [step "snapshot" ["options",obj ["scope",str "subtree";"root",str " "]]]);
     obj (base [step "snapshot" ["options",obj ["includeStableLocator",`Int 1]]]);
     obj (base [step "selectOption" ["selector",str "#x";"selectionJson",str "{}"]]);
     obj (base [step "selectOption" ["selector",str "#x";"selectionJson",str "[1]"]]);
     obj (base [step "selectOption" ["selector",str "#x";"selectionJson",str "{\"index\":-1}"]])]
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
  let press=step "press" ["selector",str "#editor";"key",str "Enter"] in
  assert_stopped (request [press])
    (result ~started:false ~completed_effect:false ~completed:[] ~failure:(failure 0 "inputPreflight"))
    ~started:false ~completed_effect:false;
  assert_stopped (request [click;press])
    (result ~started:true ~completed_effect:true ~completed:[entry 0 "click"] ~failure:(failure 1 "inputPreflight"))
    ~started:true ~completed_effect:true;
  assert_stopped (request [wait]) (result ~started:false ~completed_effect:false ~completed:[] ~failure:(failure 0 "waitForURL"))
    ~started:false ~completed_effect:false;
  assert_stopped (request [click]) (result ~started:true ~completed_effect:false ~completed:[] ~failure:(failure 0 "click"))
    ~started:true ~completed_effect:false;
  assert_stopped (request [click;wait]) (result ~started:true ~completed_effect:true ~completed:[entry 0 "click"] ~failure:(failure 1 "waitForURL"))
    ~started:true ~completed_effect:true;
  assert_stopped (request [step "keyboard.paste" ["text",str "x"]])
    (result ~started:true ~completed_effect:false ~completed:[] ~failure:(failure 0 "keyboard.paste"))
    ~started:true ~completed_effect:false;
  List.iter (fun (method_,fields) ->
    assert_stopped (request [step method_ fields])
      (result ~started:true ~completed_effect:false ~completed:[] ~failure:(failure 0 method_))
      ~started:true ~completed_effect:false)
    ["evaluate",["source",str "document.title"];
     "waitForFunction",["source",str "false"];
     "fetch",["url",str "https://example.test/"];
     "events",[]];
  assert_stopped (request [step "keyboard.insertText" ["text",str "x"];click])
    (result ~started:true ~completed_effect:true ~completed:[entry 0 "keyboard.insertText"] ~failure:(failure 1 "observation"))
    ~started:true ~completed_effect:true
let observations () =
  let methods=["url",[],str "https://example.test/start";
    "title",[],str "Title";"info",[],obj ["url",str "https://example.test/start"];
    "snapshot",["options",obj ["scope",str "subtree";"root",str "@21"]],str "subtree";
    "events",[],`List [obj ["method",str "Page.loadEventFired"]];
    "waitForTimeout",["milliseconds",`Int 0],`Null] in
  List.iter (fun (method_,arguments,receipt) ->
    let expected=request [step method_ arguments] in
    let consumes_events=method_="events" in
    let row=obj ["index",`Int 0;"method",str method_;"receipt",receipt] in
    (match ok (R.decode expected (obj (snapshot @ result ~started:consumes_events ~completed_effect:consumes_events
       ~completed:[row] ~failure:`Null))) with
     | R.Completed _ -> () | R.Stopped _ -> fail "native observation was stopped");
    let bad=if receipt=`Null then str "not void" else `Null in
    let row=obj ["index",`Int 0;"method",str method_;"receipt",bad] in
    check bool "native observation receipt shape is checked" true
      (Result.is_error (R.decode expected (obj (snapshot @ result ~started:consumes_events ~completed_effect:consumes_events
        ~completed:[row] ~failure:`Null))))) methods
let malformed_receipts () =
  let expected=request [click;wait] in
  List.iter (fun value -> check bool "incomplete/mismatched execution is not success" true (Result.is_error (R.decode expected value)))
    [`Null;
     obj (result ~started:false ~completed_effect:false ~completed:[] ~failure:(failure 0 "inputPreflight"));
     obj (result ~started:true ~completed_effect:true ~completed:[entry 0 "click";entry 1 "waitForURL"] ~failure:`Null);
     obj (snapshot @ result ~started:true ~completed_effect:true ~completed:[entry 0 "click"] ~failure:`Null);
     obj (snapshot @ result ~started:true ~completed_effect:true ~completed:[entry 0 "waitForURL";entry 1 "click"] ~failure:`Null);
     obj (snapshot @ result ~started:false ~completed_effect:false ~completed:[entry 0 "click";entry 1 "waitForURL"] ~failure:`Null)]
let pointer_release () =
  let drag=step "dragAndDrop" ["selector",str "#source";"destination",str "#target"] in
  let fields=result ~started:true ~completed_effect:false ~completed:[] ~failure:(failure 0 "dragAndDrop") in
  let fields=("inputReleased",`Bool false)::List.remove_assoc "inputReleased" fields in
  (match ok (R.decode (request [drag;click]) (obj fields)) with
   | R.Stopped {input_released=false;_} -> ()
   | R.Completed _|R.Stopped _ -> fail "lost release was called confirmed");
  let paste_fields=("failure",failure 0 "keyboard.paste")::List.remove_assoc "failure" fields in
  (match ok (R.decode (request [step "keyboard.paste" ["text",str "x"]]) (obj paste_fields)) with
   | R.Stopped {input_released=false;_} -> ()
   | R.Completed _|R.Stopped _ -> fail "paste lost its modifier release uncertainty");
  check bool "held input is impossible without a holding operation" true
    (Result.is_error (R.decode (request [step "fill" ["selector",str "#editor";"text",str "x"]]) (obj fields)))
let proof path =
  let json=Yojson.Safe.from_file path in
  let request=ok (W.of_json (Yojson.Safe.Util.member "request" json)) in
  (match ok (R.decode request (Yojson.Safe.Util.member "result" json)) with
   | R.Completed _ -> print_endline "Real Ego receipt decoded against its exact request"
   | R.Stopped _ -> fail "real browser fixture did not complete")
let page_proof path =
  proof path;
  let json=Yojson.Safe.from_file path in
  List.iter (fun (request_key,result_key) ->
    let request=ok (W.of_json (Yojson.Safe.Util.member request_key json)) in
    match ok (R.decode request (Yojson.Safe.Util.member result_key json)) with
    | R.Stopped {effect_started=true;completed_effect=false;_} -> ()
    | R.Completed _ | R.Stopped _ -> fail "a failed Page call lost its uncertain-effect boundary")
    ["blockedRequest","blocked";"timeoutRequest","timedOut"];
  print_endline "Real CORS and predicate-timeout receipts retain uncertain effects and exact progress"
let () = if Array.length Sys.argv=3 && Sys.argv.(1)="--proof" then proof Sys.argv.(2)
  else if Array.length Sys.argv=3 && Sys.argv.(1)="--page-proof" then page_proof Sys.argv.(2)
  else run "native_browser_workflow" ["SDK contract",[
  test_case "native methods preserve values" `Quick roundtrip;
  test_case "invalid methods and fields are refused" `Quick strict_inputs;
  test_case "snapshot completes the exact requested sequence" `Quick complete;
  test_case "failed waits and uncertain effects retain progress" `Quick progress_and_uncertainty;
  test_case "native observations retain values and event-drain effects" `Quick observations;
  test_case "drag release is separate from effect completion" `Quick pointer_release;
  test_case "malformed execution never proves success" `Quick malformed_receipts]]
