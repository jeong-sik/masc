open Alcotest
module W = Browser_lane.Native_workflow
module R = Masc.Browser_ego_workflow
module Rel = Masc.Browser_ego_release
let obj fields = `Assoc fields
let str value = `String value
let ok = function Ok value -> value | Error message -> fail message
let base steps = ["tabId",`Int 1;"expectedUrl",str "https://example.test/start";
  "steps",`List steps;"maxChars",`Int 1000]
let step method_ fields = obj (("method",str method_)::fields)
let click = step "click" ["selector",str "@12"]
let wait = step "waitForURL" ["url",str "**/done"]
let request steps = ok (W.of_json (obj (base steps)))
let entry ?(receipt=`Null) index method_ = obj ["index",`Int index;"method",str method_;"receipt",receipt]
let clicked index = entry ~receipt:(obj []) index "click"
let result ~started ~completed_effect ~completed ~failure = [
  "effectStarted",`Bool started;"completedEffect",`Bool completed_effect;"inputReleased",`Bool true;
  "completed",`List completed;"failure",failure]
let snapshot = ["urlBefore",str "https://example.test/start";"url",str "https://example.test/done";"title",str "Done";
  "snapshot",str "native snapshot";"chars",`Int 15;"truncated",`Bool false]
let failure index method_ = obj ["index",`Int index;"method",str method_;"message",str "SDK error"]
let unreleased fields = ("inputReleased",`Bool false)::List.remove_assoc "inputReleased" fields
(* Receipt-only methods require declared receipts. Raw typing instead needs its
   independently authenticated native window, exercised separately below. *)
let seen_input = function
  | Rel.Settled (Rel.Released (Rel.Released_by_receipts proven)) -> `Released proven
  | Rel.Settled (Rel.Released (Rel.Completed_by_evidence evidence)) ->
    `Released (List.map (function Rel.Receipt_step index|Rel.Window_step {index;_}->index) evidence)
  | Rel.Settled Rel.No_hold -> `No_hold
  | Rel.Unconfirmed reason -> `Unconfirmed reason
let with_claim claim fields=if claim then fields else unreleased fields
let stopped label expected = function
  | Ok (R.Stopped {input;_}) -> check bool label true (seen_input input=expected)
  | Ok (R.Completed _) -> fail (label ^ ": a failed sequence was called complete")
  | Error message -> fail (label ^ ": " ^ message)
let refused label decoded = check bool label true (Result.is_error decoded)
let not_released index answer = `Unconfirmed (Rel.Step_not_released {index;answer})
(* [None] is the one answer that releases. *)
let kind_of = function Rel.Receipt_without_dialog|Rel.Native_window_tail _|Rel.Refused_before_press _ -> None | Rel.Unreleased kind -> Some kind
(* The only way to get a releasing answer is to read a receipt the SDK declares. *)
let clean = Rel.answer_of_json (obj [])
(* Receipts that release nothing, with the kind the decoder must name for each. *)
let undeclared=[`Null,Rel.Void_answer;str "ok",Rel.Undeclared_answer;`Int 1,Rel.Undeclared_answer;
  `Bool true,Rel.Undeclared_answer;`List [],Rel.Undeclared_answer;
  obj ["dialog",obj ["type",str "alert"]],Rel.Receipt_with_dialog;
  obj ["dialog",`Null],Rel.Undeclared_answer;obj ["dialog",`Bool false],Rel.Undeclared_answer;
  obj ["dialog",`Int 0],Rel.Undeclared_answer;obj ["dialog",str ""],Rel.Undeclared_answer;
  `Float 0.5,Rel.Undeclared_answer;obj ["dialog",`List []],Rel.Undeclared_answer;
  obj ["dialog",`Bool true],Rel.Undeclared_answer;obj ["dialog",str "x"],Rel.Undeclared_answer;
  obj ["dialog",obj []],Rel.Receipt_with_dialog;
  (* Members the SDK does not declare, and a popup list that is not the declared shape. *)
  obj ["error",str "boom";"ok",`Bool false],Rel.Undeclared_answer;
  obj ["error",str "boom"],Rel.Undeclared_answer;obj ["ok",`Bool false],Rel.Undeclared_answer;
  obj ["interrupted",`Bool true],Rel.Undeclared_answer;
  obj ["popups",`Int 5],Rel.Undeclared_answer;obj ["popups",`List [str "p2"]],Rel.Undeclared_answer;
  obj ["popups",`List [obj ["label",`Int 1;"targetId",str "T2"]]],Rel.Undeclared_answer;
  obj ["popups",`List [obj ["label",str "p2"]]],Rel.Undeclared_answer;
  obj ["popups",`List [obj ["label",str "p2";"targetId",str "T2"];str "p3"]],Rel.Undeclared_answer;
  obj ["popups",`List [obj ["label",`Null;"targetId",str "T2"]]],Rel.Undeclared_answer;
  obj ["popups",`List [obj ["label",str "p2";"targetId",`Null]]],Rel.Undeclared_answer;
  obj ["popups",`List [obj ["label",str "";"targetId",str "T2"]]],Rel.Undeclared_answer;
  obj ["popups",`List [obj ["label",str "p2";"targetId",str ""]]],Rel.Undeclared_answer;
  (* A member that appears twice has no single value to read. *)
  obj ["popups",`List [];"popups",`Int 5],Rel.Undeclared_answer;
  obj ["dialog",obj ["type",str "alert"];"dialog",`Null],Rel.Undeclared_answer;
  obj ["popups",`List [obj ["label",str "p2";"targetId",str "T2";"label",str ""]]],Rel.Undeclared_answer;
  obj ["popups",`List [obj ["label",str "p2";"targetId",str "T2";"url",str "https://example.test/"]]],Rel.Undeclared_answer;
  obj ["popups",obj []],Rel.Undeclared_answer]
(* Receipts the SDK declares without a dialog. *)
let declared_clean=[obj [];obj ["popups",`List []];
  obj ["popups",`List [obj ["label",str "p2";"targetId",str "T2"]]];
  obj ["popups",`List [obj ["label",str "p2";"targetId",str "T2"];obj ["label",str "p3";"targetId",str "T3"]]]]
let native_input_admission () =
  let module Contract=Browser_lane.Native_input in
  let denied=request [step "fill" ["selector",str "#editor";"text",str "before"];
    step "keyboard.type" ["text",str "unsafe"];click] in
  check bool "raw typing cannot use the receipt-only contract" true
    (Contract.contract Contract.Keyboard_type=Contract.Observed_native_window);
  let insertion=request [step "keyboard.insertText" ["text",str "literal"]] in
  (match insertion.steps with
   | [step] -> check bool "insertText creates no down/up ownership or release proof" true
       (W.input_contract step.action=Contract.No_hold && not (W.holds_input step.action))
   | [] | _::_::_ -> fail "one requested insertion must remain one step");
  check bool "retained native data still round-trips without admission" true
    (W.of_json (W.to_json denied)=Ok denied)
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
let url_matchers () =
  let regex fields=step "waitForURL" ["urlRegex",obj fields] in
  let calls=[wait;regex ["source",str "^https://example\\.test/(done|ready)$";"flags",str "i"];
    regex ["source",str ""];regex ["source",str "done";"flags",str ""];
    regex ["source",str "done";"flags",str "gy"];regex ["source",str "[";"flags",str "ii"]] in
  let parsed=request calls in
  check bool "URL matcher data roundtrips without interpreting native syntax" true
    (ok (W.of_json (W.to_json parsed))=parsed);
  check bool "regex and glob URL waits remain read-only" true
    (List.for_all (fun (step : W.step) -> not (W.is_effect step.action || W.holds_input step.action)) parsed.steps);
  check bool "native optional flags distinguish omission from explicit empty flags" true
    (List.map (fun (step : W.step) -> step.action) parsed.steps =
      [W.Wait_for_url (W.Glob "**/done");
       W.Wait_for_url (W.Regexp {source="^https://example\\.test/(done|ready)$";flags=Some "i"});
       W.Wait_for_url (W.Regexp {source="";flags=None});
       W.Wait_for_url (W.Regexp {source="done";flags=Some ""});
       W.Wait_for_url (W.Regexp {source="done";flags=Some "gy"});
       W.Wait_for_url (W.Regexp {source="[";flags=Some "ii"})]);
  List.iter (fun value -> check bool "malformed or ambiguous URL matcher is refused" true
    (Result.is_error (W.of_json (obj (base [value])))))
    [step "waitForURL" [];step "waitForURL" ["url",str ""];
     step "waitForURL" ["url",str "**/done";"urlRegex",obj ["source",str "done"]];
     step "waitForURL" ["urlRegex",`Null];regex [];regex ["source",`Int 1];
     regex ["source",str "x";"flags",`Null];regex ["source",str "x";"source",str "y"];
     regex ["source",str "x";"flags",str "i";"flags",str "g"];
     regex ["source",str "x";"test",str "process.exit()"];
     step "goto" ["urlRegex",obj ["source",str "done"]];
     step "fetch" ["url",str "/data";"urlRegex",obj ["source",str "data"]]]
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
let validation_diagnostics () =
  let rejected label expected value = match W.of_json value with
    | Error message -> check string label expected message
    | Ok _ -> fail (label ^ ": invalid input was accepted") in
  rejected "an unknown key names the later step and its method"
    "native workflow step[2] (method \"fill\"): unknown fields: \"ref\""
    (obj (base [step "url" [];click;step "fill" ["ref",str "@4";"text",str "hello"]]));
  rejected "a field accepted by another method stays disallowed on fill"
    "native workflow step[1] (method \"fill\"): unknown fields: \"html\""
    (obj (base [step "title" [];step "fill" ["selector",str "#editor";"text",str "hello";"html",str "<b>hello</b>"]]));
  rejected "duplicate argument names do not choose a value"
    "native workflow step[1] (method \"fill\"): duplicate fields: \"selector\""
    (obj (base [step "title" [];step "fill" ["selector",str "#first";"selector",str "#second";"text",str "hello"]]));
  rejected "duplicate method names do not choose a diagnostic method"
    "native workflow step[0]: duplicate fields: \"method\""
    (obj (base [step "url" ["method",str "title"]]));
  rejected "workflow keys are distinguished from step keys and both problems are retained"
    "native workflow: unknown fields: \"ref\"; duplicate fields: \"maxChars\""
    (obj (("ref",str "@4")::("maxChars",`Int 20)::base []));
  rejected "native option key errors retain their step and method"
    "native workflow step[1] (method \"fill\"): unknown fields: \"delay\""
    (obj (base [step "title" [];step "fill" ["selector",str "#editor";"text",str "hello";
      "options",obj ["delay",`Int 0]] ]));
  let valid=request [step "url" [];step "fill" ["selector",str "@4";"text",str "hello";
    "options",obj ["clearFirst",`Bool false;"timeout",`Int 0]]] in
  check bool "corrected input retains the same valid native roundtrip" true
    (W.of_json (W.to_json valid)=Ok valid)
let download_cancel () =
  let id="60c7683f-f552-4c01-a5cb-2d487bb62e5e" in
  let cancel=step "download.cancel" ["downloadId",str id] in
  let wanted=request [cancel] in
  check bool "cancellation round trip" true (W.of_json (W.to_json wanted)=Ok wanted);
  check bool "cancellation is an effect" true (W.is_effect (List.hd wanted.steps).action);
  check bool "cancellation does not press input" false (W.holds_input (List.hd wanted.steps).action);
  List.iter (fun fields -> refused "invalid Download cancellation refused before SDK"
    (W.of_json (obj (base [step "download.cancel" fields]))))
    [["downloadId",str "../other"];["downloadId",str "60C7683F-F552-4C01-A5CB-2D487BB62E5E"];
     ["downloadId",str id;"options",obj []];["downloadId",str id;"path",str "/tmp/file"];
     ["downloadId",str id;"downloadId",str id];[]];
  let receipt=obj ["downloadId",str id;"source",str "native_download";"cancelReturned",`Bool true] in
  let completed receipt=obj (snapshot @ result ~started:true ~completed_effect:true
    ~completed:[entry ~receipt 0 "download.cancel"] ~failure:`Null) in
  (match ok (R.decode ~windows:None wanted (completed receipt)) with
   | R.Completed {input=Rel.No_hold;_} -> ()
   | R.Completed {input=Rel.Released (Rel.Released_by_receipts _|Rel.Completed_by_evidence _);_}|R.Stopped _ -> fail "cancellation manufactured input release");
  List.iter (fun receipt -> refused "cancel receipt must bind exact native identity and return"
    (R.decode ~windows:None wanted (completed receipt)))
    [`Null;obj [];obj ["downloadId",str "foreign";"source",str "native_download";"cancelReturned",`Bool true];
     obj ["downloadId",str id;"source",str "fetch";"cancelReturned",`Bool true];
     obj ["downloadId",str id;"source",str "native_download";"cancelReturned",`Bool false];
     obj ["downloadId",str id;"source",str "native_download";"cancelReturned",`Bool true;"cancelled",`Bool true]];
  List.iter (fun (prior,steps,entries) ->
    let req=request (steps @ [cancel]) in
    let pre=obj (result ~started:prior ~completed_effect:prior ~completed:entries
      ~failure:(failure (List.length entries) "downloadPreflight")) in
    (match ok (R.decode ~windows:None req pre) with
     | R.Stopped {effect_started;completed_effect;input;_} ->
       check bool "preflight preserves prior effects" true (effect_started=prior && completed_effect=prior);
       check bool "preflight did not press input" true (seen_input input=`No_hold)
     | R.Completed _ -> fail "cancel preflight was called completed"))
    [false,[],[];true,[step "fill" ["selector",str "#editor";"text",str "changed"]],[entry 0 "fill"]];
  refused "download preflight must name a pending cancellation"
    (R.decode ~windows:None (request [click]) (obj (result ~started:false ~completed_effect:false ~completed:[]
      ~failure:(failure 0 "downloadPreflight"))));
  stopped "lost cancellation does not claim a pressed key" `No_hold
    (R.decode ~windows:None wanted (obj (result ~started:true ~completed_effect:false ~completed:[]
      ~failure:(failure 0 "download.cancel"))))
let complete () =
  let value=obj (snapshot @ result ~started:true ~completed_effect:true
    ~completed:[clicked 0;entry 1 "waitForURL"] ~failure:`Null) in
  match ok (R.decode ~windows:None (request [click;wait]) value) with
  | R.Completed {reply;input=Rel.Released (Rel.Released_by_receipts proven);_} ->
    check bool "native final URL and snapshot returned" true (reply=value);
    check (list int) "the click is the holding step the receipts prove" [0] proven
  | R.Completed {input=Rel.Released (Rel.Completed_by_evidence _);_}
      | R.Completed {input=Rel.No_hold;_} | R.Stopped _ -> fail "a complete sequence did not release its click"
let progress_and_uncertainty () =
  let assert_stopped request fields ~started ~completed_effect =
    match ok (R.decode ~windows:None request (obj fields)) with
    | R.Stopped observed ->
      check bool "started effect" started observed.effect_started;
      check bool "completed effect" completed_effect observed.completed_effect
    | R.Completed _ -> fail "failed sequence was called complete" in
  let press=step "press" ["selector",str "#editor";"key",str "Enter"] in
  assert_stopped (request [press])
    (result ~started:false ~completed_effect:false ~completed:[] ~failure:(failure 0 "inputPreflight"))
    ~started:false ~completed_effect:false;
  assert_stopped (request [click;press])
    (result ~started:true ~completed_effect:true ~completed:[clicked 0] ~failure:(failure 1 "inputPreflight"))
    ~started:true ~completed_effect:true;
  assert_stopped (request [wait]) (result ~started:false ~completed_effect:false ~completed:[] ~failure:(failure 0 "waitForURL"))
    ~started:false ~completed_effect:false;
  assert_stopped (request [click]) (unreleased (result ~started:true ~completed_effect:false ~completed:[] ~failure:(failure 0 "click")))
    ~started:true ~completed_effect:false;
  assert_stopped (request [click;wait]) (result ~started:true ~completed_effect:true ~completed:[clicked 0] ~failure:(failure 1 "waitForURL"))
    ~started:true ~completed_effect:true;
  assert_stopped (request [step "keyboard.paste" ["text",str "x"]])
    (unreleased (result ~started:true ~completed_effect:false ~completed:[] ~failure:(failure 0 "keyboard.paste")))
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
    check bool "an observation cannot claim a press selector preflight" true
      (Result.is_error (R.decode ~windows:None expected (obj (result ~started:false ~completed_effect:false
        ~completed:[] ~failure:(failure 0 "inputPreflight")))));
    let consumes_events=method_="events" in
    let row=obj ["index",`Int 0;"method",str method_;"receipt",receipt] in
    (match ok (R.decode ~windows:None expected (obj (snapshot @ result ~started:consumes_events ~completed_effect:consumes_events
       ~completed:[row] ~failure:`Null))) with
     | R.Completed _ -> () | R.Stopped _ -> fail "native observation was stopped");
    let bad=if receipt=`Null then str "not void" else `Null in
    let row=obj ["index",`Int 0;"method",str method_;"receipt",bad] in
    check bool "native observation receipt shape is checked" true
      (Result.is_error (R.decode ~windows:None expected (obj (snapshot @ result ~started:consumes_events ~completed_effect:consumes_events
        ~completed:[row] ~failure:`Null))))) methods
let fetch_save_inputs () =
  List.iter (fun name ->
    let parsed=request [step "fetch" ["url",str "/binary";"options",obj ["saveAs",str name]]] in
    check bool "safe requested filenames roundtrip as artifact metadata" true
      (ok (W.of_json (W.to_json parsed))=parsed);
    match parsed.steps with
    | [step] -> check (option string) "fetch save name belongs to the requested step" (Some name) (W.fetch_save_name step)
    | []|_::_::_ -> fail "expected one fetch")
    ["report.bin";"한글 😀.pdf";"notes..txt";".hidden";"a b.dat"];
  List.iter (fun name ->
    check bool "unsafe save names never reach the native SDK" true
      (Result.is_error (W.of_json (obj (base [step "fetch" ["url",str "/binary";
        "options",obj ["saveAs",str name]]])))))
    ["";" ";".";"..";"a/b";"a\\b";"\000";"a\nb";"a\rb";"a\tb";"a\127b"]
let fetch_save_receipts () =
  let name="binary report.bin" in
  let expected=request [step "fetch" ["url",str "/binary";"options",obj ["saveAs",str name]]] in
  let id="00000000-0000-4000-8000-000000000001" in
  let fields=["ok",`Bool true;"status",`Int 200;"statusText",str "OK";
    "url",str "https://example.test/binary";"headers",obj ["content-type",str "application/octet-stream"];
    "downloadId",str id;"suggestedFilename",str name;"source",str "fetch"] in
  let replace key value fields=(key,value)::List.remove_assoc key fields in
  let decode fields = R.decode ~windows:None expected (obj (snapshot @ result ~started:true ~completed_effect:true
    ~completed:[obj ["index",`Int 0;"method",str "fetch";"receipt",obj fields]] ~failure:`Null)) in
  List.iter (fun fields ->
    match ok (decode fields) with R.Completed _ -> () | R.Stopped _ -> fail "a native saved response was stopped")
    [fields;fields |> replace "ok" (`Bool false) |> replace "status" (`Int 404) |> replace "statusText" (str "Not Found");
     fields |> replace "ok" (`Bool false) |> replace "status" (`Int 0) |> replace "statusText" (str "") |> replace "url" (str "")];
  List.iter (fun forged -> check bool "saved receipt binds exact metadata, UUID, filename and provenance" true
    (Result.is_error (decode forged)))
    [replace "suggestedFilename" (str "other.bin") fields;
     replace "downloadId" (str "not-a-uuid") fields;
     replace "downloadId" (str "00000000-0000-4000-8000-00000000000A") fields;
     replace "source" (str "native_download") fields;
     replace "ok" (str "true") fields;
     replace "status" (str "200") fields;
     replace "statusText" `Null fields;
     replace "url" `Null fields;
     replace "headers" (obj ["x-test",`Int 3]) fields;
     ("savedPath",str "/private/file")::fields;
     ("downloadId",str id)::fields;
     List.remove_assoc "source" fields;
     List.remove_assoc "headers" fields]
let evaluation_timeouts () =
  let expected=request [step "evaluate" ["source",str "window.slow()"];click] in
  let native=["code",str "EGO_PAGE_EVALUATION_TIMED_OUT";"timeoutMs",`Int 14000;
    "executionStopped",`Bool true;"mayHaveLateEffects",`Bool true;"pageResponsive",`Bool true] in
  let replace key value fields=(key,value)::List.remove_assoc key fields in
  let receipt ?(released=true) method_ native =
    obj (("inputReleased",`Bool released)::List.remove_assoc "inputReleased"
      (result ~started:true ~completed_effect:false ~completed:[]
        ~failure:(obj (["index",`Int 0;"method",str method_;"message",str "native timeout"] @ native)))) in
  let detail = function Some (R.Evaluation_timed_out value) -> value
    | None | Some (R.Navigation_timed_out _ | R.Popup_event_failed _ | R.Page_dialog_opened _) -> fail "native evaluation diagnostics are absent" in
  List.iter (fun fields ->
    let value=receipt "evaluate" ["nativeError",obj fields] in
    match ok (R.decode ~windows:None expected value) with
    | R.Stopped {receipt=retained;native_error;effect_started;completed_effect;input;_} ->
      let detail=detail native_error in
      check bool "evaluation effect started" true effect_started;
      check bool "failed evaluation is not completed" false completed_effect;
      check bool "evaluation held no input" true (seen_input input=`No_hold);
      check bool "original receipt is retained without rewriting native diagnostics" true (retained=value);
      check (float 0.) "native timeout milliseconds" 14000. detail.timeout_ms;
      check bool "native execution-stopped observation" (List.assoc "executionStopped" fields=`Bool true) detail.execution_stopped;
      check bool "native late effects remain possible" true detail.may_have_late_effects;
      check bool "native responsiveness observation" (List.assoc "pageResponsive" fields=`Bool true) detail.page_responsive
    | R.Completed _ -> fail "native evaluation timeout was marked complete")
    [native;replace "executionStopped" (`Bool false) native;
     native |> replace "executionStopped" (`Bool false) |> replace "pageResponsive" (`Bool false)];
  (match ok (R.decode ~windows:None expected (receipt "evaluate" ["nativeError",obj (replace "timeoutMs" (`Int 0) native)])) with
   | R.Stopped {native_error;_} -> check (float 0.) "native zero timeout retained" 0. (detail native_error).timeout_ms
   | R.Completed _ -> fail "native zero timeout was marked complete");
  (match ok (R.decode ~windows:None (request [click]) (receipt ~released:false "click" ["nativeError",obj native])) with
   | R.Stopped {input;native_error;_} ->
     check bool "native execution stopped" true (detail native_error).execution_stopped;
     check bool "executionStopped cannot clear held input" true (seen_input input=not_released 0 Rel.Never_returned)
   | R.Completed _ -> fail "failed held-input step was marked complete");
  (match ok (R.decode ~windows:None expected (receipt "evaluate" [])) with
   | R.Stopped {native_error=None;_} -> ()
   | R.Completed _|R.Stopped _ -> fail "ordinary failure acquired a native timeout");
  List.iter (fun fields ->
    check bool "invalid native timeout is an unknown receipt, never a default" true
      (Result.is_error (R.decode ~windows:None expected (receipt "evaluate" ["nativeError",obj fields]))))
    [replace "code" (str "other") native;replace "timeoutMs" (`Int (-1)) native;
     replace "timeoutMs" (`Float nan) native;replace "timeoutMs" (`Float infinity) native;
     replace "executionStopped" (str "true") native;replace "mayHaveLateEffects" `Null native;
     List.remove_assoc "pageResponsive" native;("code",str "EGO_PAGE_EVALUATION_TIMED_OUT")::native;
     ("unexpected",`Bool true)::native]
let navigation_timeouts () =
  let expected=request [step "goto" ["url",str "https://example.test/done"]] in
  let native=["code",str "EGO_NAVIGATION_TIMEOUT";"timeoutMs",`Int 5000;
    "committed",`Bool true;"waitUntil",str "load";
    "url",str "https://example.test/redirected";"readyState",str "interactive"] in
  let replace key value fields=(key,value)::List.remove_assoc key fields in
  let receipt fields=obj (result ~started:true ~completed_effect:false ~completed:[]
    ~failure:(obj ["index",`Int 0;"method",str "goto";"message",str "native navigation timeout";"nativeError",obj fields])) in
  List.iter (fun (wait,kind) ->
    List.iter (fun fields ->
      let value=receipt (replace "waitUntil" (str wait) fields) in
      match ok (R.decode ~windows:None expected value) with
      | R.Completed _ -> fail "native navigation timeout was marked complete"
      | R.Stopped {native_error;receipt=original;effect_started;completed_effect;input;_} ->
        let observed=match native_error with
          | Some (R.Navigation_timed_out value) -> value
          | None|Some (R.Evaluation_timed_out _ | R.Popup_event_failed _ | R.Page_dialog_opened _) -> fail "native navigation diagnostics are absent" in
        check bool "navigation diagnostics retain original receipt" true (original=value);
        check bool "committed is an observation" (List.assoc "committed" fields=`Bool true) observed.committed;
        check bool "requested lifecycle is preserved" true (observed.wait_until=kind);
        check (float 0.) "native timeout retained" 5000. observed.timeout_ms;
        let optional key=match List.assoc_opt key fields with Some (`String value)->Some value|_->None in
        check (option string) "native URL observation" (optional "url") observed.url;
        check (option string) "native document readiness" (optional "readyState") observed.ready_state;
        check bool "committed false never proves no effect started" true effect_started;
        check bool "committed true never completes the failed request" false completed_effect;
        check bool "diagnostics do not manufacture input evidence" true (seen_input input=`No_hold))
      [native;replace "committed" (`Bool false) (native |> List.remove_assoc "url" |> List.remove_assoc "readyState");
       native |> replace "url" (str "") |> replace "readyState" (str "")])
    ["commit",R.Commit;"domcontentloaded",R.Dom_content_loaded;"load",R.Load;"networkidle",R.Network_idle];
  List.iter (fun fields -> check bool "malformed navigation observations are not defaulted" true
    (Result.is_error (R.decode ~windows:None expected (receipt fields))))
    [replace "committed" (str "true") native;replace "waitUntil" (str "ready") native;
     replace "url" `Null native;replace "readyState" (`Int 1) native;
     replace "timeoutMs" (`Int (-1)) native;replace "timeoutMs" (`Float nan) native;
     List.remove_assoc "waitUntil" native;("committed",`Bool false)::native;
     ("executionStopped",`Bool true)::native]
let malformed_receipts () =
  let expected=request [click;wait] in
  List.iter (fun value -> check bool "incomplete/mismatched execution is not success" true (Result.is_error (R.decode ~windows:None expected value)))
    [`Null;
     obj (result ~started:false ~completed_effect:false ~completed:[] ~failure:(failure 0 "inputPreflight"));
     obj (result ~started:true ~completed_effect:true ~completed:[clicked 0;entry 1 "waitForURL"] ~failure:`Null);
     obj (snapshot @ result ~started:true ~completed_effect:true ~completed:[clicked 0] ~failure:`Null);
     obj (snapshot @ result ~started:true ~completed_effect:true ~completed:[entry 0 "waitForURL";clicked 1] ~failure:`Null);
     obj (snapshot @ result ~started:false ~completed_effect:false ~completed:[clicked 0;entry 1 "waitForURL"] ~failure:`Null)]
let pointer_release () =
  let drag=step "dragAndDrop" ["selector",str "#source";"destination",str "#target"] in
  let fields=result ~started:true ~completed_effect:false ~completed:[] ~failure:(failure 0 "dragAndDrop") in
  let fields=("inputReleased",`Bool false)::List.remove_assoc "inputReleased" fields in
  stopped "lost release was called confirmed" (not_released 0 Rel.Never_returned) (R.decode ~windows:None (request [drag;click]) (obj fields));
  let paste_fields=("failure",failure 0 "keyboard.paste")::List.remove_assoc "failure" fields in
  stopped "paste lost its modifier release uncertainty" (not_released 0 Rel.Never_returned)
    (R.decode ~windows:None (request [step "keyboard.paste" ["text",str "x"]]) (obj paste_fields))
let holding=["dragAndDrop",["selector",str "#source";"destination",str "#target"];
  "click",["selector",str "#source"];"dblclick",["selector",str "#source"];
  "mouse.click",["x",`Int 10;"y",`Int 20];
  "press",["selector",str "#editor";"key",str "Enter"];
  "keyboard.press",["key",str "Enter"];"keyboard.paste",["text",str "x"]]
let release_needs_receipt_evidence () =
  List.iter (fun (method_,args) ->
    let expected=request [step method_ args;wait] in
    check bool (method_ ^ " holds input") true
      (match expected.W.steps with first::_ -> W.holds_input first.W.action | [] -> false);
    let success ?(released=true) receipt=
      let fields=result ~started:true ~completed_effect:true ~failure:`Null
        ~completed:[entry ~receipt 0 method_;entry 1 "waitForURL"] in
      R.decode ~windows:None expected (obj (snapshot @ with_claim released fields)) in
    List.iter (fun receipt -> match ok (success receipt) with
      | R.Completed {input=Rel.Released (Rel.Released_by_receipts proven);_} ->
        check (list int) (method_ ^ ": the receipt proves its holding step") [0] proven
      | R.Completed {input=Rel.Released (Rel.Completed_by_evidence _);_}
      | R.Completed {input=Rel.No_hold;_} -> fail (method_ ^ ": the holding step was not counted")
      | R.Stopped _ -> fail (method_ ^ ": an object receipt without a dialog was stopped"))
      declared_clean;
    List.iter (fun (receipt,_) -> refused (method_ ^ ": a release claim needs an object receipt without a dialog")
      (success receipt)) undeclared;
    refused (method_ ^ ": a success that denies the release is not complete") (success ~released:false (obj []))) holding
let release_claim_on_stopped_replies () =
  List.iter (fun (method_,args) ->
    let alone=request [step method_ args] and then_wait=request [step method_ args;wait] in
    let never_returned=result ~started:true ~completed_effect:false ~completed:[] ~failure:(failure 0 method_) in
    refused (method_ ^ ": a step that never returned cannot report release") (R.decode ~windows:None alone (obj never_returned));
    stopped (method_ ^ ": a step that never returned reports a held input") (not_released 0 Rel.Never_returned)
      (R.decode ~windows:None alone (obj (unreleased never_returned)));
    let failed_later receipt=result ~started:true ~completed_effect:true ~failure:(failure 1 "waitForURL")
      ~completed:[entry ~receipt 0 method_] in
    let snapshot_failed receipt=result ~started:true ~completed_effect:true ~failure:(failure 1 "snapshot")
      ~completed:[entry ~receipt 0 method_] in
    List.iter (fun (label,decode,fields) ->
      stopped (method_ ^ ": " ^ label ^ " with a receipt that shows release") (`Released [0])
        (decode (obj (fields (obj []))));
      stopped (method_ ^ ": " ^ label ^ " may report a held input despite its receipt") (`Unconfirmed Rel.Held_by_script_report)
        (decode (obj (with_claim false (fields (obj [])))));
      List.iter (fun (receipt,answer) ->
        refused (method_ ^ ": " ^ label ^ " cannot report release without evidence") (decode (obj (fields receipt)));
        stopped (method_ ^ ": " ^ label ^ " without evidence reports a held input") (not_released 0 answer)
          (decode (obj (with_claim false (fields receipt)))))
        undeclared)
      ["a later failure",R.decode ~windows:None then_wait,failed_later;"a failed snapshot",R.decode ~windows:None alone,snapshot_failed]) holding
let release_across_several_holding_steps () =
  let two=request [click;click] and hover_first=request [step "hover" ["selector",str "@3"];click] in
  let both first second=result ~started:true ~completed_effect:true ~failure:`Null
    ~completed:[entry ~receipt:first 0 "click";entry ~receipt:second 1 "click"] in
  (match ok (R.decode ~windows:None two (obj (snapshot @ both (obj []) (obj [])))) with
   | R.Completed {input=Rel.Released (Rel.Released_by_receipts proven);_} -> check (list int) "both holding steps are proven" [0;1] proven
   | R.Completed {input=Rel.Released (Rel.Completed_by_evidence _);_}
      | R.Completed {input=Rel.No_hold;_} | R.Stopped _ -> fail "two proven holding steps were not released");
  refused "a proven last step does not hide an unproven first one" (R.decode ~windows:None two (obj (snapshot @ both `Null (obj []))));
  refused "a proven first step does not hide an unproven last one" (R.decode ~windows:None two (obj (snapshot @ both (obj []) `Null)));
  let first_unproven fields=result ~started:true ~completed_effect:true ~failure:(failure 2 "waitForURL") ~completed:fields in
  stopped "the first unreleased holding step is the one named" (not_released 0 Rel.Void_answer)
    (R.decode ~windows:None (request [click;click;wait]) (obj (unreleased (first_unproven
      [entry ~receipt:`Null 0 "click";entry ~receipt:(str "ok") 1 "click"]))));
  stopped "a later unreleased holding step is named when the first is proven" (not_released 1 Rel.Undeclared_answer)
    (R.decode ~windows:None (request [click;click;wait]) (obj (unreleased (first_unproven
      [clicked 0;entry ~receipt:(str "ok") 1 "click"]))));
  (match ok (R.decode ~windows:None hover_first (obj (snapshot @ result ~started:true ~completed_effect:true ~failure:`Null
      ~completed:[entry 0 "hover";clicked 1]))) with
   | R.Completed {input=Rel.Released (Rel.Released_by_receipts proven);_} ->
     check (list int) "a non-holding step is not listed as proven" [1] proven
   | R.Completed {input=Rel.Released (Rel.Completed_by_evidence _);_}
      | R.Completed {input=Rel.No_hold;_} | R.Stopped _ -> fail "a hover followed by a proven click was not released");
  let void_then_failed=result ~started:true ~completed_effect:true ~completed:[entry ~receipt:`Null 0 "click"] ~failure:(failure 1 "click") in
  stopped "the earlier unreleased step is named before a later failed one" (not_released 0 Rel.Void_answer)
    (R.decode ~windows:None two (obj (unreleased void_then_failed)));
  let second_never_returned=result ~started:true ~completed_effect:true ~completed:[clicked 0] ~failure:(failure 1 "click") in
  refused "a later holding step that never returned cannot report release" (R.decode ~windows:None two (obj second_never_returned));
  stopped "a later holding step that never returned reports a held input" (not_released 1 Rel.Never_returned)
    (R.decode ~windows:None two (obj (unreleased second_never_returned)));
  let after_hover=result ~started:true ~completed_effect:true ~completed:[entry 0 "hover"] ~failure:(failure 1 "click") in
  refused "a holding step after a non-holding one cannot report release unreturned" (R.decode ~windows:None hover_first (obj after_hover));
  stopped "a holding step after a non-holding one reports a held input" (not_released 1 Rel.Never_returned)
    (R.decode ~windows:None hover_first (obj (unreleased after_hover)))
let a_dialog_left_on_a_holding_step_is_unproven () =
  let named index method_=obj ["index",`Int index;"method",str method_;"message",str "answer";
    "dialog",obj ["type",str "alert";"message",str "m"]] in
  let on_click=result ~started:true ~completed_effect:true ~completed:[clicked 0] ~failure:(named 0 "click") in
  refused "a dialog reported on a holding step cannot sit beside a release claim" (R.decode ~windows:None (request [click]) (obj on_click));
  refused "a failure on a step that already returned needs a dialog to explain it"
    (R.decode ~windows:None (request [click]) (obj (unreleased (result ~started:true ~completed_effect:true ~completed:[clicked 0]
      ~failure:(failure 0 "click")))));
  stopped "a dialog reported on a holding step reports a held input" (not_released 0 Rel.Receipt_with_dialog)
    (R.decode ~windows:None (request [click]) (obj (unreleased on_click)));
  let on_insert=result ~started:true ~completed_effect:true ~failure:(named 1 "keyboard.insertText")
    ~completed:[clicked 0;entry 1 "keyboard.insertText"] in
  stopped "a dialog on a later non-holding step leaves the earlier release proven" (`Released [0])
    (R.decode ~windows:None (request [click;step "keyboard.insertText" ["text",str "x"]]) (obj on_insert))
let a_held_claim_needs_a_holding_effect () =
  let fill=step "fill" ["selector",str "#editor";"text",str "x"] in
  let failed_fill=result ~started:true ~completed_effect:false ~completed:[] ~failure:(failure 0 "fill") in
  refused "a request with no holding step cannot hold input" (R.decode ~windows:None (request [fill]) (obj (unreleased failed_fill)));
  let initial=result ~started:false ~completed_effect:false ~completed:[] ~failure:(failure 0 "initialUrl") in
  refused "a holding step that started no effect cannot hold input" (R.decode ~windows:None (request [click]) (obj (unreleased initial)))
let an_initial_url_failure_holds_nothing () =
  let initial=result ~started:false ~completed_effect:false ~completed:[] ~failure:(failure 0 "initialUrl") in
  (match R.decode ~windows:None (request [click]) (obj initial) with
   | Ok (R.Stopped {effect_started;input;_}) ->
     check bool "an unreadable starting URL starts no effect" false effect_started;
     check bool "an unreadable starting URL holds nothing" true (seen_input input=`No_hold)
   | Ok (R.Completed _) | Error _ -> fail "an unreadable starting URL did not stop before any input");
  refused "initialUrl only fails before the first step"
    (R.decode ~windows:None (request [click;click]) (obj (result ~started:true ~completed_effect:true ~completed:[clicked 0]
      ~failure:(failure 1 "initialUrl"))));
  refused "initialUrl only fails before any step completed"
    (R.decode ~windows:None (request [step "url" [];click]) (obj (result ~started:false ~completed_effect:false
      ~completed:[entry ~receipt:(str "https://example.test/start") 0 "url"] ~failure:(failure 0 "initialUrl"))))
let a_workflow_that_never_held_input_has_nothing_to_release () =
  let fill=step "fill" ["selector",str "#editor";"text",str "x"] in
  let first_fails=result ~started:true ~completed_effect:false ~completed:[] ~failure:(failure 0 "fill") in
  stopped "a failure before the holding step leaves nothing to release" `No_hold
    (R.decode ~windows:None (request [fill;click]) (obj first_fails));
  stopped "a held claim with no holding step entered is only the script's" (`Unconfirmed Rel.Held_by_script_report)
    (R.decode ~windows:None (request [fill;click]) (obj (unreleased first_fails)));
  (match ok (R.decode ~windows:None (request [step "url" []]) (obj (snapshot @ result ~started:false ~completed_effect:false
      ~completed:[entry ~receipt:(str "https://example.test/start") 0 "url"] ~failure:`Null))) with
   | R.Completed {input=Rel.No_hold;_} -> ()
   | R.Completed {input=Rel.Released (Rel.Released_by_receipts _|Rel.Completed_by_evidence _);_} | R.Stopped _ -> fail "a workflow with no holding step released something")
let release_is_judged_from_declared_answers () =
  check bool "an empty receipt is the declared answer that releases" true (kind_of clean=None);
  List.iter (fun receipt ->
    check bool "a declared receipt without a dialog is the answer that releases" true (kind_of (Rel.answer_of_json receipt)=None))
    declared_clean;
  List.iter (fun (receipt,kind) ->
    check bool "an SDK answer is read into the kind that withholds the release" true
      (kind_of (Rel.answer_of_json receipt)=Some kind))
    undeclared;
  check bool "no holding step leaves nothing to release" true (seen_input (Rel.judge [])=`No_hold);
  check bool "clean answers release and list their steps" true (seen_input (Rel.judge [0,clean;2,clean])=`Released [0;2]);
  List.iter (fun kind ->
    let answer=Rel.of_unreleased kind in
    check bool "the first answer that does not release is named" true
      (seen_input (Rel.judge [0,clean;1,answer;2,Rel.of_unreleased Rel.Receipt_with_dialog])=not_released 1 kind);
    check bool "one unreleased answer withholds the release" true
      (seen_input (Rel.judge [0,answer])=not_released 0 kind))
    [Rel.Receipt_with_dialog;Rel.Void_answer;Rel.Undeclared_answer;Rel.Never_returned]
(* An SDK error is a refusal before the press only when its declared name and kind say so. *)
let a_refusal_before_the_press_holds_nothing () =
  let refusal kind = obj ["name",str "ElementResolutionError";"kind",str kind] in
  let refused gesture value = match Rel.answer_of_refusal gesture value with
    | Rel.Refused_before_press resolution -> Some resolution
    | Rel.Receipt_without_dialog | Rel.Native_window_tail _ | Rel.Unreleased _ -> None in
  List.iter (fun gesture ->
    check bool "a permanent target refusal is read" true (refused gesture (refusal "permanent")=Some Rel.Permanent);
    check bool "a transient target refusal is read" true (refused gesture (refusal "transient")=Some Rel.Transient))
    [Rel.Click;Rel.Double_click;Rel.Drag_and_drop];
  List.iter (fun (label,value) ->
    check bool (label ^ " is no answer") true
      (Rel.answer_of_refusal Rel.Click value=Rel.of_unreleased Rel.Never_returned))
    ["another error name",obj ["name",str "TimeoutError";"kind",str "transient"];
     "an undeclared kind",obj ["name",str "ElementResolutionError";"kind",str "fatal"];
     "a missing kind",obj ["name",str "ElementResolutionError";"kind",`Null];
     "an extra member",obj ["name",str "ElementResolutionError";"kind",str "permanent";"message",str "x"];
     "a repeated member",`Assoc ["name",str "ElementResolutionError";"name",str "ElementResolutionError"];
     "no error object",`Null];
  let permanent=Rel.answer_of_refusal Rel.Click (refusal "permanent") in
  check bool "a lone refusal leaves nothing to release" true (seen_input (Rel.judge [0,permanent])=`No_hold);
  check bool "a refusal adds no evidence beside released steps" true
    (seen_input (Rel.judge [0,clean;1,permanent])=`Released [0]);
  check bool "a refusal does not hide a later unreleased step" true
    (seen_input (Rel.judge [0,permanent;1,Rel.of_unreleased Rel.Void_answer])=not_released 1 Rel.Void_answer);
  check bool "a refusal beside a receipt for the same step is contradictory" true
    (seen_input (Rel.judge [0,permanent;0,clean])=not_released 0 Rel.Conflicting_evidence);
  check bool "a receipt beside a refusal for the same step is contradictory" true
    (seen_input (Rel.judge [0,clean;0,permanent])=not_released 0 Rel.Conflicting_evidence)
(* The workflow script marks a holding step held before calling it; the judge reads the thrown error. *)
let a_workflow_step_refused_before_its_press_holds_nothing () =
  let module U=Yojson.Safe.Util in
  let thrown name kind = obj ["name",str name;"kind",str kind] in
  let failed index method_ value =
    obj ["index",`Int index;"method",str method_;"message",str "Locator matched 8 elements";"thrown",value] in
  let stopped_alone method_ value = obj (unreleased (result ~started:true ~completed_effect:false ~completed:[]
    ~failure:(failed 0 method_ value))) in
  List.iter (fun (method_,args) ->
    let alone=request [step method_ args] in
    (match R.decode ~windows:None alone (stopped_alone method_ (thrown "ElementResolutionError" "permanent")) with
     | Ok (R.Stopped {input;receipt;refused_before_press;_}) ->
       check bool (method_ ^ ": a refused step leaves nothing to release") true (seen_input input=`No_hold);
       check bool (method_ ^ ": the refusal is typed on the outcome") true (refused_before_press=Some Rel.Permanent);
       let failure=U.member "failure" receipt in
       check string (method_ ^ ": the SDK kind is public") "permanent"
         (U.to_string (U.member "kind" (U.member "refusedBeforePress" failure)));
       check bool (method_ ^ ": the raw thrown error is not public") true (U.member "thrown" failure=`Null)
     | Ok (R.Completed _) -> fail (method_ ^ ": a refused step was called complete")
     | Error message -> fail (method_ ^ ": " ^ message));
    stopped (method_ ^ ": a refusal after a released click keeps that release") (`Released [0])
      (R.decode ~windows:None (request [click;step method_ args])
         (obj (unreleased (result ~started:true ~completed_effect:true ~completed:[clicked 0]
            ~failure:(failed 1 method_ (thrown "ElementResolutionError" "transient"))))));
    stopped (method_ ^ ": another SDK error stays held") (not_released 0 Rel.Never_returned)
      (R.decode ~windows:None alone (stopped_alone method_ (thrown "TimeoutError" "transient"))))
    ["click",["selector",str "#source"];"dblclick",["selector",str "#source"];
     "dragAndDrop",["selector",str "#source";"destination",str "#target"]];
  let identity=obj ["spaceId",`Int 51;"label",str "p1";"targetId",str "T1";"openedBy",str "agent"] in
  let popup=step "clickAndWaitForPopup" ["selector",str "a[target=_blank]";"popupOptions",obj ["timeout",`Int 0]] in
  (match R.decode ~windows:None (request [popup;step "fill" ["selector",str "input";"text",str "child"]])
      (obj (("pages",obj ["source",identity;"current",identity;"transitions",`List []])
        ::unreleased (result ~started:true ~completed_effect:false ~completed:[]
          ~failure:(failed 0 "clickAndWaitForPopup" (thrown "ElementResolutionError" "transient"))))) with
   | Ok (R.Stopped {input;refused_before_press;_}) ->
     check bool "a refused popup trigger leaves nothing to release" true (seen_input input=`No_hold);
     check bool "a refused popup trigger is typed on the outcome" true (refused_before_press=Some Rel.Transient)
   | Ok (R.Completed _) -> fail "a refused popup trigger was called complete"
   | Error message -> fail ("refused popup trigger: " ^ message));
  List.iter (fun (method_,args) ->
    stopped (method_ ^ ": the same SDK error does not release this step") (not_released 0 Rel.Never_returned)
      (R.decode ~windows:None (request [step method_ args])
         (stopped_alone method_ (thrown "ElementResolutionError" "permanent"))))
    ["press",["selector",str "#editor";"key",str "Enter"];"mouse.click",["x",`Int 10;"y",`Int 20]]
(* A failed step can be reported twice: by its receipt and by the failure label that names a dialog. *)
let a_step_answered_twice_counts_once () =
  let dialog=Rel.of_unreleased Rel.Receipt_with_dialog in
  check bool "the same clean answer twice lists the step once" true
    (seen_input (Rel.judge [0,clean;0,clean])=`Released [0]);
  check bool "a dialog after a clean answer withholds the release" true
    (seen_input (Rel.judge [0,clean;0,dialog])=not_released 0 Rel.Receipt_with_dialog);
  check bool "a clean answer after a dialog does not undo it" true
    (seen_input (Rel.judge [0,dialog;0,clean])=not_released 0 Rel.Receipt_with_dialog);
  check bool "a repeated step keeps its first place" true
    (seen_input (Rel.judge [0,clean;1,clean;0,clean])=`Released [0;1])
(* A failure label is only believed at the position where the request can fail with it. *)
let a_failure_label_must_match_its_position () =
  let two=request [click;wait] and three=request [click;click;wait] in
  let named index method_=obj ["index",`Int index;"method",str method_;"message",str "answer";
    "dialog",obj ["type",str "alert";"message",str "m"]] in
  List.iter (fun claim ->
    let shown fields=obj (with_claim claim fields) in
    refused "a snapshot failure while steps remain is not a step failure"
      (R.decode ~windows:None two (shown (result ~started:true ~completed_effect:true ~completed:[clicked 0] ~failure:(failure 1 "snapshot"))));
    refused "an observation failure before any step completed is not a step failure"
      (R.decode ~windows:None two (shown (result ~started:false ~completed_effect:false ~completed:[] ~failure:(failure 0 "observation"))));
    refused "a dialog on a step that is not the last completed one does not explain the failure"
      (R.decode ~windows:None three (shown (result ~started:true ~completed_effect:true ~completed:[clicked 0;clicked 1] ~failure:(named 0 "click")))))
    [true;false]
let proof path =
  let json=Yojson.Safe.from_file path in
  let request=ok (W.of_json (Yojson.Safe.Util.member "request" json)) in
  (match ok (R.decode ~windows:None request (Yojson.Safe.Util.member "result" json)) with
   | R.Completed _ -> print_endline "Real Ego receipt decoded against its exact request"
   | R.Stopped _ -> fail "real browser fixture did not complete")
let page_proof path =
  proof path;
  let json=Yojson.Safe.from_file path in
  List.iter (fun (request_key,result_key) ->
    let request=ok (W.of_json (Yojson.Safe.Util.member request_key json)) in
    match ok (R.decode ~windows:None request (Yojson.Safe.Util.member result_key json)) with
    | R.Stopped {effect_started=true;completed_effect=false;_} -> ()
    | R.Completed _ | R.Stopped _ -> fail "a failed Page call lost its uncertain-effect boundary")
    ["blockedRequest","blocked";"timeoutRequest","timedOut"];
  print_endline "Real CORS and predicate-timeout receipts retain uncertain effects and exact progress"
let popup_progress () =
  let popup=step "clickAndWaitForPopup" ["selector",str "a[target=_blank]";"popupOptions",obj ["timeout",`Int 0]] in
  let wanted=request [popup;step "fill" ["selector",str "input";"text",str "child"]] in
  check bool "popup options retain native omission/zero without a new host budget" true
    (W.of_json (W.to_json wanted)=Ok wanted);
  List.iter (fun options -> refused "popup options are strict native event options"
    (W.of_json (obj (base [step "clickAndWaitForPopup" ["selector",str "a";"popupOptions",options]]))))
    [obj ["label",str "invented"];obj ["timeout",`Int (-1)];obj ["timeout",`Int 1;"timeout",`Int 2]];
  List.iter (fun key -> refused "internal source/receipt contracts cannot be supplied by callers"
    (W.of_json (obj ((key,obj [])::base [popup])))) ["expectedSourcePage";"inputReceiptContract"];
  let identity ?(space_id=51) label target=obj ["spaceId",`Int space_id;"label",str label;
    "targetId",str target;"openedBy",str "agent"] in
  let source=identity "p1" "T1" and child=identity "p2" "T2" in
  let transition ?(popup=child) selected=obj ["index",`Int 0;"source",source;"popup",popup;"selected",`Bool selected] in
  let pages current transitions=obj ["source",source;"current",current;"transitions",`List transitions] in
  let completed=obj (("pages",pages child [transition true])::snapshot @
    result ~started:true ~completed_effect:true ~completed:[entry ~receipt:(obj []) 0 "clickAndWaitForPopup";entry 1 "fill"] ~failure:`Null) in
  (match ok (R.decode ~windows:None wanted completed) with
   | R.Completed {pages=Some pages;input=Rel.Released (Rel.Released_by_receipts proven);_} ->
     check string "final Page is the child" "p2" pages.current.label;
     check string "opener identity is retained" "p1" pages.source.label;
     check (list int) "native trigger receipt alone proves its input release" [0] proven
   | R.Completed {input=Rel.Released (Rel.Completed_by_evidence _);_}
   | R.Completed {pages=None;input=Rel.Released (Rel.Released_by_receipts _);_}
   | R.Completed {input=Rel.No_hold;_}|R.Stopped _ -> fail "popup completion lost its typed Page/input observations");
  let pending_reply receipt released = obj (("pages",pages source [])::
    ("pendingAction",obj ["index",`Int 0;"method",str "clickAndWaitForPopup";"receipt",receipt])::
    with_claim released (result ~started:true ~completed_effect:true ~completed:[]
      ~failure:(obj ["index",`Int 0;"method",str "popupWait";"message",str "native wait failed";
        "eventError",obj ["name",str "TimeoutError";"code",str "native-code";"timeoutMs",`Int 9]]))) in
  (match ok (R.decode ~windows:None wanted (pending_reply (obj []) true)) with
   | R.Stopped {completed_effect=true;input;native_error=Some (R.Popup_event_failed error);_} ->
     check bool "a failed popup wait retains the returned trigger and release proof" true (seen_input input=`Released [0]);
     check bool "native event diagnostics are data, not fabricated Page success" true
       (error.code=Some "native-code" && error.timeout_ms=Some 9.)
   | R.Stopped {native_error=None|Some (R.Evaluation_timed_out _|R.Navigation_timed_out _|R.Page_dialog_opened _);_}
   | R.Stopped {completed_effect=false;native_error=Some (R.Popup_event_failed _);_}
   | R.Completed _ -> fail "pending popup click was erased or called completed");
  stopped "void trigger never manufactures key release" (not_released 0 Rel.Void_answer)
    (R.decode ~windows:None wanted (pending_reply `Null false));
  List.iter (fun value -> refused "foreign/missing/inconsistent Page transitions are refused"
    (R.decode ~windows:None wanted value))
    [obj (snapshot @ result ~started:true ~completed_effect:true
      ~completed:[entry ~receipt:(obj []) 0 "clickAndWaitForPopup";entry 1 "fill"] ~failure:`Null);
     obj (("pages",pages child [transition ~popup:(identity ~space_id:52 "p2" "T2") true])::snapshot @
       result ~started:true ~completed_effect:true ~completed:[entry ~receipt:(obj []) 0 "clickAndWaitForPopup";entry 1 "fill"] ~failure:`Null);
     obj (("pages",pages child [transition false])::snapshot @
       result ~started:true ~completed_effect:true ~completed:[entry ~receipt:(obj []) 0 "clickAndWaitForPopup";entry 1 "fill"] ~failure:`Null)]

let native_window_workflow () =
  let module Raw=Masc.Browser_ego_raw_type in
  let module Window=Masc.Browser_ego_native_window in
  let source:Window.page={space_id=51;native={Masc.Browser_surface.label=Some "p1";
    target_id="T1";opened_by=Masc.Browser_surface.Agent_created}} in
  let context=ok (Raw.prepare ~command_id:"actual-workflow-command" ~generation:"actual-pending-generation"
    ~source ~indices:[0;1;2]) in
  let directory=Filename.temp_dir ~perms:0o700 "masc-workflow-window-" "" in
  Fun.protect ~finally:(fun () ->
    Array.iter (fun name -> Sys.remove (Filename.concat directory name)) (Sys.readdir directory);
    Unix.rmdir directory) (fun () ->
    let arguments=Filename.concat directory "arguments.json" and outputs=Filename.concat directory "outputs.json" in
    Yojson.Safe.to_file arguments (obj ["source",obj (("spaceId",`Int source.space_id)
      ::Masc.Browser_surface.ego_page_fields source.native);"windows",Raw.arguments context;
      "receiptContract",Rel.receipt_contract]);
    let pid=Unix.create_process "node" [|"node";"test_browser_ego_workflow_window.cjs";arguments;outputs|]
      Unix.stdin Unix.stdout Unix.stderr in
    let _,status=Unix.waitpid [] pid in
    (match status with Unix.WEXITED 0 -> ()
     | WEXITED _|WSIGNALED _|WSTOPPED _ -> fail "combined native transport stand-in failed");
    let open Yojson.Safe.Util in
    let cases=Yojson.Safe.from_file outputs |> to_list in
    check int "all combined producer/consumer scenarios returned" 15 (List.length cases);
    let contains text fragment =
      let n=String.length fragment in
      let rec loop offset=offset+n<=String.length text &&
        (String.sub text offset n=fragment || loop (offset+1)) in loop 0 in
    List.iter (fun row ->
      let mode=member "mode" row |> to_string in
      let request=member "request" row |> W.of_json |> ok in
      let original=member "result" row in
      let decoded=ok (R.decode ~windows:(Some context) request original) in
      let public,input=match decoded with
        | R.Completed {reply;input;_} ->
          check bool "only fully completed workflows are success" true
            (List.mem mode ["normal";"popup";"two-raw"]);
          reply,Rel.Settled input
        | R.Stopped {receipt;input;effect_started;_} ->
          check bool "every native interruption stops the workflow" false
            (List.mem mode ["normal";"popup";"two-raw"]);
          check bool "invoked native setup never claims a wholly effect-free command" true effect_started;
          receipt,input in
      let public_text=Yojson.Safe.to_string public in
      List.iter (fun private_field -> check bool (mode ^ " hides " ^ private_field) false
        (contains public_text private_field))
        ["PRIVATE_WORKFLOW_NATIVE_HEADER_SENTINEL";"nativeInputWindow";"worldName";"bindingName";"nonce"];
      (match mode with
       | "normal"|"popup"|"two-raw"|"cleanup"|"cleanup-dialog"|"cleanup-malformed"|"info"|"snapshot" ->
         (match input with
          | Rel.Settled (Released proof) ->
            check int "every returned raw tail remains distinct verified evidence"
              (if mode="two-raw" then 2 else 1) (List.length (Rel.window_bindings proof))
          | Rel.Settled No_hold|Rel.Unconfirmed _ -> fail (mode ^ " lost verified native completion"))
       | "pre-raw" -> check bool "no holding step entered" true (seen_input input=`No_hold)
       | "start-dialog" -> check bool "real SDK failure before raw call holds nothing" true (seen_input input=`No_hold)
       | "prefix-pre-raw" -> check bool "earlier holding receipt is retained, not rolled back" true
           (seen_input input=`Released [0])
       | "dialog" -> check bool "swallowed dialog leaves raw input uncertain" true
           (seen_input input=not_released 0 (Rel.Native_window_unconfirmed Window.Dialog_opened))
       | "native-dialog" -> check bool "real thrown SDK failure during raw call remains uncertain" true
           (seen_input input=not_released 0 (Rel.Native_window_unconfirmed Window.Native_failure))
       | "missing-end" -> check bool "missing end cannot complete raw input" true
           (seen_input input=not_released 0 (Rel.Native_window_unconfirmed Window.Bounds_missing_or_duplicated))
       | "late-hold" -> check bool "later unreturned hold dominates earlier raw completion" true
           (seen_input input=not_released 1 Rel.Never_returned)
       | _ -> fail "unknown combined scenario");
      if List.mem mode ["native-dialog";"start-dialog";"cleanup-dialog"] then (
        match decoded with
        | R.Stopped {native_error=Some (R.Page_dialog_opened error);_} ->
          check string "actual native SDK session survives" "actual-error-session" error.session_id;
          check string "actual native SDK method survives"
            (if mode="start-dialog" then "Runtime.evaluate"
             else if mode="cleanup-dialog" then "Runtime.removeBinding" else "Input.dispatchKeyEvent") error.method_;
          check string "actual SDK dialog survives separately from native window uncertainty"
            "owned native dialog" error.dialog.message;
          check string "public typed native error remains present" "EGO_PAGE_DIALOG_OPENED"
            (public |> member "failure" |> member "nativeError" |> member "code" |> to_string)
        | R.Completed _|R.Stopped {native_error=None|Some (R.Evaluation_timed_out _|R.Navigation_timed_out _|R.Popup_event_failed _);_} ->
          fail "genuine thrown SDK diagnostic was erased");
      if mode="dialog" then check bool "swallowed void never manufactures an SDK exception" true
        (public |> member "failure" |> member "nativeError" = `Null);
      if mode="cleanup-malformed" then check bool "malformed cleanup-only diagnostic stays private" true
        (public |> member "failure" |> member "nativeError" = `Null);
      if List.mem mode ["cleanup";"cleanup-malformed"] then (
        let popup_request=ok (W.of_json (obj (base [step "keyboard.type" ["text",str "a"];
          step "clickAndWaitForPopup" ["selector",str "#popup"]]))) in
        let fields=to_assoc original in
        let pending=obj ["index",`Int 1;"method",str "clickAndWaitForPopup";"receipt",obj []] in
        refused "cleanup failure cannot include a later holding trigger"
          (R.decode ~windows:(Some context) popup_request (obj (("pendingAction",pending)::fields)));
        let pages=member "pages" original |> to_assoc in
        let source=List.assoc "source" pages in
        let popup=obj ["spaceId",`Int 51;"label",str "p2";"targetId",str "T2";"openedBy",str "agent"] in
        let transition=obj ["index",`Int 1;"source",source;"popup",popup;"selected",`Bool false] in
        let pages=obj (("transitions",`List [transition])::List.remove_assoc "transitions" pages) in
        refused "cleanup failure cannot include a later acquired popup"
          (R.decode ~windows:(Some context) popup_request
            (obj (("pages",pages)::List.remove_assoc "pages" fields))));
      if mode="normal" then (
        refused "raw progress cannot be authenticated without Host context" (R.decode ~windows:None request original);
        let fields=to_assoc original in
        let completed=member "completed" original |> to_list in
        let raw=List.hd completed |> to_assoc in
        let forged=obj (("receipt",obj [])::List.remove_assoc "receipt" raw) in
        refused "an object receipt cannot substitute for the raw SDK-tail window"
          (R.decode ~windows:(Some context) request
            (obj (("completed",`List (forged::List.tl completed))::List.remove_assoc "completed" fields))));
      if mode="popup" then (
        let fields=to_assoc original in let pages=member "pages" original |> to_assoc in
        let source=member "source" (member "pages" original) |> to_assoc in
        let pages=obj (("source",obj (("targetId",str "replacement")::List.remove_assoc "targetId" source))
          ::List.remove_assoc "source" pages) in
        refused "popup windows remain bound to original Host source"
          (R.decode ~windows:(Some context) request (obj (("pages",pages)::List.remove_assoc "pages" fields))))) cases)

let () = if Array.length Sys.argv=2 && Sys.argv.(1)="--receipt-contract" then
    print_endline (Yojson.Safe.to_string Rel.receipt_contract)
  else if Array.length Sys.argv=3 && Sys.argv.(1)="--proof" then proof Sys.argv.(2)
  else if Array.length Sys.argv=3 && Sys.argv.(1)="--page-proof" then page_proof Sys.argv.(2)
  else run "native_browser_workflow" ["SDK contract",[
  test_case "shared native producer and Host decoder stop unsafe followups" `Quick native_window_workflow;
  test_case "popup acquisition retains identity, partial trigger and input guarantees" `Quick popup_progress;
  test_case "raw typing admission requires its native-window contract" `Quick native_input_admission;
  test_case "native methods preserve values" `Quick roundtrip;
  test_case "Download cancellation binds identity and exact effect progress" `Quick download_cancel;
  test_case "URL matcher forms preserve native syntax and reject ambiguous input" `Quick url_matchers;
  test_case "invalid methods and fields are refused" `Quick strict_inputs;
  test_case "validation identifies the exact workflow or step fields before execution" `Quick validation_diagnostics;
  test_case "snapshot completes the exact requested sequence" `Quick complete;
  test_case "failed waits and uncertain effects retain progress" `Quick progress_and_uncertainty;
  test_case "native observations retain values and event-drain effects" `Quick observations;
  test_case "fetch save names are safe artifact metadata" `Quick fetch_save_inputs;
  test_case "saved fetch receipts bind exact artifact provenance" `Quick fetch_save_receipts;
  test_case "native evaluation timeout preserves diagnostics and uncertain effects" `Quick evaluation_timeouts;
  test_case "native navigation timeout preserves commit and lifecycle observations" `Quick navigation_timeouts;
  test_case "drag release is separate from effect completion" `Quick pointer_release;
  test_case "a release claim needs receipt evidence" `Quick release_needs_receipt_evidence;
  test_case "a stopped reply cannot report a release its receipts do not show" `Quick release_claim_on_stopped_replies;
  test_case "release is judged over every holding step" `Quick release_across_several_holding_steps;
  test_case "a dialog left on a holding step leaves its release unproven" `Quick a_dialog_left_on_a_holding_step_is_unproven;
  test_case "a held claim needs a holding effect" `Quick a_held_claim_needs_a_holding_effect;
  test_case "an initial URL failure holds nothing" `Quick an_initial_url_failure_holds_nothing;
  test_case "a workflow that never held input has nothing to release" `Quick a_workflow_that_never_held_input_has_nothing_to_release;
  test_case "release is judged from the answers the SDK declared" `Quick release_is_judged_from_declared_answers;
  test_case "a refusal before the press holds nothing" `Quick a_refusal_before_the_press_holds_nothing;
  test_case "a workflow step refused before its press holds nothing" `Quick a_workflow_step_refused_before_its_press_holds_nothing;
  test_case "a step answered twice counts once" `Quick a_step_answered_twice_counts_once;
  test_case "a failure label must match its position" `Quick a_failure_label_must_match_its_position;
  test_case "malformed execution never proves success" `Quick malformed_receipts]]
