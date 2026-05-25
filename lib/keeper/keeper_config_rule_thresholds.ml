(** Keeper_config_rule_thresholds — Rule engine similarity/alignment thresholds.

    Extracted from [Keeper_config] during godfile decomposition.
    All thresholds are [Runtime_params]-backed floats in [0.0, 1.0].

    @since God file decomposition *)

open Keeper_config_rp_helpers

(* ================================================================ *)
(* Rule engine thresholds                                           *)
(* ================================================================ *)

let keeper_rule_reflect_repetition_rp =
  _rp_float ~key:"keeper.rule.reflect_repetition"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_RULE_REFLECT_REPETITION"
                          ~default:0.86 ~min_v:0.0 ~max_v:1.0)
    ~min_v:0.0 ~max_v:1.0
    ~description:"Reflect rule: repetition similarity threshold" ()
let keeper_rule_reflect_repetition_threshold () : float =
  Runtime_params.get keeper_rule_reflect_repetition_rp

let keeper_rule_plan_goal_alignment_rp =
  _rp_float ~key:"keeper.rule.plan_goal_alignment_max"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_RULE_PLAN_GOAL_ALIGNMENT_MAX"
                          ~default:0.06 ~min_v:0.0 ~max_v:1.0)
    ~min_v:0.0 ~max_v:1.0
    ~description:"Plan rule: goal alignment max distance" ()
let keeper_rule_plan_goal_alignment_threshold () : float =
  Runtime_params.get keeper_rule_plan_goal_alignment_rp

let keeper_rule_plan_response_alignment_rp =
  _rp_float ~key:"keeper.rule.plan_response_alignment_max"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_RULE_PLAN_RESPONSE_ALIGNMENT_MAX"
                          ~default:0.10 ~min_v:0.0 ~max_v:1.0)
    ~min_v:0.0 ~max_v:1.0
    ~description:"Plan rule: response alignment max distance" ()
let keeper_rule_plan_response_alignment_threshold () : float =
  Runtime_params.get keeper_rule_plan_response_alignment_rp

let keeper_rule_guardrail_repetition_rp =
  _rp_float ~key:"keeper.rule.guardrail_repetition"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_RULE_GUARDRAIL_REPETITION"
                          ~default:0.90 ~min_v:0.0 ~max_v:1.0)
    ~min_v:0.0 ~max_v:1.0
    ~description:"Guardrail rule: repetition similarity threshold" ()
let keeper_rule_guardrail_repetition_threshold () : float =
  Runtime_params.get keeper_rule_guardrail_repetition_rp

let keeper_rule_guardrail_goal_alignment_rp =
  _rp_float ~key:"keeper.rule.guardrail_goal_alignment_max"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_RULE_GUARDRAIL_GOAL_ALIGNMENT_MAX"
                          ~default:0.04 ~min_v:0.0 ~max_v:1.0)
    ~min_v:0.0 ~max_v:1.0
    ~description:"Guardrail rule: goal alignment max distance" ()
let keeper_rule_guardrail_goal_alignment_threshold () : float =
  Runtime_params.get keeper_rule_guardrail_goal_alignment_rp

let keeper_rule_guardrail_response_alignment_rp =
  _rp_float ~key:"keeper.rule.guardrail_response_alignment_max"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_RULE_GUARDRAIL_RESPONSE_ALIGNMENT_MAX"
                          ~default:0.08 ~min_v:0.0 ~max_v:1.0)
    ~min_v:0.0 ~max_v:1.0
    ~description:"Guardrail rule: response alignment max distance" ()
let keeper_rule_guardrail_response_alignment_threshold () : float =
  Runtime_params.get keeper_rule_guardrail_response_alignment_rp

let keeper_rule_guardrail_context_rp =
  _rp_float ~key:"keeper.rule.guardrail_context_min"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_RULE_GUARDRAIL_CONTEXT_MIN"
                          ~default:0.70 ~min_v:0.0 ~max_v:1.0)
    ~min_v:0.0 ~max_v:1.0
    ~description:"Guardrail rule: minimum context ratio" ()
let keeper_rule_guardrail_context_threshold () : float =
  Runtime_params.get keeper_rule_guardrail_context_rp
