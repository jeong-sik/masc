open Alcotest
module UI = Masc_tui_lane_subscriptions
module S = Masc.Lane_addon_subscription
let ok = function Ok value->value|Error detail->fail detail
let target : UI.target = {installation_id="documents";run_id="project";output_id="changes";
  instance_id="worker-1";title="Document checks"}
let keepers = ["alice";"bob"]
let targets = [target]
let sub keeper : S.subscription = {keeper_name=keeper;installation_id=target.installation_id;
  run_id=target.run_id;output_id=target.output_id}
let initial = UI.initial ~keepers ~targets
let config : UI.snapshot = {revision=Some "revision-1";
  entries=[sub "alice",UI.Position {instance_id="worker-1";acknowledged=2;latest=4;replaced=false}]}
let enter = UI.enter ~keepers ~targets
let choose () =
  let view=UI.loaded initial (Ok config) |> UI.add in
  let view=UI.move view 1 in
  let view,request=enter view in
  check bool "choosing Keeper performs no request" true (request=None);
  let view,request=enter view in
  check bool "choosing output still requires review" true (request=None);
  view
let guided_add_and_remove () =
  let view=choose () in
  check bool "review names the actual Keeper" true (List.mem "Keeper: bob" (UI.lines view));
  check bool "review names exact declared output" true (List.mem "Output: changes" (UI.lines view));
  let _,request=enter view in
  let request=Option.get request in
  check bool "save keeps unrelated subscriptions and frozen CAS revision" true
    (request=UI.Save {revision=Some "revision-1";subscriptions=[sub "alice";sub "bob"]});
  let json=UI.request_json request in
  check bool "configuration request does not impersonate reader" true
    (Yojson.Safe.Util.member "operation" json=`String "save"
     && Yojson.Safe.Util.member "caller" json=`Null
     && Yojson.Safe.Util.member "receipt" json=`Null);
  let _,removed=enter (UI.remove (UI.loaded initial (Ok config))) in
  check bool "removal previews then uses the same CAS boundary" true
    (removed=Some (UI.Save {revision=Some "revision-1";subscriptions=[]}));
  let rejected=UI.loaded view (Error "subscription configuration revision conflict") in
  check bool "revision conflict stays visible without declaring success" true
    (List.mem "Error: subscription configuration revision conflict" (UI.lines rejected))
let changed_choices_are_not_retargeted () =
  let view=choose () in
  let _,request=UI.enter ~keepers:["alice"] ~targets view in
  check bool "removed Keeper cannot inherit confirmation" true (request=None);
  let _,request=UI.enter ~keepers ~targets:[{target with instance_id="replacement"}] view in
  check bool "replacement worker cannot inherit confirmation" true (request=None);
  let empty=UI.initial ~keepers:[] ~targets |> fun t->UI.loaded t (Ok config) |> UI.add in
  check bool "empty roster does not fabricate recipient" true
    (List.mem "Error: No workspace Keeper is available in the roster. Close and refresh." (UI.lines empty))
let reader_state_requires_matching_snapshot () =
  let state=`Assoc ["subscription",S.json (sub "alice");"instance_id",`String "worker-1";
    "after_sequence",`Int 2;"latest_sequence",`Int 4;"replaced",`Bool false;
    "new_observations",`Bool true] in
  let json states=`Assoc ["source_revision",`String "revision-1";
    "subscriptions",`List [S.json (sub "alice")];"reader_states",`List states] in
  let snapshot=UI.decode (json [state]) |> ok in
  let lines=UI.lines (UI.loaded initial (Ok snapshot)) in
  check bool "unread and acknowledged positions are distinguished" true
    (List.mem "Acknowledged through sequence 2 · latest 4 · unread 2" lines);
  check bool "unpersisted reads are not described as use" true
    (List.mem "Reads without acknowledgment are not persisted." lines);
  check bool "missing reader state is not invented as zero" true
    (Result.is_error (UI.decode (json [])));
  let unavailable=`Assoc ["subscription",S.json (sub "alice");"unavailable",`String "missing record store"] in
  let snapshot=UI.decode (json [unavailable]) |> ok in
  check bool "dependency failure remains visible" true
    (List.mem "Reader state unavailable: missing record store" (UI.lines (UI.loaded initial (Ok snapshot))))
let () = run "Guided Lane subscriptions" ["operator scenarios",[
  test_case "finite choices, explicit confirmation and CAS preservation" `Quick guided_add_and_remove;
  test_case "changed recipients and outputs cannot silently retarget" `Quick changed_choices_are_not_retargeted;
  test_case "reader state is honest and joined to exact subscriptions" `Quick reader_state_requires_matching_snapshot]]
