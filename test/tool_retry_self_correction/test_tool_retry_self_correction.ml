(* Regression guard for the keeper {}-tool-call livelock.

   A weak keeper model (e.g. deepseek-v4-flash on keeper "sangsu") emits
   [keeper_board_post_get {}] omitting the required [post_id], fails input
   validation, then recovers with a real post_id on a later re-prompt. The
   SDK's default policy ([max_retries = 2]) terminated the turn with
   [ToolRetryExhausted] at 2/2 — before the recovery attempt. masc now injects
   [Env_config_runtime.Tool_retry.validation_self_correction_ceiling] so
   validation errors keep re-prompting; runaway is bounded by the per-turn
   token budget + max_idle_turns, not this count. *)

module Trp = Agent_sdk.Tool_retry_policy

let ceiling = Env_config_runtime.Tool_retry.validation_self_correction_ceiling

let policy : Trp.t = { Trp.default_internal with max_retries = ceiling }

(* error_class is [Unknown], not the [classify Validation_error -> Deterministic]
   projection: [failure_enabled] short-circuits Deterministic failures to
   [No_retry] before the count matters, so the live retry path (which the user
   observed re-prompting "2/2") runs on a non-Deterministic class that defers to
   the [retry_on_validation_error] toggle. *)
let validation_failure : Trp.failure =
  { tool_name = "keeper_board_post_get"
  ; detail = "post_id: MISSING (required: string)"
  ; kind = Trp.Validation_error
  ; error_class = Trp.Unknown
  }

(* The old default killed the turn at exactly prior_retries = 2 (2/2). *)
let sdk_default_kill_point = 2

let test_ceiling_above_default_kill () =
  Alcotest.(check bool)
    "ceiling is above the SDK default 2/2 kill point"
    true
    (ceiling > sdk_default_kill_point)

let test_validation_retries_past_old_cap () =
  match Trp.decide ~policy ~prior_retries:sdk_default_kill_point [ validation_failure ] with
  | Trp.Retry _ -> ()
  | Trp.Exhausted _ ->
    Alcotest.fail "validation error still terminated at the old 2/2 cap"
  | Trp.No_retry -> Alcotest.fail "validation error must remain retryable"

let test_exhausts_only_at_ceiling () =
  (* prior_retries = ceiling -> retry_count = ceiling + 1 > max_retries -> Exhausted.
     The tripwire still fires as a last-ditch runaway guard. *)
  match Trp.decide ~policy ~prior_retries:ceiling [ validation_failure ] with
  | Trp.Exhausted _ -> ()
  | Trp.Retry _ | Trp.No_retry ->
    Alcotest.fail "ceiling must still exhaust as a runaway tripwire"

let () =
  Alcotest.run "tool_retry_self_correction"
    [ ( "self_correction"
      , [ Alcotest.test_case "ceiling above default kill" `Quick
            test_ceiling_above_default_kill
        ; Alcotest.test_case "retries past old 2/2 cap" `Quick
            test_validation_retries_past_old_cap
        ; Alcotest.test_case "exhausts only at ceiling" `Quick
            test_exhausts_only_at_ceiling
        ] )
    ]
