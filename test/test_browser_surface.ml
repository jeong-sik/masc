open Alcotest
module Surface = Masc.Browser_surface
let test_slack_identity () =
  List.iter (fun url -> check bool url true (Surface.is_slack_url url))
    ["https://app.slack.com/client/T123/C123"; "https://team.slack.com/archives/C123"];
  List.iter (fun url -> check bool url false (Surface.is_slack_url url))
    ["https://slack.com.evil.test/client/T/C";"https://example.org/?slack.com/client/T/C";
     "https://app.slack.com/signin";"http://app.slack.com/client/T/C"]
let test_strict_input () =
  List.iter (fun json -> match Surface.parse_request json with
      | Error _ -> () | Ok _ -> fail "invalid read request accepted")
    [`Assoc ["lane", `Bool true]; `Assoc ["app",`String "unknown"];
     `Assoc ["tabId",`Int (-1)]; `Assoc ["tabID",`Int 1]]
let test_remote_failure () =
  match Surface.decode_answer (Browser_lane.Answered
    (`Assoc ["ok",`Bool false;"error",`String "tab closed"])) with
  | Error "tab closed" -> () | _ -> fail "backend failure became success"
let () = run "browser app surface" ["behavior",[
  test_case "Slack URL identity resists spoofing" `Quick test_slack_identity;
  test_case "invalid input is refused" `Quick test_strict_input;
  test_case "backend failure is visible" `Quick test_remote_failure]]
