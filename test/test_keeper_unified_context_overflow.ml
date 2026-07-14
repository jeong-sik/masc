open Alcotest

module EC = Masc.Keeper_error_classify
module UT = Masc.Keeper_unified_turn
module KP = Keeper_state_machine

let source_path path =
  if Filename.is_relative path then
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> Filename.concat root path
    | None -> path
  else path

let read_file path = In_channel.with_open_text (source_path path) In_channel.input_all

let contains_substring ~needle haystack =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else
    let rec loop index =
      index + needle_len <= haystack_len
      && (String.sub haystack index needle_len = needle || loop (index + 1))
    in
    loop 0

let index_of_substring ~needle haystack =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 then Some 0
  else
    let rec loop index =
      if index + needle_len > haystack_len then None
      else if String.sub haystack index needle_len = needle then Some index
      else loop (index + 1)
    in
    loop 0

let index_of_substring_from ~start ~needle haystack =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 then Some (max 0 start)
  else
    let rec loop index =
      if index + needle_len > haystack_len then None
      else if String.sub haystack index needle_len = needle then Some index
      else loop (index + 1)
    in
    loop (max 0 start)

(* context_overflow_limit is now in OAS as Retry.extract_context_limit.
   These tests verify the OAS SSOT API is accessible from MASC. *)
let test_context_overflow_limit_parses_common_oas_errors () =
  check
    (option int)
    "available context size extracted"
    (Some 159671)
    (Agent_sdk.Retry.extract_context_limit
       "OpenAI returned 400: This model's maximum context length is 128000 tokens. \
        However, your messages resulted in 193217 tokens. available context size \
        (159671)");
  check
    (option int)
    "input budget exceeded extracted"
    (Some 8192)
    (Agent_sdk.Retry.extract_context_limit
       "Agent run failed: Input token budget exceeded:\n  10847/8192");
  check
    (option int)
    "non-overflow message"
    None
    (Agent_sdk.Retry.extract_context_limit "HTTP error: 503 Service Unavailable")
;;

let test_is_context_overflow_only_for_overflow_errors () =
  check
    bool
    "ContextOverflow matches"
    true
    (EC.is_context_overflow
       (Agent_sdk.Error.Api (ContextOverflow { message = "exceeded"; limit = Some 32768 })));
  check
    bool
    "ContextOverflow without limit"
    true
    (EC.is_context_overflow
       (Agent_sdk.Error.Api (ContextOverflow { message = "exceeded"; limit = None })));
  check
    bool
    "NetworkError does not match"
    false
    (EC.is_context_overflow
       (Agent_sdk.Error.Api
          (NetworkError
             { message = "Connection_reset"
             ; kind = Llm_provider.Http_client.Connection_refused
             })));
  check
    bool
    "Internal does not match"
    false
    (EC.is_context_overflow (Agent_sdk.Error.Internal "some error"))
;;

(* ContextOverflow is routed as an explicit recoverable turn failure after OAS
   has exhausted its own compaction retry. It must not rewrite Keeper lifecycle. *)
let test_context_overflow_is_auto_recoverable () =
  check
    bool
    "ContextOverflow is auto-recoverable at turn level"
    true
    (EC.is_auto_recoverable_turn_error
       (Agent_sdk.Error.Api (ContextOverflow { message = "exceeded"; limit = Some 32768 })))
;;

let test_overflow_failure_contract_keeps_lifecycle_active () =
  let budget_src = read_file "lib/keeper/keeper_turn_runtime_budget.ml" in
  check bool "overflow failure latches typed evidence" true
    (contains_substring
       ~needle:"Some Keeper_registry.Turn_overflow_failure"
       budget_src);
  check bool "overflow failure explicitly keeps lifecycle active" true
    (contains_substring ~needle:"Keeper lifecycle remains active" budget_src);
  let execution_src = read_file "lib/keeper/keeper_unified_turn_execution.ml" in
  check bool "post-OAS retry overflow has dedicated phase label" true
    (contains_substring ~needle:"Context_overflow_after_oas_retry" execution_src);
  check bool "post-OAS retry overflow records failure" true
    (contains_substring ~needle:"record_overflow_failure" execution_src);
  check bool "overflow path has no paused-meta override" false
    (contains_substring ~needle:"paused_meta_override" execution_src)
;;

let test_preflight_overflow_does_not_bypass_driver_retry () =
  let agent_run_src = read_file "lib/keeper/keeper_agent_run.ml" in
  check bool "preflight observes context-window overflow" true
    (contains_substring ~needle:"pre_dispatch_over_context_window" agent_run_src);
  check bool "preflight overflow is not a pre-dispatch terminal error" true
    (match
       index_of_substring ~needle:"let pre_dispatch_error =" agent_run_src
     with
     | Some preflight ->
       (match
          ( index_of_substring_from
              ~start:preflight
              ~needle:"pre_dispatch_context_window_error"
              agent_run_src
          , index_of_substring_from
              ~start:preflight
              ~needle:"let call_run_named ?raw_trace ~initial_messages () ="
              agent_run_src
          )
        with
        | Some context_error_use, Some driver -> driver < context_error_use
        | None, Some _driver -> true
        | _ -> false)
     | None -> false);
  let execution_src = read_file "lib/keeper/keeper_unified_turn_execution.ml" in
  check bool "overflow branch stamps current turn blocker" true
    (contains_substring ~needle:"current_turn_blocker_info =" execution_src);
  check bool "overflow blocker uses typed context-window class" true
    (contains_substring
       ~needle:"Keeper_meta_contract.blocker_info_of_class"
       execution_src
     && contains_substring ~needle:"Sdk_context_window_exceeded" execution_src);
  check bool "overflow branch records failure without pause" true
    (contains_substring ~needle:"record_overflow_failure" execution_src)
;;

let () =
  run
    "keeper_unified_context_overflow"
    [ ( "context_overflow"
      , [ test_case
            "parses common OAS overflow errors (SSOT)"
            `Quick
            test_context_overflow_limit_parses_common_oas_errors
        ; test_case
            "is_context_overflow only matches ContextOverflow"
            `Quick
            test_is_context_overflow_only_for_overflow_errors
        ; test_case
            "context overflow is auto-recoverable"
            `Quick
            test_context_overflow_is_auto_recoverable
        ; test_case
            "overflow failure keeps lifecycle active"
            `Quick
            test_overflow_failure_contract_keeps_lifecycle_active
        ; test_case
            "preflight overflow does not bypass driver retry"
            `Quick
            test_preflight_overflow_does_not_bypass_driver_retry
        ] )
    ]
;;
