(** #10318 — pin the cost ledger source-attribution contract.

    Pre-fix [costs.jsonl] showed 100% [cost_usd=0] across 1697
    entries.  Each missing/reporting path (missing usage,
    AGENT_CORE cost omission, structurally-unmetered runtime, actual
    zero-token call) collapsed to the same [0.0] field with no
    way for an operator to distinguish "tracking is broken" from
    "this runtime is unmetered" from "AGENT_CORE did not report cost".
    Without that distinction the operator
    can't pick the right next action: A (audit) vs C (pricing
    SSOT) vs E (cross-link to #9959) all need different evidence.

    These tests pin the [missing_usage] label the ledger writes and the
    token evidence behind it. Precedence is fixed (top-down) in
    [Keeper_hooks_agent_core.classify_cost_usd_source] so a missing-usage
    call on a pricing-known model still labels [missing_usage], not
    [agent_core_cost_unreported] — the upstream signal is the more
    actionable failure mode. The [computed] and
    [agent_core_cost_unreported] labels are checked through the real
    payload in test_cost_token_decouple. *)

open Alcotest

module H = Masc.Keeper_hooks_agent_core

let check_source ~msg ~usage_missing ~runtime_unmetered
    ~cost_usd expected =
  let actual =
    H.classify_cost_usd_source ~usage_missing ~runtime_unmetered ~cost_usd
  in
  check string msg expected actual

(* --- precedence: top-down ordering ------------------------------ *)

let test_missing_usage_wins_over_everything () =
  (* Even with a known-priced model and a positive cost number, an
     upstream missing-usage signal must dominate — that's the
     more-actionable failure mode (provider adapter didn't surface
     usage at all). *)
  check_source
    ~msg:"missing_usage even with priced model + positive cost"
    ~usage_missing:true
    ~runtime_unmetered:false
    ~cost_usd:0.42
    "missing_usage"

(* --- usage evidence ------------------------------------------------ *)

let test_hook_usage_missing_uses_token_evidence () =
  let cost_only : Agent_core.Types.api_usage =
    { Agent_core.Types.zero_api_usage with cost_usd = Some 0.25 }
  in
  let cache_creation_only : Agent_core.Types.api_usage =
    { Agent_core.Types.zero_api_usage with cache_creation_input_tokens = 1 }
  in
  check bool "cost-only Some usage remains missing" true
    (H.For_testing.usage_missing_of_usage (Some cost_only));
  check bool "cache creation is genuine usage" false
    (H.For_testing.usage_missing_of_usage (Some cache_creation_only))

let test_cost_only_usage_trust_matches_missing () =
  (* Pricing-observation firewall: a cost-only turn must not serialize the
     contradictory pair usage_trust=trusted + usage_missing=true.  Trust
     classification delegates to the same token evidence as
     [usage_missing_of_usage]. *)
  let cost_only : Agent_core.Types.api_usage =
    { Agent_core.Types.zero_api_usage with cost_usd = Some 0.25 }
  in
  let real_usage : Agent_core.Types.api_usage =
    { Agent_core.Types.zero_api_usage with
      input_tokens = 10;
      output_tokens = 5;
    }
  in
  check string "cost-only usage is missing, not trusted" "missing"
    (Keeper_usage_trust.to_string (H.classify_usage_trust ~usage:cost_only ()));
  check string "token usage stays trusted" "trusted"
    (Keeper_usage_trust.to_string (H.classify_usage_trust ~usage:real_usage ()));
  check string "absent usage is missing" "missing"
    (Keeper_usage_trust.to_string (H.classify_usage_trust ()))

let () =
  run "cost_usd_source_attribution_10318"
    [
      ( "precedence",
        [
          test_case "missing_usage wins over everything" `Quick
            test_missing_usage_wins_over_everything;
        ] );
      ( "canonical-paths",
        [
          test_case "hook usage missing uses token evidence" `Quick
            test_hook_usage_missing_uses_token_evidence;
          test_case "cost-only usage trust matches missing" `Quick
            test_cost_only_usage_trust_matches_missing;
        ] );
    ]
