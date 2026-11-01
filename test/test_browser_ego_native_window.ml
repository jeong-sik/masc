open Alcotest
module W = Masc.Browser_ego_native_window
module Surface = Masc.Browser_surface
open W

let object_ fields = `Assoc fields
let text value = `String value
let page target label : W.page = {space_id=7;native={Surface.label=Some label;
  target_id=target;opened_by=Surface.Agent_created}}
let original = page "source-target" "p1"
let popup = page "popup-target" "p2"
let make_expected ?(command="command") ?(generation="generation") ?(step=2)
    ?(source=original) ?(current=popup) ?(nonce="nonce") () =
  match W.prepare ~command_id:command ~generation ~step_index:step ~source ~current
      ~nonce ~world_name:"private-world" ~binding_name:"private-binding" with
  | Ok value -> value | Error detail -> fail detail
let event ?(session="session") method_ params = object_ [
  "sessionId",text session;"method",text method_;"params",object_ params]
let context ?(id=31) ?(unique="unique-context") ?(name="private-world")
    ?(frame="root-frame") () = object_ ["id",`Int id;"uniqueId",text unique;
  "name",text name;"origin",text "";"auxData",object_ [
    "frameId",text frame;"type",text "isolated";"isDefault",`Bool false]]
let created value = event "Runtime.executionContextCreated" ["context",value]
let tree ?(loader="document") () = object_ ["frameTree",object_ ["frame",object_ [
  "id",text "root-frame";"loaderId",text loader;"url",text "https://example.test/"]]]
let boot expected ?(events=`List [created (context ())]) ?(before=tree ()) () =
  W.bootstrap ~expected ~page_enable:(object_ []) ~runtime_enable:(object_ [])
    ~frame_tree:(tree ()) ~isolated_world:(object_ ["executionContextId",`Int 31])
    ~add_binding:(object_ []) ~events ~before_start_frame_tree:before
let bound expected = match boot expected () with Ok value -> value | Error _ -> fail "invalid bootstrap fixture"
let marker ?(session="session") ?(id=31) expected phase = event ~session "Runtime.bindingCalled" [
  "name",text "private-binding";"payload",text (W.marker_payload expected phase);"executionContextId",`Int id]
let response expected marker = object_ ["result",object_ ["type",text "string";"value",text (W.marker_payload expected marker)]]
let classify ?(current=popup) ?(returned=W.Void_return) ?start ?ending expected events =
  let start = match start with Some value -> value | None -> response expected Start in
  let ending = match ending with Some value -> value | None -> response expected End in
  W.classify (bound expected) ~current ~returned ~start_reply:start ~end_reply:ending ~events:(`List events)
let success = function Ok value -> value | Error _ -> fail "expected a verified native interval"
let rejects expected = function
  | Error reason -> check bool "exact unconfirmed reason" true (reason=expected)
  | Ok _ -> fail "unconfirmed capture became completion"
let malformed = function
  | Error (W.Malformed_native _) -> ()
  | Error (Context_or_session_changed | Document_changed | Bounds_missing_or_duplicated
    | Bounds_out_of_order | Dialog_opened | Unexpected_return | No_raw_call | Native_failure
    | Control_unavailable | Transport_unconfirmed | Cancelled | Page_binding_changed)
  | Ok _ -> fail "expected malformed native capture"

let normal_and_binding () =
  let expected = make_expected () in
  let start = marker expected Start and ending = marker expected End in
  let proof = success (classify expected [start;ending]) in
  check bool "same immutable command" true (W.matches proof expected);
  List.iter (fun different -> check bool "cannot rebind completion" false (W.matches proof different)) [
    make_expected ~command:"other" (); make_expected ~generation:"other" (); make_expected ~step:3 ();
    make_expected ~source:popup (); make_expected ~current:original (); make_expected ~nonce:"other" ()];
  check string "actual native unique ID" "unique-context" (W.unique_context_id (bound expected));
  let raw = W.observation proof in
  check bool "retains interval array unchanged" true
    (Yojson.Safe.Util.member "events" raw = `List [start;ending]);
  check bool "explicit void observation" true
    (Yojson.Safe.Util.member "returnKind" raw = text "void");
  rejects Page_binding_changed (classify ~current:original expected [start;ending])

let return_and_transport () =
  let expected = make_expected () in
  let events = [marker expected Start;marker expected End] in
  List.iter (fun value -> rejects W.Unexpected_return
    (classify ~returned:(Value_return value) expected events)) [`Null;object_ [];text "undefined"];
  List.iter (fun reason -> rejects reason (classify ~returned:(Did_not_return reason) expected events))
    [W.Native_failure;Control_unavailable;Transport_unconfirmed;Cancelled];
  rejects No_raw_call (classify ~returned:Not_invoked expected events);
  malformed (classify ~start:(object_ ["result",object_ ["type",text "undefined"];
    "exceptionDetails",object_ []]) expected events);
  malformed (classify ~ending:(object_ ["result",object_ ["type",text "object";"value",`Null]]) expected events)

let bootstrap_authority () =
  let expected = make_expected () in
  rejects W.Context_or_session_changed (boot expected ~events:(`List []) ());
  rejects Context_or_session_changed (boot expected ~events:(`List [created (context ~frame:"child" ())]) ());
  rejects Context_or_session_changed (boot expected ~events:(`List [created (context ());created (context ())]) ());
  rejects Document_changed (boot expected ~before:(tree ~loader:"replacement" ()) ());
  let missing_unique = object_ ["id",`Int 31;"name",text "private-world";"origin",text ""] in
  malformed (boot expected ~events:(`List [created missing_unique]) ());
  let no_session = object_ ["method",text "Runtime.executionContextCreated";"params",object_ ["context",context ()]] in
  rejects Context_or_session_changed (boot expected ~events:(`List [created (context ());no_session]) ());
  rejects Context_or_session_changed (boot expected ~events:(`List [created (context ());
    event "Runtime.executionContextsCleared" []]) ())

let exact_bounds () =
  let expected = make_expected () in
  let start = marker expected Start and ending = marker expected End in
  List.iter (fun events -> rejects W.Bounds_missing_or_duplicated (classify expected events))
    [[];[start];[ending];[start;start;ending];[start;ending;ending]];
  rejects Bounds_out_of_order (classify expected [ending;start]);
  rejects Context_or_session_changed (classify expected [marker ~session:"other" expected Start;ending]);
  rejects Context_or_session_changed (classify expected [start;marker ~id:32 expected End]);
  let other = make_expected ~nonce:"forged" () in
  rejects Bounds_missing_or_duplicated (classify expected [marker other Start;ending]);
  let lookalike = event "Runtime.consoleAPICalled" ["value",text (W.marker_payload expected Start)] in
  rejects Bounds_missing_or_duplicated (classify expected [lookalike;ending])

let capture_cannot_rebind () =
  let original_expected = make_expected () in
  let events = [marker original_expected Start;marker original_expected End] in
  let changed_origin : W.page = {original with native={original.native with opened_by=Surface.Unknown_origin}} in
  let other_source : W.page = {original with space_id=8} in
  let other_current : W.page = {popup with space_id=8} in
  List.iter (fun (changed,current) ->
    malformed (classify ~current ~start:(response original_expected Start)
      ~ending:(response original_expected End) changed events);
    rejects W.Bounds_missing_or_duplicated (classify ~current changed events)) [
    make_expected ~source:popup (),popup;
    make_expected ~source:changed_origin (),popup;
    make_expected ~current:original (),original;
    make_expected ~source:other_source ~current:other_current (),other_current]

let lifecycle_scope () =
  let expected = make_expected () in
  let start = marker expected Start and ending = marker expected End in
  let dialog = event "Page.javascriptDialogOpening" ["type",text "alert";"message",text "nonce"] in
  let root = event "Page.frameStartedNavigating" ["frameId",text "root-frame"] in
  let child = event "Page.frameStartedNavigating" ["frameId",text "child-frame"] in
  let clear = event "Runtime.executionContextsCleared" [] in
  rejects W.Dialog_opened (classify expected [start;dialog;ending]);
  rejects Document_changed (classify expected [start;root;ending]);
  rejects Context_or_session_changed (classify expected [start;clear;ending]);
  rejects Context_or_session_changed (classify expected [start;created (context ());ending]);
  rejects Transport_unconfirmed (classify expected [start;event "Inspector.detached" [];ending]);
  ignore (success (classify expected [start;child;event ~session:"other" "Page.javascriptDialogOpening" [];ending]));
  ignore (success (classify expected [dialog;start;ending;dialog;root;clear]));
  ignore (success (classify expected [start;ending;event "Runtime.executionContextCreated" []]))

let malformed_capture () =
  let expected = make_expected () in
  let start = marker expected Start and ending = marker expected End in
  let duplicate = object_ ["method",text "Runtime.bindingCalled";"method",text "Runtime.consoleAPICalled"] in
  malformed (classify expected [start;duplicate;ending]);
  let duplicate_context = object_ ["method",text "Runtime.executionContextDestroyed";"sessionId",text "session";
    "params",object_ ["executionContextId",`Int 31;"executionContextId",`Int 32;"executionContextUniqueId",text "unique-context"]] in
  malformed (classify expected [start;duplicate_context;ending]);
  let missing_session = object_ ["method",text "Page.javascriptDialogOpening";"params",object_ []] in
  malformed (classify expected [start;missing_session;ending]);
  malformed (W.classify (bound expected) ~current:popup ~returned:Void_return
    ~start_reply:(response expected Start) ~end_reply:(response expected End) ~events:(object_ []))

let () = run "Ego native window foundation" ["native interval",[
  test_case "normal void and exact immutable command/Page binding" `Quick normal_and_binding;
  test_case "value, failed marker and direct interruption remain unknown" `Quick return_and_transport;
  test_case "native unique context and root document bootstrap" `Quick bootstrap_authority;
  test_case "authentic unique bounds, not application lookalikes" `Quick exact_bounds;
  test_case "old native capture cannot rebind source/current/Space" `Quick capture_cannot_rebind;
  test_case "relevant interval lifecycle only" `Quick lifecycle_scope;
  test_case "malformed/duplicate/partial native capture" `Quick malformed_capture]]
