open Alcotest
module Effort = Llm_provider.Reasoning_effort

let command reasoning_effort =
  Runtime_claude_code.command ~system_prompt_file:None
    (Runtime_claude_code.default_config ~cwd:"/tmp") ~dynamic_tools:[]
    ~reasoning_effort ~session_mode:Runtime_claude_code.Start
    ~session_id:"11111111-1111-4111-8111-111111111111"
;;

let test_unadmitted_tiers_are_rejected () =
  List.iter (fun effort -> match command (Some effort) with
    | Error (Runtime_claude_code.Invalid_config _) -> ()
    | Error error -> fail (Runtime_claude_code.error_to_string error)
    | Ok _ -> fail ("unadmitted " ^ Effort.to_string effort ^ " reached native argv"))
    [Effort.Minimal; Ultra]
;;

let test_native_admission_preserves_explicit_intent () =
  List.iter (fun (requested, expected_effort, expected_thinking) ->
    let argv = match command (Option.map Runtime_claude_code.cli_admitted_reasoning_effort requested) with
      | Ok argv -> argv | Error error -> fail (Runtime_claude_code.error_to_string error) in
    let rec flag name = function
      | key :: value :: _ when String.equal name key -> Some value
      | _ :: rest -> flag name rest
      | [] -> None in
    check (option string) "admitted effort flag" expected_effort (flag "--effort" argv);
    check (option string) "omission differs from disabled thinking" expected_thinking (flag "--thinking" argv))
    [None, None, None;
     Some Effort.None_, None, Some "disabled";
     Some Minimal, Some "low", None;
     Some Low, Some "low", None;
     Some Medium, Some "medium", None;
     Some High, Some "high", None;
     Some XHigh, Some "xhigh", None;
     Some Max, Some "max", None;
     Some Ultra, Some "max", None]
;;

let () = run "Claude native effort admission"
  ["native vocabulary",[
    test_case "unsupported raw tiers never reach argv" `Quick test_unadmitted_tiers_are_rejected;
    test_case "admitted argv preserves all explicit intent" `Quick test_native_admission_preserves_explicit_intent]]
;;
