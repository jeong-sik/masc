(** #10561: pin the [gh_command_blocked] error to surface the allowed
    command list inline so the LLM can self-correct on the same retry
    instead of random-guessing into the next [gh_command_blocked] event
    (13 events / day pre-fix, executor circuit_breaker tripped 1x). *)

open Alcotest

module GHV = Masc_mcp.Gh_command_validation

let contains s sub =
  let n = String.length s and m = String.length sub in
  let rec loop i =
    if i + m > n then false
    else if String.sub s i m = sub then true
    else loop (i + 1)
  in
  loop 0

let test_disallowed_command_surfaces_allowed_list () =
  match GHV.validate_gh_command "auth login" with
  | Ok _ -> failf "expected gh_command_blocked for 'auth'"
  | Error msg ->
      check bool
        (Printf.sprintf "error must mention allowed list — got: %s" msg)
        true
        (contains msg "allowed=[" && contains msg "pr"
         && contains msg "issue" && contains msg "repo");
      check bool "error must still mention the rejected command" true
        (contains msg "'auth'")

let test_allowed_command_passes () =
  match GHV.validate_gh_command "pr list --state open" with
  | Ok _ -> ()
  | Error msg -> failf "expected pr list to pass, got: %s" msg

let () =
  run "gh_command_blocked_message_10561"
    [
      ( "error-message-shape",
        [
          test_case "disallowed command lists allowed alternatives" `Quick
            test_disallowed_command_surfaces_allowed_list;
          test_case "allowed command (pr list) still passes" `Quick
            test_allowed_command_passes;
        ] );
    ]
