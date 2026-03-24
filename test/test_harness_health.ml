(** Tests for Tool_harness_health — harness subsystem health check *)

module H = Masc_mcp.Tool_harness_health
module D = Masc_mcp.Tool_dispatch
module M = Masc_mcp.Tool_metrics
module Trace = Masc_mcp.Trace

let setup () =
  D.clear_hooks ();
  M.clear ();
  Trace.clear ();
  Masc_mcp.Server_startup_state.reset ()

let test_all_checks_run () =
  setup ();
  let checks = H.all_checks () in
  Alcotest.(check bool) "5 checks" true (List.length checks = 5);
  List.iter (fun c ->
    Alcotest.(check bool) (Printf.sprintf "%s has name" c.H.name)
      true (String.length c.name > 0);
    Alcotest.(check bool) (Printf.sprintf "%s has detail" c.H.name)
      true (String.length c.detail > 0)
  ) checks

let test_score_zero_when_empty () =
  setup ();
  let checks = H.all_checks () in
  let score = H.health_score checks in
  Alcotest.(check (float 0.0001)) "score is zero without startup/runtime signals"
    0.0 score

let test_score_improves_with_hooks () =
  setup ();
  Masc_mcp.Server_startup_state.reset ~backend_mode:"filesystem" ();
  Masc_mcp.Server_startup_state.mark_state_ready ~backend_mode:"filesystem";
  (* Install hooks and generate some data *)
  Masc_mcp.Tool_metrics.install ();
  D.register ~tool_name:"__health_test"
    ~handler:(fun ~name:_ ~args:_ -> Some (true, "ok"));
  let _ = D.dispatch_structured ~name:"__health_test" ~args:`Null in
  let checks = H.all_checks () in
  let score = H.health_score checks in
  Alcotest.(check bool) "score > 0.5 with subsystems active"
    true (score > 0.5)

let test_handle_returns_json () =
  setup ();
  match H.handle ~name:"masc_harness_health" ~args:`Null with
  | Some (true, json_str) ->
    let json = Yojson.Safe.from_string json_str in
    (match json with
     | `Assoc fields ->
       Alcotest.(check bool) "has score" true
         (List.exists (fun (k, _) -> k = "score") fields);
       Alcotest.(check bool) "has checks" true
         (List.exists (fun (k, _) -> k = "checks") fields)
     | _ -> Alcotest.fail "expected Assoc")
  | _ -> Alcotest.fail "expected Some (true, _)"

let () =
  Alcotest.run "Harness_health" [
    "checks", [
      Alcotest.test_case "all run" `Quick test_all_checks_run;
      Alcotest.test_case "score range" `Quick test_score_zero_when_empty;
      Alcotest.test_case "score improves" `Quick test_score_improves_with_hooks;
    ];
    "handler", [
      Alcotest.test_case "returns JSON" `Quick test_handle_returns_json;
    ];
  ]
