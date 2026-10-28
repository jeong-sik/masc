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
(* The rule reads the SDK's answer, not the method. The real keyboard.type answer is void and so never
   releases; an object receipt for it is hypothetical and is judged like any other. *)
let seen_input = function
  | Rel.Settled (Rel.Released (Rel.Released_by_receipts proven)) -> `Released proven
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
let kind_of = function Rel.Receipt_without_dialog -> None | Rel.Unreleased kind -> Some kind
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
    ~completed:[clicked 0;entry 1 "waitForURL"] ~failure:`Null) in
  match ok (R.decode (request [click;wait]) value) with
  | R.Completed {reply;input=Rel.Released (Rel.Released_by_receipts proven)} ->
    check bool "native final URL and snapshot returned" true (reply=value);
    check (list int) "the click is the holding step the receipts prove" [0] proven
  | R.Completed {input=Rel.No_hold;_} | R.Stopped _ -> fail "a complete sequence did not release its click"
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
      (Result.is_error (R.decode expected (obj (result ~started:false ~completed_effect:false
        ~completed:[] ~failure:(failure 0 "inputPreflight")))));
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
  let decode fields = R.decode expected (obj (snapshot @ result ~started:true ~completed_effect:true
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
    | None -> fail "native evaluation diagnostics are absent" in
  List.iter (fun fields ->
    let value=receipt "evaluate" ["nativeError",obj fields] in
    match ok (R.decode expected value) with
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
  (match ok (R.decode expected (receipt "evaluate" ["nativeError",obj (replace "timeoutMs" (`Int 0) native)])) with
   | R.Stopped {native_error;_} -> check (float 0.) "native zero timeout retained" 0. (detail native_error).timeout_ms
   | R.Completed _ -> fail "native zero timeout was marked complete");
  (match ok (R.decode (request [click]) (receipt ~released:false "click" ["nativeError",obj native])) with
   | R.Stopped {input;native_error;_} ->
     check bool "native execution stopped" true (detail native_error).execution_stopped;
     check bool "executionStopped cannot clear held input" true (seen_input input=not_released 0 Rel.Never_returned)
   | R.Completed _ -> fail "failed held-input step was marked complete");
  (match ok (R.decode expected (receipt "evaluate" [])) with
   | R.Stopped {native_error=None;_} -> ()
   | R.Completed _|R.Stopped _ -> fail "ordinary failure acquired a native timeout");
  List.iter (fun fields ->
    check bool "invalid native timeout is an unknown receipt, never a default" true
      (Result.is_error (R.decode expected (receipt "evaluate" ["nativeError",obj fields]))))
    [replace "code" (str "other") native;replace "timeoutMs" (`Int (-1)) native;
     replace "timeoutMs" (`Float nan) native;replace "timeoutMs" (`Float infinity) native;
     replace "executionStopped" (str "true") native;replace "mayHaveLateEffects" `Null native;
     List.remove_assoc "pageResponsive" native;("code",str "EGO_PAGE_EVALUATION_TIMED_OUT")::native;
     ("unexpected",`Bool true)::native]
let malformed_receipts () =
  let expected=request [click;wait] in
  List.iter (fun value -> check bool "incomplete/mismatched execution is not success" true (Result.is_error (R.decode expected value)))
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
  stopped "lost release was called confirmed" (not_released 0 Rel.Never_returned) (R.decode (request [drag;click]) (obj fields));
  let paste_fields=("failure",failure 0 "keyboard.paste")::List.remove_assoc "failure" fields in
  stopped "paste lost its modifier release uncertainty" (not_released 0 Rel.Never_returned)
    (R.decode (request [step "keyboard.paste" ["text",str "x"]]) (obj paste_fields))
let holding=["dragAndDrop",["selector",str "#source";"destination",str "#target"];
  "click",["selector",str "#source"];"dblclick",["selector",str "#source"];
  "mouse.click",["x",`Int 10;"y",`Int 20];
  "press",["selector",str "#editor";"key",str "Enter"];
  "keyboard.press",["key",str "Enter"];"keyboard.type",["text",str "x"];"keyboard.paste",["text",str "x"]]
let release_needs_receipt_evidence () =
  List.iter (fun (method_,args) ->
    let expected=request [step method_ args;wait] in
    check bool (method_ ^ " holds input") true
      (match expected.W.steps with first::_ -> W.holds_input first.W.action | [] -> false);
    let success ?(released=true) receipt=
      let fields=result ~started:true ~completed_effect:true ~failure:`Null
        ~completed:[entry ~receipt 0 method_;entry 1 "waitForURL"] in
      R.decode expected (obj (snapshot @ with_claim released fields)) in
    List.iter (fun receipt -> match ok (success receipt) with
      | R.Completed {input=Rel.Released (Rel.Released_by_receipts proven);_} ->
        check (list int) (method_ ^ ": the receipt proves its holding step") [0] proven
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
    refused (method_ ^ ": a step that never returned cannot report release") (R.decode alone (obj never_returned));
    stopped (method_ ^ ": a step that never returned reports a held input") (not_released 0 Rel.Never_returned)
      (R.decode alone (obj (unreleased never_returned)));
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
      ["a later failure",R.decode then_wait,failed_later;"a failed snapshot",R.decode alone,snapshot_failed]) holding
let release_across_several_holding_steps () =
  let two=request [click;click] and hover_first=request [step "hover" ["selector",str "@3"];click] in
  let both first second=result ~started:true ~completed_effect:true ~failure:`Null
    ~completed:[entry ~receipt:first 0 "click";entry ~receipt:second 1 "click"] in
  (match ok (R.decode two (obj (snapshot @ both (obj []) (obj [])))) with
   | R.Completed {input=Rel.Released (Rel.Released_by_receipts proven);_} -> check (list int) "both holding steps are proven" [0;1] proven
   | R.Completed {input=Rel.No_hold;_} | R.Stopped _ -> fail "two proven holding steps were not released");
  refused "a proven last step does not hide an unproven first one" (R.decode two (obj (snapshot @ both `Null (obj []))));
  refused "a proven first step does not hide an unproven last one" (R.decode two (obj (snapshot @ both (obj []) `Null)));
  let first_unproven fields=result ~started:true ~completed_effect:true ~failure:(failure 2 "waitForURL") ~completed:fields in
  stopped "the first unreleased holding step is the one named" (not_released 0 Rel.Void_answer)
    (R.decode (request [click;click;wait]) (obj (unreleased (first_unproven
      [entry ~receipt:`Null 0 "click";entry ~receipt:(str "ok") 1 "click"]))));
  stopped "a later unreleased holding step is named when the first is proven" (not_released 1 Rel.Undeclared_answer)
    (R.decode (request [click;click;wait]) (obj (unreleased (first_unproven
      [clicked 0;entry ~receipt:(str "ok") 1 "click"]))));
  (match ok (R.decode hover_first (obj (snapshot @ result ~started:true ~completed_effect:true ~failure:`Null
      ~completed:[entry 0 "hover";clicked 1]))) with
   | R.Completed {input=Rel.Released (Rel.Released_by_receipts proven);_} ->
     check (list int) "a non-holding step is not listed as proven" [1] proven
   | R.Completed {input=Rel.No_hold;_} | R.Stopped _ -> fail "a hover followed by a proven click was not released");
  let void_then_failed=result ~started:true ~completed_effect:true ~completed:[entry ~receipt:`Null 0 "click"] ~failure:(failure 1 "click") in
  stopped "the earlier unreleased step is named before a later failed one" (not_released 0 Rel.Void_answer)
    (R.decode two (obj (unreleased void_then_failed)));
  let second_never_returned=result ~started:true ~completed_effect:true ~completed:[clicked 0] ~failure:(failure 1 "click") in
  refused "a later holding step that never returned cannot report release" (R.decode two (obj second_never_returned));
  stopped "a later holding step that never returned reports a held input" (not_released 1 Rel.Never_returned)
    (R.decode two (obj (unreleased second_never_returned)));
  let after_hover=result ~started:true ~completed_effect:true ~completed:[entry 0 "hover"] ~failure:(failure 1 "click") in
  refused "a holding step after a non-holding one cannot report release unreturned" (R.decode hover_first (obj after_hover));
  stopped "a holding step after a non-holding one reports a held input" (not_released 1 Rel.Never_returned)
    (R.decode hover_first (obj (unreleased after_hover)))
let a_dialog_left_on_a_holding_step_is_unproven () =
  let named index method_=obj ["index",`Int index;"method",str method_;"message",str "answer";
    "dialog",obj ["type",str "alert";"message",str "m"]] in
  let on_click=result ~started:true ~completed_effect:true ~completed:[clicked 0] ~failure:(named 0 "click") in
  refused "a dialog reported on a holding step cannot sit beside a release claim" (R.decode (request [click]) (obj on_click));
  refused "a failure on a step that already returned needs a dialog to explain it"
    (R.decode (request [click]) (obj (unreleased (result ~started:true ~completed_effect:true ~completed:[clicked 0]
      ~failure:(failure 0 "click")))));
  stopped "a dialog reported on a holding step reports a held input" (not_released 0 Rel.Receipt_with_dialog)
    (R.decode (request [click]) (obj (unreleased on_click)));
  let on_insert=result ~started:true ~completed_effect:true ~failure:(named 1 "keyboard.insertText")
    ~completed:[clicked 0;entry 1 "keyboard.insertText"] in
  stopped "a dialog on a later non-holding step leaves the earlier release proven" (`Released [0])
    (R.decode (request [click;step "keyboard.insertText" ["text",str "x"]]) (obj on_insert))
let a_held_claim_needs_a_holding_effect () =
  let fill=step "fill" ["selector",str "#editor";"text",str "x"] in
  let failed_fill=result ~started:true ~completed_effect:false ~completed:[] ~failure:(failure 0 "fill") in
  refused "a request with no holding step cannot hold input" (R.decode (request [fill]) (obj (unreleased failed_fill)));
  let initial=result ~started:false ~completed_effect:false ~completed:[] ~failure:(failure 0 "initialUrl") in
  refused "a holding step that started no effect cannot hold input" (R.decode (request [click]) (obj (unreleased initial)))
let an_initial_url_failure_holds_nothing () =
  let initial=result ~started:false ~completed_effect:false ~completed:[] ~failure:(failure 0 "initialUrl") in
  (match R.decode (request [click]) (obj initial) with
   | Ok (R.Stopped {effect_started;input;_}) ->
     check bool "an unreadable starting URL starts no effect" false effect_started;
     check bool "an unreadable starting URL holds nothing" true (seen_input input=`No_hold)
   | Ok (R.Completed _) | Error _ -> fail "an unreadable starting URL did not stop before any input");
  refused "initialUrl only fails before the first step"
    (R.decode (request [click;click]) (obj (result ~started:true ~completed_effect:true ~completed:[clicked 0]
      ~failure:(failure 1 "initialUrl"))));
  refused "initialUrl only fails before any step completed"
    (R.decode (request [step "url" [];click]) (obj (result ~started:false ~completed_effect:false
      ~completed:[entry ~receipt:(str "https://example.test/start") 0 "url"] ~failure:(failure 0 "initialUrl"))))
let a_workflow_that_never_held_input_has_nothing_to_release () =
  let fill=step "fill" ["selector",str "#editor";"text",str "x"] in
  let first_fails=result ~started:true ~completed_effect:false ~completed:[] ~failure:(failure 0 "fill") in
  stopped "a failure before the holding step leaves nothing to release" `No_hold
    (R.decode (request [fill;click]) (obj first_fails));
  stopped "a held claim with no holding step entered is only the script's" (`Unconfirmed Rel.Held_by_script_report)
    (R.decode (request [fill;click]) (obj (unreleased first_fails)));
  (match ok (R.decode (request [step "url" []]) (obj (snapshot @ result ~started:false ~completed_effect:false
      ~completed:[entry ~receipt:(str "https://example.test/start") 0 "url"] ~failure:`Null))) with
   | R.Completed {input=Rel.No_hold;_} -> ()
   | R.Completed {input=Rel.Released _;_} | R.Stopped _ -> fail "a workflow with no holding step released something")
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
      (R.decode two (shown (result ~started:true ~completed_effect:true ~completed:[clicked 0] ~failure:(failure 1 "snapshot"))));
    refused "an observation failure before any step completed is not a step failure"
      (R.decode two (shown (result ~started:false ~completed_effect:false ~completed:[] ~failure:(failure 0 "observation"))));
    refused "a dialog on a step that is not the last completed one does not explain the failure"
      (R.decode three (shown (result ~started:true ~completed_effect:true ~completed:[clicked 0;clicked 1] ~failure:(named 0 "click")))))
    [true;false]
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
  test_case "fetch save names are safe artifact metadata" `Quick fetch_save_inputs;
  test_case "saved fetch receipts bind exact artifact provenance" `Quick fetch_save_receipts;
  test_case "native evaluation timeout preserves diagnostics and uncertain effects" `Quick evaluation_timeouts;
  test_case "drag release is separate from effect completion" `Quick pointer_release;
  test_case "a release claim needs receipt evidence" `Quick release_needs_receipt_evidence;
  test_case "a stopped reply cannot report a release its receipts do not show" `Quick release_claim_on_stopped_replies;
  test_case "release is judged over every holding step" `Quick release_across_several_holding_steps;
  test_case "a dialog left on a holding step leaves its release unproven" `Quick a_dialog_left_on_a_holding_step_is_unproven;
  test_case "a held claim needs a holding effect" `Quick a_held_claim_needs_a_holding_effect;
  test_case "an initial URL failure holds nothing" `Quick an_initial_url_failure_holds_nothing;
  test_case "a workflow that never held input has nothing to release" `Quick a_workflow_that_never_held_input_has_nothing_to_release;
  test_case "release is judged from the answers the SDK declared" `Quick release_is_judged_from_declared_answers;
  test_case "a step answered twice counts once" `Quick a_step_answered_twice_counts_once;
  test_case "a failure label must match its position" `Quick a_failure_label_must_match_its_position;
  test_case "malformed execution never proves success" `Quick malformed_receipts]]
