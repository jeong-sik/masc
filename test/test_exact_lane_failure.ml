(** One class per exact-lane failure: the Candle appraiser reads only
    whether it is transient, a package's exact outputs read all of it. *)
open Alcotest
module Exact = Agent_core.Exact_output
module Http = Agent_core.Llm_provider.Http_client
module F = Exact_lane_failure

let failure =
  testable
    (fun fmt -> function
       | F.Transient -> Format.pp_print_string fmt "transient"
       | F.Auth_refused -> Format.pp_print_string fmt "auth_refused"
       | F.Configuration_refused -> Format.pp_print_string fmt "configuration_refused"
       | F.Input_refused F.Request_body -> Format.pp_print_string fmt "input_refused request_body"
       | F.Input_refused F.Invalid_request -> Format.pp_print_string fmt "input_refused invalid_request"
       | F.Input_refused F.Context_overflow -> Format.pp_print_string fmt "input_refused context_overflow"
       | F.Input_refused F.Input_capacity -> Format.pp_print_string fmt "input_refused input_capacity"
       | F.Output_unusable -> Format.pp_print_string fmt "output_unusable"
       | F.Output_limit -> Format.pp_print_string fmt "output_limit")
    ( = )

let input_refusal =
  testable
    (fun fmt kind ->
       Format.pp_print_string fmt
         (match kind with
          | F.Request_body -> "request_body"
          | F.Invalid_request -> "invalid_request"
          | F.Context_overflow -> "context_overflow"
          | F.Input_capacity -> "input_capacity"))
    ( = )

let refused refusal = Exact.Provider_response_refused { http_status = 400; refusal; retry_after_s = None }
let completion kind =
  Exact.Completion_failed
    { error = Http.ProviderFailure { kind; message = "m" }; dispatch = Exact.Generation_dispatch_started }

let test_provider_refusals () =
  List.iter (fun (refusal, expected) ->
      check failure (Exact.provider_refusal_to_string refusal) expected (F.execution (refused refusal)))
    [ Exact.Rate_limited, F.Transient; Exact.Overloaded, F.Transient; Exact.Server_error, F.Transient
    ; Exact.Network_error, F.Transient; Exact.Timeout, F.Transient; Exact.Refusal_body_not_received, F.Transient
    ; Exact.Auth_failed, F.Auth_refused; Exact.Authorization_refused, F.Auth_refused
    ; Exact.Payment_required, F.Configuration_refused; Exact.Not_found, F.Configuration_refused
    ; Exact.Request_body_refused, F.Input_refused F.Request_body
    ; Exact.Invalid_request, F.Input_refused F.Invalid_request
    ; Exact.Context_overflow, F.Input_refused F.Context_overflow
    ; Exact.Input_capacity, F.Input_refused F.Input_capacity ];
  (* A 402 that states a window holds its account's slots until then
     (Runtime_exact_lane_backpressure.note_cause); called, it reads the same
     as a held slot (RFC-exact-lane-waits-for-a-stated-reset R5). *)
  List.iter (fun (retry_after_s, expected) ->
      check failure "a payment refusal is transient only with a usable window" expected
        (F.execution
           (Exact.Provider_response_refused
              { http_status = 402; refusal = Exact.Payment_required; retry_after_s })))
    [ None, F.Configuration_refused; Some 0., F.Configuration_refused; Some nan, F.Configuration_refused
    ; Some infinity, F.Configuration_refused; Some 60., F.Transient ]

let test_answers_that_cannot_be_used () =
  List.iter (fun (label, cause) -> check failure label F.Output_unusable (F.execution cause))
    [ "incomplete", Exact.Incomplete_output
    ; "missing", Exact.Missing_output; "ambiguous", Exact.Ambiguous_output 2
    ; "unexpected content", Exact.Unexpected_output_content; "invalid json", Exact.Invalid_json_output
    ; "empty completion", completion (Http.Empty_completion { stop_reason = Agent_core.Types.EndTurn }) ];
  check failure "a body deadline may pass later" F.Transient (F.execution Exact.Response_body_deadline_exceeded);
  check failure "the actual output limit remains distinct" F.Output_limit (F.execution Exact.Output_limit_reached)

let test_completion_failures () =
  check failure "an overflow named by the provider refuses the input" (F.Input_refused F.Context_overflow)
    (F.execution (completion (Http.Context_overflow { limit = Some 8192 })));
  check failure "a provider interruption is transient" F.Transient (F.execution (completion Http.Provider_interrupted));
  List.iter (fun (retry_after, expected) ->
      check failure "a hard quota is transient only with a usable window" expected
        (F.execution (completion (Http.Hard_quota { retry_after }))))
    [ None, F.Configuration_refused; Some 0., F.Configuration_refused; Some nan, F.Configuration_refused
    ; Some infinity, F.Configuration_refused; Some 60., F.Transient ]

let test_cli_failures () =
  List.iter (fun (resets_at_ms, expected) ->
    check failure "Muse typed quota follows its stated reset" expected
      (F.cli_failure (Masc.Keeper_lane_cli_oneshot.Execution_failed
         {runtime_id="muse.fixture";
          cause=Masc.Fusion_official_client.Muse_failure
            (Runtime_muse_serve.Turn_failed
               {Runtime_muse_msp.kind=Runtime_muse_msp.Model_error;
                message="fixture failure"; retryable=false;
                quota=Some {limit_kind="tierLimit"; resets_at_ms}})})))
    [Int.of_float ((Time_compat.now () +. 3600.) *. 1000.), F.Transient;
     0, F.Configuration_refused];
  check failure "an unknown runtime is configuration" F.Configuration_refused
    (F.cli_failure (Masc.Keeper_lane_cli_oneshot.Unknown_runtime { runtime_id = "r" }));
  check failure "text that is not JSON cannot be used" F.Output_unusable
    (F.cli_failure (Masc.Keeper_lane_cli_oneshot.Invalid_json_output { runtime_id = "r"; detail = "d" }));
  check failure "no reply cannot be used" F.Output_unusable
    (F.cli_failure
       (Masc.Keeper_lane_cli_oneshot.Execution_failed { runtime_id = "r"; cause = Masc.Fusion_official_client.Missing_reply }))

let test_antigravity_noncompletion_is_not_transient () =
  List.iter (fun status ->
      let cause = Runtime_antigravity.Result_not_completed
          { status; conversation_id = Some "interrupted-conversation"
          ; response = "partial reply"; error = None; num_turns = 1
          ; usage = {input_tokens=1;output_tokens=1;thinking_tokens=0;cache_read_tokens=0;total_tokens=2}
          ; denied = None } in
      let classified = F.cli_failure
          (Masc.Keeper_lane_cli_oneshot.Execution_failed
             { runtime_id = "agy.fixture"; cause = Masc.Fusion_official_client.Antigravity_failure cause }) in
      check failure "non-completed answer is unusable" F.Output_unusable classified;
      check bool "no safe transient replay" false (F.is_transient classified))
    [ Runtime_antigravity.Canceled; Interrupted; Invalid; Waiting; Running ]

let test_antigravity_refusal_is_not_transient () =
  let cause = Runtime_antigravity.Actions_denied
      { conversation_id = "conversation-1"; model = "gemini-fixture"
      ; denied = { first = "read_file"; rest = [] }; response = "partial reply"
      ; num_turns = 1
      ; usage = {input_tokens=1;output_tokens=1;thinking_tokens=0;cache_read_tokens=0;total_tokens=2}
      ; tool_steps = 0; stderr_tail = "" } in
  let classified = F.cli_failure
      (Masc.Keeper_lane_cli_oneshot.Execution_failed
         { runtime_id = "agy.fixture"; cause = Masc.Fusion_official_client.Antigravity_failure cause }) in
  check failure "refused run is unusable" F.Output_unusable classified;
  check bool "the same rules refuse a replay" false (F.is_transient classified)

let test_a_refusal_that_names_the_size_ends_the_walk () =
  let ending = check (option input_refusal) in
  let unnamed = F.Input_refused F.Invalid_request in
  List.iter
    (fun size ->
       let named = F.Input_refused size in
       ending "the slot that names the size walked second" (Some size) (F.ending_input_refusal [ unnamed; named ]);
       ending "the slot that names the size walked first" (Some size) (F.ending_input_refusal [ named; unnamed ]))
    [ F.Request_body; F.Context_overflow; F.Input_capacity ];
  let sizes = [ F.Input_refused F.Request_body; F.Input_refused F.Input_capacity; F.Input_refused F.Context_overflow ] in
  ending "among refusals that name the size the kind does not follow walk order" (Some F.Context_overflow)
    (F.ending_input_refusal (unnamed :: sizes));
  ending "the same slots walked in reverse end the same way" (Some F.Context_overflow)
    (F.ending_input_refusal (List.rev (unnamed :: sizes)));
  ending "input capacity comes before the request body" (Some F.Input_capacity)
    (F.ending_input_refusal [ F.Input_refused F.Request_body; F.Input_refused F.Input_capacity ]);
  ending "a refusal without a named cause ends the walk when no slot names the size"
    (Some F.Invalid_request)
    (F.ending_input_refusal [ F.Output_unusable; unnamed ]);
  ending "a walk without an input refusal has none" None
    (F.ending_input_refusal [ F.Output_unusable; F.Output_limit ])

let () =
  run "exact lane failure"
    [ ( "classes"
      , [ test_case "provider refusals" `Quick test_provider_refusals
        ; test_case "answers that cannot be used" `Quick test_answers_that_cannot_be_used
        ; test_case "completion failures" `Quick test_completion_failures
        ; test_case "a refusal that names the size ends the walk" `Quick
            test_a_refusal_that_names_the_size_ends_the_walk
        ; test_case "cli failures" `Quick test_cli_failures
        ; test_case "Antigravity noncompletion is not transient" `Quick
            test_antigravity_noncompletion_is_not_transient
        ; test_case "Antigravity refusal is not transient" `Quick
            test_antigravity_refusal_is_not_transient ] ) ]
