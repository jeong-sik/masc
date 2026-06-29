(* Keeper_pressure_admission SSOT + Keeper_pressure_admission_observer edge logic.

   Distinct from Keeper_turn_admission (RFC-0225 single-flight gate): this is the
   fd/disk resource-pressure composition that gates whether a turn is attempted
   at all. These pin the two load-bearing pure functions of the pressure-gate
   fix:

   1. [decide_with] composes the fd and disk circuit-breaker decisions with fd
      priority. The 2x2 product is matched explicitly (no [_ ->]); these cases
      are the revert-to-red guard for that exhaustiveness.
   2. [Keeper_pressure_admission_observer.classify] drives the edge-triggered
      WARN. The "repeat -> No_edge" case is the non-vacuous proof that a
      sustained stall logs once per episode, not once per cycle: deleting the
      same-kind guard in [classify] flips [test_repeat_block_no_edge] red.
   3. [admission_decision_of_snapshot] floor wiring: an available-bytes value
      far below the effective floor blocks; far above admits. Extreme values
      keep the assertion independent of the exact floor arithmetic. *)

open Alcotest
module PA = Keeper_pressure_admission
module Obs = Keeper_pressure_admission_observer
module Disk = Keeper_disk_pressure
module Fd = Keeper_fd_pressure

let decision_tag : PA.decision -> string = function
  | PA.Admitted -> "admitted"
  | PA.Blocked (PA.Fd _) -> "fd"
  | PA.Blocked (PA.Disk _) -> "disk"
;;

let fd_block = Fd.Block (Fd.Fd_pressure_cooldown 5.0)
let disk_block = Disk.Block (Disk.Disk_pressure_cooldown 5.0)

(* --- decide_with: 2x2 product, fd priority --- *)

let test_admit_admit () =
  check string "both admit -> admitted" "admitted"
    (decision_tag (PA.decide_with ~fd:Fd.Admit ~disk:Disk.Admit))
;;

let test_fd_block_disk_admit () =
  check string "fd blocks -> fd" "fd"
    (decision_tag (PA.decide_with ~fd:fd_block ~disk:Disk.Admit))
;;

let test_admit_disk_block () =
  check string "disk blocks -> disk" "disk"
    (decision_tag (PA.decide_with ~fd:Fd.Admit ~disk:disk_block))
;;

let test_both_block_fd_priority () =
  check string "both block -> fd priority" "fd"
    (decision_tag (PA.decide_with ~fd:fd_block ~disk:disk_block))
;;

(* --- observer classify: edge transitions --- *)

let edge_tag : Obs.edge -> string = function
  | Obs.No_edge -> "none"
  | Obs.Entered_block _ -> "entered"
  | Obs.Kind_changed _ -> "changed"
  | Obs.Resumed _ -> "resumed"
;;

let test_enter_block_edge () =
  let _phase, edge =
    Obs.classify
      ~prev:Obs.Admitting
      ~block:(Some { Obs.kind = "disk:x"; summary = "disk floor: free 1GiB < 40GiB" })
      ~now:100.0
  in
  check string "admitting -> blocked = entered" "entered" (edge_tag edge);
  (* The typed-edge invariant: a block edge carries the summary verbatim, so
     the log site needs no option fallback. *)
  match edge with
  | Obs.Entered_block { summary; _ } ->
    check string "entered edge carries block summary" "disk floor: free 1GiB < 40GiB"
      summary
  | _ -> fail "expected Entered_block"
;;

let test_repeat_block_no_edge () =
  (* The anti-flood guard: a second identical block must NOT re-log. *)
  let prev = Obs.Blocked_phase { kind = "disk:x"; since = 100.0 } in
  let _phase, edge =
    Obs.classify
      ~prev
      ~block:(Some { Obs.kind = "disk:x"; summary = "disk floor: free 1GiB < 40GiB" })
      ~now:130.0
  in
  check string "same-kind repeat = no edge" "none" (edge_tag edge)
;;

let test_kind_change_edge () =
  let prev = Obs.Blocked_phase { kind = "disk:x"; since = 100.0 } in
  let _phase, edge =
    Obs.classify
      ~prev
      ~block:(Some { Obs.kind = "fd:y"; summary = "fd budget exhausted" })
      ~now:130.0
  in
  check string "block reason change = changed" "changed" (edge_tag edge)
;;

let test_resume_edge () =
  let prev = Obs.Blocked_phase { kind = "disk:x"; since = 100.0 } in
  let phase, edge = Obs.classify ~prev ~block:None ~now:160.0 in
  check string "blocked -> admit = resumed" "resumed" (edge_tag edge);
  match phase with
  | Obs.Admitting -> ()
  | Obs.Blocked_phase _ -> fail "resume must return to Admitting"
;;

let test_admit_repeat_no_edge () =
  let _phase, edge = Obs.classify ~prev:Obs.Admitting ~block:None ~now:100.0 in
  check string "admit while admitting = no edge" "none" (edge_tag edge)
;;

(* --- disk floor wiring via admission_decision_of_snapshot --- *)

let gib n = n * 1024 * 1024 * 1024

let snapshot ~available_bytes ~total_bytes ~available_percent =
  Disk.Snapshot
    { path = "/test"
    ; filesystem = "testfs"
    ; total_bytes
    ; used_bytes = total_bytes - available_bytes
    ; available_bytes
    ; capacity_percent = 100.0 -. available_percent
    ; available_percent
    ; mounted_on = "/test"
    }
;;

let test_disk_below_floor_blocks () =
  Disk.For_testing.reset ();
  let snap =
    snapshot ~available_bytes:(gib 1) ~total_bytes:(gib 100) ~available_percent:1.0
  in
  let d = Disk.For_testing.admission_decision_of_snapshot snap in
  check string "1GiB free below floor -> disk block" "disk"
    (decision_tag (PA.decide_with ~fd:Fd.Admit ~disk:d))
;;

let test_disk_above_floor_admits () =
  Disk.For_testing.reset ();
  let snap =
    snapshot ~available_bytes:(gib 500) ~total_bytes:(gib 4000) ~available_percent:12.5
  in
  let d = Disk.For_testing.admission_decision_of_snapshot snap in
  check string "500GiB free above floor -> admitted" "admitted"
    (decision_tag (PA.decide_with ~fd:Fd.Admit ~disk:d))
;;

let () =
  run "keeper_pressure_admission"
    [ ( "decide_with"
      , [ test_case "admit+admit" `Quick test_admit_admit
        ; test_case "fd block, disk admit" `Quick test_fd_block_disk_admit
        ; test_case "admit, disk block" `Quick test_admit_disk_block
        ; test_case "both block -> fd priority" `Quick test_both_block_fd_priority
        ] )
    ; ( "observer-classify"
      , [ test_case "enter block edge" `Quick test_enter_block_edge
        ; test_case "repeat block = no edge (anti-flood)" `Quick test_repeat_block_no_edge
        ; test_case "kind change edge" `Quick test_kind_change_edge
        ; test_case "resume edge returns Admitting" `Quick test_resume_edge
        ; test_case "admit repeat = no edge" `Quick test_admit_repeat_no_edge
        ] )
    ; ( "disk-floor-wiring"
      , [ test_case "below floor blocks" `Quick test_disk_below_floor_blocks
        ; test_case "above floor admits" `Quick test_disk_above_floor_admits
        ] )
    ]
;;
