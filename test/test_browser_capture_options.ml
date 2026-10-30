open Alcotest
module B = Browser_lane
module C = B.Capture
let ok = function Ok value -> value | Error detail -> fail detail
let options = `Assoc ["fullPage",`Bool true;"raw",`Bool false;"scale",`String "css";
  "clip",`Assoc ["x",`Int (-2);"y",`Float 0.5;"width",`Int 640;"height",`Int 480;"scale",`Float 2.]]
let native_options () =
  let native=ok (C.of_json options) in
  check bool "all native options survive JSON serialization" true
    (C.of_json (C.to_json native)=Ok native);
  check bool "explicit false is preserved" true (native.raw=Some false);
  check bool "omission differs from an explicit native options object" true
    (C.of_optional_json None=Ok None && C.of_optional_json (Some (`Assoc []))=Ok (Some (ok (C.of_json (`Assoc [])))));
  List.iter (fun value -> check bool "invalid or host-owned options refused" true
      (Result.is_error (C.of_json value)))
    [`Null;`Assoc ["path",`String "/tmp/caller.png"];`Assoc ["timeoutMs",`Int 10];
     `Assoc ["fullPage",`Bool true;"fullPage",`Bool false];`Assoc ["raw",`Null];
     `Assoc ["scale",`String "device"];`Assoc ["clip",`Assoc ["x",`Float nan;"y",`Int 0;"width",`Int 1;"height",`Int 1]];
     `Assoc ["clip",`Assoc ["x",`Int 0;"y",`Int 0;"width",`Int 0;"height",`Int 1]];
     `Assoc ["clip",`Assoc ["x",`Int 0;"y",`Int 0;"width",`Int 1;"height",`Int 1;"scale",`Int (-1)]]]
let route_and_wait () =
  let native=B.Page_capture {tab_id=7;options=Some (ok (C.of_json options))} in
  let ordinary=B.Page_capture {tab_id=7;options=None} in
  check bool "native capture uses SDK execution ownership" true (B.ego_reply_policy native=B.Executor_owned);
  check bool "viewport capture also uses SDK execution ownership" true (B.ego_reply_policy ordinary=B.Executor_owned);
  check bool "native options are refused before automation work" true (B.automation_refusal native<>None);
  check bool "ordinary viewport capture remains available on automation" true (B.automation_refusal ordinary=None);
  check bool "native options are unavailable on Stagehand" false (B.verb_allowed_on_stagehand native);
  check bool "ordinary viewport capture remains available on Stagehand" true (B.verb_allowed_on_stagehand ordinary);
  check bool "native options require Ego capability" true
    (B.live_capability native=Some B.Native_workflow
      && B.live_transport_serves B.Ego_task_space B.Native_workflow
      && not (B.live_transport_serves B.Webdriver_bidi B.Native_workflow)
      && not (B.live_transport_serves B.Web_extension B.Native_workflow));
  check bool "ordinary capture remains supported by BiDi" true
    (B.live_capability ordinary=Some B.Viewport_capture
      && B.live_transport_serves B.Webdriver_bidi B.Viewport_capture)
let () = run "native screenshot request" ["boundary",[
  test_case "native option contract and owned path" `Quick native_options;
  test_case "SDK wait and transport admission" `Quick route_and_wait]]
