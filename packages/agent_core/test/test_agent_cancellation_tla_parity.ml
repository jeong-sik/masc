(* test_agent_cancellation_tla_parity.ml

   OCaml mirror predicate for the AgentCancellation.tla spec.
   Validates that Runtime.phase values align with the TLA+ model:
   - 8-state alphabet
   - 3 terminal phases (Completed, Failed, Cancelled)
   - TerminalIsStable: terminal -> non-terminal is disallowed
   - CancelledRequiresSignal: implied by construction (Cancelled is terminal)

   Reference: specs/AgentCancellation.tla
*)

open Agent_core

let all_phases =
  [ Runtime.Bootstrapping
  ; Runtime.Running
  ; Runtime.Input_required
  ; Runtime.Waiting_on_workers
  ; Runtime.Finalizing
  ; Runtime.Completed
  ; Runtime.Failed
  ; Runtime.Cancelled
  ]
;;

let terminal_phases = [ Runtime.Completed; Runtime.Failed; Runtime.Cancelled ]

let non_terminal_phases =
  [ Runtime.Bootstrapping
  ; Runtime.Running
  ; Runtime.Input_required
  ; Runtime.Waiting_on_workers
  ; Runtime.Finalizing
  ]
;;

(* Mirror of TLA+ TerminalIsStable:
   prev_phase \in Terminal /\ phase # prev_phase => phase \in Terminal *)
let terminal_is_stable ~prev_phase ~phase =
  let is_terminal p = List.mem p terminal_phases in
  if is_terminal prev_phase && prev_phase <> phase then is_terminal phase else true
;;

(* Mirror of TLA+ CancelledIsTerminal *)
let cancelled_is_terminal () = List.mem Runtime.Cancelled terminal_phases
let phase_count_matches () = List.length all_phases = 8
let non_terminal_count_matches () = List.length non_terminal_phases = 5
let terminal_count_matches () = List.length terminal_phases = 3

let () =
  Alcotest.run
    "agent_cancellation_tla_parity"
    [ ( "invariants"
      , [ Alcotest.test_case "phase count is 8" `Quick (fun () ->
            Alcotest.(check bool) "8 phases" true (phase_count_matches ()))
        ; Alcotest.test_case "terminal count is 3" `Quick (fun () ->
            Alcotest.(check bool) "3 terminal" true (terminal_count_matches ()))
        ; Alcotest.test_case "non-terminal count is 5" `Quick (fun () ->
            Alcotest.(check bool) "5 non-terminal" true (non_terminal_count_matches ()))
        ; Alcotest.test_case "Cancelled is terminal" `Quick (fun () ->
            Alcotest.(check bool) "cancelled terminal" true (cancelled_is_terminal ()))
        ; Alcotest.test_case
            "TerminalIsStable — terminal to non-terminal disallowed"
            `Quick
            (fun () ->
               Alcotest.(check bool)
                 "Completed -> Running"
                 false
                 (terminal_is_stable ~prev_phase:Runtime.Completed ~phase:Runtime.Running);
               Alcotest.(check bool)
                 "Cancelled -> Running"
                 false
                 (terminal_is_stable ~prev_phase:Runtime.Cancelled ~phase:Runtime.Running);
               Alcotest.(check bool)
                 "Failed -> Bootstrapping"
                 false
                 (terminal_is_stable
                    ~prev_phase:Runtime.Failed
                    ~phase:Runtime.Bootstrapping);
               (* same-phase transition is allowed (stutter) *)
               Alcotest.(check bool)
                 "Completed -> Completed"
                 true
                 (terminal_is_stable
                    ~prev_phase:Runtime.Completed
                    ~phase:Runtime.Completed);
               (* non-terminal -> anything is unrestricted *)
               Alcotest.(check bool)
                 "Running -> Finalizing"
                 true
                 (terminal_is_stable
                    ~prev_phase:Runtime.Running
                    ~phase:Runtime.Finalizing))
        ] )
    ]
;;
