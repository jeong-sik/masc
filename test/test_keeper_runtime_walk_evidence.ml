open Alcotest
module Evidence = Keeper_runtime_walk_evidence
module Fault = Llm_provider.Candidate_fault

let refused = Agent_core.Error.Api (Agent_core.Retry.InvalidRequest
  {message="Prompt exceeds max length";reason=Agent_core.Retry.Unknown_invalid_request})
let limited = Agent_core.Error.Api (Agent_core.Retry.RateLimited
  {message="Rate limit reached";retry_after=None})
let overflow = Agent_core.Error.Api (Agent_core.Retry.ContextOverflow
  {message="typed window observation";limit=Some 1048576})

let observe ?(dispatch=Runtime_attempt_dispatch.Dispatched) attempt runtime_id error =
  Evidence.observe_failure ~runtime_id ~attempt ~dispatch error

let decode evidence =
  match Evidence.of_yojson (Evidence.to_yojson evidence) with
  | Ok value -> value
  | Error error -> fail error

let test_mixed_candidate_failures () =
  let preflight=observe ~dispatch:Runtime_attempt_dispatch.Rejected_before_dispatch
    0 "missing.binding" (Agent_core.Error.Internal "candidate unavailable") in
  let first=observe 1 "glm.first" refused and last=observe 2 "glm.last" limited in
  let evidence=decode {Evidence.failures=[preflight;first;last];
    terminal=Evidence.observe_terminal ~runtime_id:"glm.last" ~attempt:2 limited} in
  check (list (pair int string)) "walk order and original candidate ordinals survive"
    [0,"missing.binding";1,"glm.first";2,"glm.last"]
    (List.map (fun (failure:Evidence.failure) -> failure.attempt,failure.runtime_id) evidence.failures);
  match evidence.failures with
  | [preflight;first;last] ->
    check bool "local refusal is not attributed to an invoked provider" true
      (preflight.dispatch=Runtime_attempt_dispatch.Rejected_before_dispatch);
    check bool "non-API preflight has no invented API fault" true
      (preflight.api_candidate_fault=None);
    check bool "HTTP prose remains an unattributed API refusal" true
      (first.api_candidate_fault=Some Fault.Unattributed);
    check bool "prose does not become a typed context overflow" false
      (match first.failure.cause with Keeper_request_failure.Context_overflow _ -> true | _ -> false);
    check bool "last candidate still has its distinct rate-limit fact" true
      (last.api_candidate_fault=Some (Fault.Binding Fault.Rate_limit))
  | _ -> fail "candidate failures disappeared"

let test_earlier_terminal_and_repeated_runtime () =
  let first=observe 0 "same.runtime" overflow and last=observe 1 "same.runtime" limited in
  let evidence=decode {Evidence.failures=[first;last];
    terminal=Evidence.observe_terminal ~runtime_id:"same.runtime" ~attempt:0 overflow} in
  check int "repeated runtime ids retain both independent attempts" 2 (List.length evidence.failures);
  match evidence.terminal with
  | Evidence.Candidate_terminal {runtime_id;attempt;failure} ->
    check string "terminal origin is the original candidate" "same.runtime" runtime_id;
    check int "terminal points at the earlier attempt, not the list tail" 0 attempt;
    check bool "terminal's own typed error is preserved" true
      (failure.cause=Keeper_request_failure.Context_overflow {limit=Some 1048576})
  | Evidence.Terminal_not_observed -> fail "actual terminal origin disappeared"

let test_successful_fallback_and_unobserved_terminal () =
  let evidence=decode {Evidence.failures=[observe 0 "first.runtime" limited];
    terminal=Evidence.Terminal_not_observed} in
  check int "a successful successor does not discard previous failures" 1
    (List.length evidence.failures);
  check bool "no terminal callback does not invent a failure origin" true
    (evidence.terminal=Evidence.Terminal_not_observed);
  let transformed=decode {evidence with terminal=Evidence.observe_terminal
    ~runtime_id:"first.runtime" ~attempt:0 (Agent_core.Error.Internal "effect settlement unknown")} in
  match transformed.terminal with
  | Evidence.Candidate_terminal {failure;_} ->
    check string "terminal observation need not equal the earlier provider answer"
      "effect settlement unknown" (Keeper_request_failure.summary failure)
  | Evidence.Terminal_not_observed -> fail "transformed terminal disappeared"

let test_corrupt_evidence_is_not_an_empty_walk () =
  let expect_error json = match Evidence.of_yojson json with
    | Error _ -> () | Ok _ -> fail "malformed evidence was accepted" in
  expect_error (`Assoc []);
  expect_error (`Assoc ["failures",`Null;"terminal",`Assoc ["kind",`String "not_observed"]]);
  expect_error (`Assoc ["failures",`List [];"failures",`List [];
    "terminal",`Assoc ["kind",`String "not_observed"]]);
  let first=observe 0 "first.runtime" refused in
  let json=Evidence.to_yojson {Evidence.failures=[first];terminal=Evidence.Terminal_not_observed} in
  let rewrite f = match json with
    | `Assoc fields ->
      (match List.assoc "failures" fields with
       | `List [`Assoc failure] -> `Assoc (("failures",`List [`Assoc (f failure)])
           ::List.remove_assoc "failures" fields)
       | _ -> fail "unexpected fixture shape")
    | _ -> fail "unexpected fixture shape" in
  expect_error (rewrite (fun fields -> ("attempt",`Int (-1))::List.remove_assoc "attempt" fields));
  expect_error (rewrite (fun fields -> ("dispatch",`String "maybe_sent")::List.remove_assoc "dispatch" fields));
  expect_error (rewrite (fun fields -> ("api_candidate_fault",`Assoc ["kind",`String "future_fault"])
    ::List.remove_assoc "api_candidate_fault" fields))

let () = run "runtime walk receipt evidence" ["candidate facts",[
  test_case "preflight, unclassified request refusal and quota stay distinct" `Quick test_mixed_candidate_failures;
  test_case "earlier terminal origin and repeated runtime identities survive" `Quick test_earlier_terminal_and_repeated_runtime;
  test_case "successful fallback and transformed terminal preserve separate facts" `Quick test_successful_fallback_and_unobserved_terminal;
  test_case "malformed evidence cannot masquerade as an empty walk" `Quick test_corrupt_evidence_is_not_an_empty_walk]]
