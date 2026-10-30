open Alcotest
module App = Lane_addon_application

let worker ?(matches_desired=true) id activity : App.worker = {instance_id=id;matches_desired;activity}
let observe ?(complete=true) ?(issues=[]) ~enabled workers = App.observe ~enabled ~complete ~issues ~workers
let expect label expected actual = check string label
  (Yojson.Safe.to_string (App.to_json expected)) (Yojson.Safe.to_string (App.to_json actual))

let off_waits_for_all_owners () =
  let old = worker ~matches_desired:false "historical" App.Stopping in
  expect "absence of a live owner is not cleanup proof" App.Cleaning_workers (observe ~enabled:false [old]);
  expect "a stopped old owner does not block off" App.Inactive
    (observe ~enabled:false [{old with activity=App.Stopped}]);
  expect "a live owner still needs cleanup" App.Cleaning_workers
    (observe ~enabled:false [worker "live" App.Running;{old with activity=App.Stopped}])

let restart_does_not_prove_application () =
  expect "no owner is pending, not applied" App.Starting_worker (observe ~enabled:true []);
  expect "created container before handshake is pending" App.Starting_worker
    (observe ~enabled:true [worker "starting" App.Starting]);
  expect "running exact owner applies the observed configuration" (App.Applied "live")
    (observe ~enabled:true [worker "live" App.Running])

let revision_replacement_waits_for_cleanup () =
  let current = worker "current" App.Running and previous = worker ~matches_desired:false "previous" App.Stopping in
  expect "new revision does not hide retained cleanup" App.Cleaning_workers (observe ~enabled:true [current;previous]);
  expect "completed retained cleanup allows exact running owner" (App.Applied "current")
    (observe ~enabled:true [current;{previous with activity=App.Stopped}]);
  expect "same payload after off/on still waits for the stopping owner" App.Cleaning_workers
    (observe ~enabled:true [worker "same-revision" App.Stopping])

let failures_remain_failures () =
  expect "historical cleanup failure cannot become off" (App.Failed ["historical: cleanup failed"])
    (observe ~enabled:false [worker "historical" (App.Worker_failed "cleanup failed")]);
  expect "missing image is not successfully configured" (App.Failed ["image unavailable"])
    (observe ~issues:["image unavailable"] ~enabled:true []);
  expect "running worker cannot hide an admission error" (App.Failed ["publication failed"])
    (observe ~issues:["publication failed"] ~enabled:true [worker "live" App.Running])

let unknown_readings_cannot_complete () =
  List.iter (fun (enabled,workers) -> match observe ~complete:false ~enabled workers with
    | App.Unknown _ -> () | _ -> fail "incomplete inventory claimed a state")
    [false,[]; false,[worker "old" App.Stopped]; true,[worker "live" App.Running]];
  expect "duplicate current owners have no winner" (App.Unknown ["Multiple workers claim the desired declaration"])
    (observe ~enabled:true [worker "a" App.Running;worker "b" App.Running])

let () = run "Lane application observation" ["operator lifecycle", [
  test_case "off waits for live and historical owners" `Quick off_waits_for_all_owners;
  test_case "startup waits for accepted worker connection" `Quick restart_does_not_prove_application;
  test_case "replacement and reenable preserve cleanup" `Quick revision_replacement_waits_for_cleanup;
  test_case "failed cleanup and admission remain visible" `Quick failures_remain_failures;
  test_case "incomplete and ambiguous readings stay unknown" `Quick unknown_readings_cannot_complete;
]]
