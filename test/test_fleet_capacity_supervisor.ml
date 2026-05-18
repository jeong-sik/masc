open Alcotest
open Masc_mcp
module Sup = Keeper_fleet_capacity_supervisor

let base_obs : Sup.observation =
  { running_keeper_fiber_count = 5
  ; target_reaction_capacity_count = 5
  ; minimum_running_fibers = 2
  ; reaction_capacity_shortfall_count = 0
  ; admission_blocked_count = 0
  ; admission_queue_saturated_cap = 10
  ; disk_pressure_active = false
  ; fd_pressure_active = false
  ; cold_start_in_progress = false
  ; now = 1000.0
  ; last_action_at = None
  ; cooldown_seconds = 60.0
  }
;;

let is_spawn = function
  | Sup.Spawn _ -> true
  | _ -> false
;;

let is_backpressure = function
  | Sup.Backpressure _ -> true
  | _ -> false
;;

let is_noop = function
  | Sup.Noop _ -> true
  | _ -> false
;;

let spawn_reason = function
  | Sup.Spawn { reason; _ } -> Some reason
  | _ -> None
;;

let backpressure_reason = function
  | Sup.Backpressure r -> Some r
  | _ -> None
;;

let noop_reason = function
  | Sup.Noop r -> Some r
  | _ -> None
;;

(* §1. Single-rule tests — each priority level fires correctly in isolation. *)

let test_disk_pressure_highest () =
  let obs =
    { base_obs with
      disk_pressure_active = true
    ; reaction_capacity_shortfall_count = 10  (* would otherwise spawn *)
    }
  in
  check
    (option (testable Fmt.nop ( = )))
    "disk pressure wins over shortfall"
    (Some Sup.Backpressure_reason.Disk_pressure_active)
    (backpressure_reason (Sup.tick obs))
;;

let test_fd_pressure_over_shortfall () =
  let obs =
    { base_obs with fd_pressure_active = true; reaction_capacity_shortfall_count = 10 }
  in
  check
    (option (testable Fmt.nop ( = )))
    "fd pressure wins over shortfall"
    (Some Sup.Backpressure_reason.Fd_pressure_active)
    (backpressure_reason (Sup.tick obs))
;;

let test_admission_queue_saturated () =
  let obs = { base_obs with admission_blocked_count = 20; admission_queue_saturated_cap = 10 } in
  check
    (option (testable Fmt.nop ( = )))
    "blocked > cap → saturated backpressure"
    (Some Sup.Backpressure_reason.Admission_queue_saturated)
    (backpressure_reason (Sup.tick obs))
;;

let test_cooldown_blocks_action () =
  let obs =
    { base_obs with
      reaction_capacity_shortfall_count = 5  (* would otherwise spawn *)
    ; last_action_at = Some 980.0
    ; now = 1000.0
    ; cooldown_seconds = 60.0  (* 1000 - 980 = 20 < 60 *)
    }
  in
  check
    (option (testable Fmt.nop ( = )))
    "cooldown gate fires"
    (Some Sup.Noop_reason.Already_recently_acted)
    (noop_reason (Sup.tick obs))
;;

let test_cooldown_elapsed_allows_spawn () =
  let obs =
    { base_obs with
      reaction_capacity_shortfall_count = 5
    ; last_action_at = Some 900.0
    ; now = 1000.0
    ; cooldown_seconds = 60.0  (* 100 >= 60 *)
    }
  in
  check bool "cooldown elapsed → spawn allowed" true (is_spawn (Sup.tick obs))
;;

let test_cold_start_spawn () =
  let obs = { base_obs with cold_start_in_progress = true; reaction_capacity_shortfall_count = 3 } in
  check
    (option (testable Fmt.nop ( = )))
    "cold start → recovery spawn"
    (Some Sup.Spawn_reason.Recovery_from_cold_start)
    (spawn_reason (Sup.tick obs))
;;

let test_below_minimum_fibers () =
  let obs =
    { base_obs with
      running_keeper_fiber_count = 1
    ; minimum_running_fibers = 3
    ; reaction_capacity_shortfall_count = 0
    }
  in
  check
    (option (testable Fmt.nop ( = )))
    "below minimum → margin breach spawn"
    (Some Sup.Spawn_reason.Below_minimum_running_fibers)
    (spawn_reason (Sup.tick obs))
;;

let test_below_target_shortfall_spawn () =
  let obs =
    { base_obs with
      running_keeper_fiber_count = 3
    ; target_reaction_capacity_count = 13
    ; minimum_running_fibers = 2
    ; reaction_capacity_shortfall_count = 10
    }
  in
  match Sup.tick obs with
  | Sup.Spawn { reason = Below_target_reaction_capacity; suggested_keeper_count } ->
    check int "suggested matches shortfall" 10 suggested_keeper_count
  | other ->
    failf "expected Spawn Below_target, got %s" (Sup.decision_to_string other)
;;

let test_capacity_at_target_noop () =
  let obs = { base_obs with running_keeper_fiber_count = 5; target_reaction_capacity_count = 5 } in
  check
    (option (testable Fmt.nop ( = )))
    "running = target → at_target noop"
    (Some Sup.Noop_reason.Capacity_at_target)
    (noop_reason (Sup.tick obs))
;;

let test_capacity_above_target_noop () =
  let obs = { base_obs with running_keeper_fiber_count = 7; target_reaction_capacity_count = 5 } in
  check
    (option (testable Fmt.nop ( = )))
    "running > target → above_target noop"
    (Some Sup.Noop_reason.Capacity_above_target)
    (noop_reason (Sup.tick obs))
;;

(* §2. Property checks — invariants over generated observations. *)

let make_obs ~running ~target ~min_fibers ~shortfall ~blocked ~disk ~fd ~cold ~last =
  { base_obs with
    running_keeper_fiber_count = running
  ; target_reaction_capacity_count = target
  ; minimum_running_fibers = min_fibers
  ; reaction_capacity_shortfall_count = shortfall
  ; admission_blocked_count = blocked
  ; disk_pressure_active = disk
  ; fd_pressure_active = fd
  ; cold_start_in_progress = cold
  ; last_action_at = last
  }
;;

let test_prop_pressure_always_backpressure () =
  (* ∀ obs. (disk ∨ fd) ⇒ tick obs ∈ Backpressure *)
  let cases =
    [ (* (disk, fd) combos with all other dimensions varied *)
      true, false, 0, 0, 0
    ; false, true, 0, 0, 0
    ; true, true, 100, 100, 100
    ; true, false, 5, 13, 10
    ; false, true, 1, 13, 12
    ]
  in
  List.iter
    (fun (disk, fd, running, target, shortfall) ->
       let obs =
         make_obs
           ~running
           ~target
           ~min_fibers:2
           ~shortfall
           ~blocked:0
           ~disk
           ~fd
           ~cold:false
           ~last:None
       in
       check
         bool
         (Printf.sprintf
            "pressure (disk=%b, fd=%b, run=%d) → backpressure"
            disk
            fd
            running)
         true
         (is_backpressure (Sup.tick obs)))
    cases
;;

let test_prop_shortfall_clean_spawns () =
  (* ∀ obs. shortfall > 0 ∧ ¬pressure ∧ cooldown_elapsed ∧ ¬cold_start
           ⇒ tick obs ∈ Spawn Below_target_reaction_capacity *)
  let cases = [ 1; 2; 5; 10; 100 ] in
  List.iter
    (fun shortfall ->
       let obs =
         make_obs
           ~running:5
           ~target:(5 + shortfall)
           ~min_fibers:2
           ~shortfall
           ~blocked:0
           ~disk:false
           ~fd:false
           ~cold:false
           ~last:None
       in
       check
         (option (testable Fmt.nop ( = )))
         (Printf.sprintf "clean shortfall=%d → spawn Below_target" shortfall)
         (Some Sup.Spawn_reason.Below_target_reaction_capacity)
         (spawn_reason (Sup.tick obs)))
    cases
;;

let test_prop_admission_blocked_over_cap () =
  (* ∀ obs. admission_blocked > cap ∧ ¬disk ∧ ¬fd
           ⇒ tick obs = Backpressure Admission_queue_saturated *)
  let cases = [ 11, 10; 100, 50; 1, 0 ] in
  List.iter
    (fun (blocked, cap) ->
       let obs =
         { base_obs with
           admission_blocked_count = blocked
         ; admission_queue_saturated_cap = cap
         }
       in
       check
         (option (testable Fmt.nop ( = )))
         (Printf.sprintf "blocked=%d cap=%d → saturated" blocked cap)
         (Some Sup.Backpressure_reason.Admission_queue_saturated)
         (backpressure_reason (Sup.tick obs)))
    cases
;;

let test_prop_totality () =
  (* tick is total: every input produces a non-exception decision. *)
  let extremes =
    [ -1000, -1000, -1000, -1000, -1000
    ; 0, 0, 0, 0, 0
    ; 1, 1, 1, 1, 1
    ; max_int, max_int, max_int, max_int, max_int
    ; -1, 0, 0, 0, 0
    ; 0, -1, 0, 0, 0
    ]
  in
  List.iter
    (fun (run, target, min_fib, short, blocked) ->
       let obs =
         make_obs
           ~running:run
           ~target
           ~min_fibers:min_fib
           ~shortfall:short
           ~blocked
           ~disk:false
           ~fd:false
           ~cold:false
           ~last:None
       in
       let _ : Sup.decision = Sup.tick obs in
       ())
    extremes
;;

(* §3. Decision string formatting (used by /health JSON emitter in PR-3). *)

let test_decision_to_string () =
  check
    string
    "spawn"
    "spawn(reason=below_target_reaction_capacity,count=3)"
    (Sup.decision_to_string
       (Sup.Spawn
          { reason = Sup.Spawn_reason.Below_target_reaction_capacity
          ; suggested_keeper_count = 3
          }));
  check
    string
    "backpressure"
    "backpressure(disk_pressure_active)"
    (Sup.decision_to_string (Sup.Backpressure Sup.Backpressure_reason.Disk_pressure_active));
  check
    string
    "noop"
    "noop(capacity_at_target)"
    (Sup.decision_to_string (Sup.Noop Sup.Noop_reason.Capacity_at_target))
;;

let () =
  run
    "fleet_capacity_supervisor"
    [ ( "priority order"
      , [ test_case "disk pressure highest" `Quick test_disk_pressure_highest
        ; test_case "fd over shortfall" `Quick test_fd_pressure_over_shortfall
        ; test_case "admission saturated" `Quick test_admission_queue_saturated
        ; test_case "cooldown blocks" `Quick test_cooldown_blocks_action
        ; test_case "cooldown elapsed allows" `Quick test_cooldown_elapsed_allows_spawn
        ; test_case "cold start spawn" `Quick test_cold_start_spawn
        ; test_case "below minimum spawn" `Quick test_below_minimum_fibers
        ; test_case "below target spawn" `Quick test_below_target_shortfall_spawn
        ; test_case "at target noop" `Quick test_capacity_at_target_noop
        ; test_case "above target noop" `Quick test_capacity_above_target_noop
        ] )
    ; ( "properties"
      , [ test_case "pressure ⇒ backpressure" `Quick test_prop_pressure_always_backpressure
        ; test_case "clean shortfall ⇒ spawn" `Quick test_prop_shortfall_clean_spawns
        ; test_case "blocked > cap ⇒ saturated" `Quick test_prop_admission_blocked_over_cap
        ; test_case "tick is total" `Quick test_prop_totality
        ] )
    ; "formatting", [ test_case "decision_to_string" `Quick test_decision_to_string ]
    ]
;;
