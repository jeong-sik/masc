(* Regression for the operator_disposition catch-all fall-through.

   A keeper turn cut off by its per-call turn cap ([MaxTurnsExceeded]), the
   wall-clock ceiling ([AgentExecutionTimeout]), or the progress-aware idle
   watchdog ([AgentExecutionIdleTimeout]) is auto-recoverable: the keeper
   checkpoints and the supervisor resumes. Before this fix those terminal
   reasons matched none of [operator_disposition]'s early branches and could
   be misread as a contract failure, falsely paging an operator while the
   keeper silently auto-resumed.

   The literal strings below are the exact wire form emitted by
   [Keeper_agent_error.agent_error_terminal_reason_code] (which now builds them
   from the same [terminal_prefix_*] constants the predicate matches, so the
   two cannot drift). Pinning the literals also guards wire compatibility with
   receipts persisted before the refactor. *)

module R = Masc.Keeper_execution_receipt

let failures = ref []
let check name cond = if not cond then failures := name :: !failures

(* Mirror [operator_disposition], which lower-cases terminal_reason_code. *)
let pred s = R.is_auto_recoverable_turn_budget_terminal (String.lowercase_ascii s)

let () =
  (* Budget/time cut-offs: auto-recoverable, must NOT page an operator. *)
  List.iter
    (fun s -> check ("expected-recoverable: " ^ s) (pred s))
    [ "agent_error_max_turns_exceeded:turns=8,limit=8"
    ; "agent_error_execution_timeout:elapsed_sec=120.0,timeout_sec=120.0,turn_count=7,max_turns=8"
    ; "agent_error_idle_timeout:idle_sec=120.0,idle_timeout_sec=120.0,turn_count=7,max_turns=8"
    ];
  (* Genuine ceilings and non-budget terminals must NOT be reclassified as
     transient — an operator should still see them. The prefix is precise:
     [idle_detected] is a distinct signal from [idle_timeout]. *)
  List.iter
    (fun s -> check ("expected-not-recoverable: " ^ s) (not (pred s)))
    [ "agent_error_token_budget_exceeded:kind=output,used=100,limit=50"
    ; "agent_error_cost_budget_exceeded:spent_usd=1.00,limit_usd=0.50"
    ; "turn_budget_exhausted:8/8"
    ; "agent_error_guardrail_violation:validator=x"
    ; "agent_error_tripwire_violation:tripwire=y"
    ; "agent_error_idle_detected:consecutive_idle_turns=3"
    ; "agent_error_exit_condition_met:turn=4"
    ; "api_error_timeout"
    ; "provider_error"
    ; "runtime_exhausted"
    ; "internal_error"
    ; "pre_dispatch_success"
    ];
  match !failures with
  | [] -> print_endline "test_keeper_disposition_budget: OK"
  | xs ->
    List.iter (fun n -> print_endline ("FAIL: " ^ n)) (List.rev xs);
    failwith
      (Printf.sprintf "%d disposition-budget assertion(s) failed" (List.length xs))
;;
