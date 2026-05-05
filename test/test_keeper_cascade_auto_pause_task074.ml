(** task-074 — pin the two predicates the cascade auto-pause guard at
    [keeper_unified_turn.ml:~2226] depends on, so future drift breaks
    this test before the fleet starts looping the supervisor restart
    cycle again ("초반에만 반짝" symptom).

    The guard is:

    {v
      cascade_auto_paused =
        EC.is_cascade_exhausted_error err
        && count >= Keeper_behavioral_regime.turn_fail_streak_threshold
        && not updated_meta.paused
    v}

    Two load-bearing facts that this test pins:

    1. [is_cascade_exhausted_error] returns [true] for the variants that
       a misconfigured / unavailable cascade actually emits, and [false]
       for transient errors that are already retried at a lower layer
       (otherwise auto-pause would fire on a single 429).

    2. [turn_fail_streak_threshold] is < [keeper_max_turn_failures]
       default, so the pause path actually fires *before* the crash
       escalation that raises [Keeper_fiber_crash] and triggers the
       supervisor restart loop the guard was added to break. *)

open Alcotest
module EC = Masc_mcp.Keeper_error_classify
module Owne = Masc_mcp.Oas_worker_named
module KT = Masc_mcp.Keeper_types
module Regime = Masc_mcp.Keeper_behavioral_regime
module UT = Masc_mcp.Keeper_unified_turn

let cascade_name raw = Owne.cascade_name_of_string raw

(* --- 1. is_cascade_exhausted_error covers the variants auto-pause cares about --- *)

let mk_cascade_exhausted () =
  Owne.sdk_error_of_masc_internal_error
    (Owne.Cascade_exhausted
       { cascade_name = cascade_name "test"; reason = KT.All_providers_failed })

let mk_no_tool_capable () =
  Owne.sdk_error_of_masc_internal_error
    (Owne.No_tool_capable_provider
       { cascade_name = cascade_name "test"; configured_labels = [] })

let mk_accept_rejected () =
  Owne.sdk_error_of_masc_internal_error
    (Owne.Accept_rejected { scope = "test"; model = None; reason = "x" })

let mk_resumable_cli_session () =
  Owne.sdk_error_of_masc_internal_error
    (Owne.Resumable_cli_session
       { cascade_name = cascade_name "test";
         detail = "rollout-thread-not-found";
         exit_code = Some 1 })

let test_pause_fires_on_cascade_exhausted_variants () =
  check bool "Cascade_exhausted -> pause" true
    (EC.is_cascade_exhausted_error (mk_cascade_exhausted ()));
  check bool "No_tool_capable_provider -> pause" true
    (EC.is_cascade_exhausted_error (mk_no_tool_capable ()));
  check bool "Accept_rejected -> pause" true
    (EC.is_cascade_exhausted_error (mk_accept_rejected ()));
  check bool "Resumable_cli_session -> pause" true
    (EC.is_cascade_exhausted_error (mk_resumable_cli_session ()))

(* --- 2. is_cascade_exhausted_error stays false for transient/timeout variants ---
   If this regresses, a single 429 + 2 prior unrelated failures would
   flip the keeper to paused on its first transient error of the streak. *)

let mk_oas_timeout_budget () =
  Owne.sdk_error_of_masc_internal_error
    (Owne.Oas_timeout_budget
       { budget_sec = 30.0;
         keeper_turn_timeout_sec = 60.0;
         estimated_input_tokens = 1000;
         source = "test" })

let mk_turn_timeout () =
  Owne.sdk_error_of_masc_internal_error
    (Owne.Turn_timeout { elapsed_sec = 60.0 })

let mk_admission_queue_timeout () =
  Owne.sdk_error_of_masc_internal_error
    (Owne.Admission_queue_timeout
       { keeper_name = "test_keeper";
         cascade_name = cascade_name "test";
         wait_sec = 5.0 })

let mk_required_tool_contract_violation () =
  Agent_sdk.Error.Agent
    (Agent_sdk.Error.CompletionContractViolation
       {
         contract = Agent_sdk.Completion_contract_id.Require_tool_use;
         reason =
           "required tool contract unsatisfied: tool_choice requested tool use, but the model returned no ToolUse block";
       })

let test_pause_does_not_fire_on_transient () =
  check bool "Oas_timeout_budget -> no pause" false
    (EC.is_cascade_exhausted_error (mk_oas_timeout_budget ()));
  check bool "Turn_timeout -> no pause" false
    (EC.is_cascade_exhausted_error (mk_turn_timeout ()));
  check bool "Admission_queue_timeout -> no pause" false
    (EC.is_cascade_exhausted_error (mk_admission_queue_timeout ()))

(* --- 3. threshold ordering: pause fires before crash --- *)

let test_threshold_pin () =
  (* Auto-pause uses [turn_fail_streak_threshold] (=3) so the pause path
     intercepts the failing keeper before the crash escalation at
     [keeper_max_turn_failures] (default 5). If someone bumps
     [turn_fail_streak_threshold] above the crash threshold the guard
     becomes dead code — this test catches that drift. *)
  check int "turn_fail_streak_threshold pinned at 3"
    3 Regime.turn_fail_streak_threshold;
  check bool "pause threshold strictly less than crash threshold default 5"
    true
    (Regime.turn_fail_streak_threshold < 5)

(* --- 4. behavioral regime regards 3 failures of the cascade-class as Thrashing,
   which is the qualitative signal the guard escalates to a hard pause for. --- *)

let test_regime_flips_to_thrashing_at_threshold () =
  let input : Regime.input = {
    turn_consecutive_failures = Regime.turn_fail_streak_threshold;
    restart_count = 0;
    last_restart_ts = 0.0;
    tool_aggregates = [];
  } in
  let snapshot = Regime.derive ~now:0.0 input in
  check string "regime -> thrashing"
    "thrashing" (Regime.string_of_regime snapshot.regime);
  check string "rule_id -> turn_fail_streak"
    "turn_fail_streak" snapshot.reason.rule_id

let test_required_tool_contract_pause_guard () =
  let violation = mk_required_tool_contract_violation () in
  check bool "below threshold -> no pause" false
    (UT.should_auto_pause_required_tool_contract_violation
       ~paused:false
       ~consecutive_failures:(Regime.turn_fail_streak_threshold - 1)
       violation);
  check bool "threshold -> pause" true
    (UT.should_auto_pause_required_tool_contract_violation
       ~paused:false
       ~consecutive_failures:Regime.turn_fail_streak_threshold
       violation);
  check bool "already paused -> no duplicate pause" false
    (UT.should_auto_pause_required_tool_contract_violation
       ~paused:true
       ~consecutive_failures:Regime.turn_fail_streak_threshold
       violation);
  check bool "non contract error -> no pause" false
    (UT.should_auto_pause_required_tool_contract_violation
       ~paused:false
       ~consecutive_failures:Regime.turn_fail_streak_threshold
       (mk_oas_timeout_budget ()))

let () =
  run "keeper_cascade_auto_pause_task074"
    [
      ( "predicate covers cascade-class errors",
        [
          test_case "cascade variants trigger pause" `Quick
            test_pause_fires_on_cascade_exhausted_variants;
          test_case "transient variants do not trigger pause" `Quick
            test_pause_does_not_fire_on_transient;
        ] );
      ( "threshold ordering",
        [
          test_case "pause threshold < crash default" `Quick test_threshold_pin;
          test_case "regime flip at threshold" `Quick
            test_regime_flips_to_thrashing_at_threshold;
        ] );
      ( "required-tool contract pause",
        [
          test_case "required contract loops pause before crash" `Quick
            test_required_tool_contract_pause_guard;
        ] );
    ]
