open Alcotest
module S = Mcp_protocol.Mcp_types
module Wire = Lane_addon_tool_result

let response ?(is_error=true) metadata : S.tool_result =
  {content=[];is_error=Some is_error;structured_content=None;_meta=metadata}

let test_producer_failure_survives () =
  List.iter (fun disposition ->
    let result = Tool_result.make_err ~tool_name:"fixture" ~start_time:(Tool_timing.start ())
      ~class_:Tool_result.Workflow_rejection ~effect_disposition:disposition
      ~metadata:(`Assoc ["worker", `String "receipt"]) "refused" in
    let metadata = Wire.metadata result in
    check bool "worker extension survives serialization" true
      (match metadata with Some (`Assoc fields) -> List.assoc_opt "worker" fields=Some (`String "receipt") | _ -> false);
    check bool "class and effect disposition survive SDK metadata" true
      (Wire.failure (response metadata) = (Tool_result.Workflow_rejection, disposition)))
    [Tool_result.Proven_pre_effect; Proven_post_effect; Effect_outcome_unknown]

let test_malformed_metadata_never_proves_effect () =
  let key = "io.github.jeong-sik/masc.lane.failure" in
  let known = `Assoc ["class", `String "workflow_rejection"; "effect", `String "proven_pre_effect"] in
  List.iter (fun metadata ->
    check bool "incomplete or ambiguous metadata stays unknown" true
      (Wire.failure (response metadata) = (Tool_result.Runtime_failure, Tool_result.Effect_outcome_unknown)))
    [None; Some (`String "proven_pre_effect"); Some (`Assoc []);
     Some (`Assoc [key, known;key,known]);
     Some (`Assoc [key, `Assoc ["class", `String "workflow_rejection"]]);
     Some (`Assoc [key, `Assoc ["class", `String "unknown";"effect",`String "proven_pre_effect"]]);
     Some (`Assoc [key, `Assoc ["class", `String "workflow_rejection";"effect",`String "unknown"]]);
     Some (`Assoc [key, `Assoc ["class", `String "workflow_rejection";"class",`String "workflow_rejection"]])];
  check bool "success cannot become a proven failure from stale metadata" true
    (Wire.failure (response ~is_error:false (Some (`Assoc [key, known]))) =
      (Tool_result.Runtime_failure, Tool_result.Effect_outcome_unknown));
  let success = Tool_result.make_ok ~tool_name:"fixture" ~start_time:(Tool_timing.start ())
    ~metadata:(`Assoc [key,known;"worker",`String "receipt"]) () in
  check bool "producer removes stale failure metadata on success" true
    (Wire.metadata success = Some (`Assoc ["worker",`String "receipt"]))

let () = run "Lane worker failure boundary" ["wire", [
  test_case "producer effect truth survives" `Quick test_producer_failure_survives;
  test_case "malformed metadata keeps unknown outcome" `Quick test_malformed_metadata_never_proves_effect]]
