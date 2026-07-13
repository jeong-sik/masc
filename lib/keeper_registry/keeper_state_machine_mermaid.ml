(* Keeper state-machine -> Mermaid stateDiagram-v2 rendering.

   Used by the dashboard FSM diagnostic panel. Pure mapping over the
   [Keeper_state_machine.phase] type - no I/O, no shared state.

   Extracted from [Keeper_state_machine] (godfile decomp). Note: no
   reverse alias in [Keeper_state_machine] - external callers reference
   this module directly to avoid the wrapped-library import cycle
   recorded in memory/feedback. *)

open Keeper_state_machine

let phase_to_mermaid_id = function
  | Offline -> "Offline"
  | Running -> "Running"
  | Failing -> "Failing"
  | Overflowed -> "Overflowed"
  | Compacting -> "Compacting"
  | HandingOff -> "HandingOff"
  | Draining -> "Draining"
  | Paused -> "Paused"
  | Stopped -> "Stopped"
  | Crashed -> "Crashed"
  | Restarting -> "Restarting"
  | Dead -> "Dead"
;;

let phase_to_mermaid ~(current : phase) : string =
  let b = Buffer.create 512 in
  let p fmt = Printf.bprintf b fmt in
  p "stateDiagram-v2\n";
  (* Phase nodes with display names *)
  p "    [*] --> Offline\n";
  p "    Offline --> Running : Fiber_started\n";
  p "    Offline --> Draining : stop requested\n";
  p "    Offline --> Stopped : stop while not started\n";
  p "    Running --> Failing : hb/turn/reconcile fail\n";
  p "    Running --> Overflowed : prompt exceeded max context\n";
  p "    Running --> Compacting : compact start\n";
  p "    Running --> HandingOff : handoff start\n";
  p "    Running --> Draining : stop requested\n";
  p "    Running --> Paused : operator pause\n";
  p "    Running --> Stopped : stop requested\n";
  p "    Running --> Crashed : fiber death\n";
  p "    Failing --> Running : clean turn recovery\n";
  p "    Failing --> Overflowed : prompt exceeded max context\n";
  p "    Failing --> Crashed : fiber death\n";
  p "    Failing --> Draining : stop requested\n";
  p "    Failing --> Paused : operator pause\n";
  p "    Overflowed --> Running : operator clear\n";
  p "    Overflowed --> Compacting : auto-compact\n";
  p "    Overflowed --> Paused : operator pause\n";
  p "    Overflowed --> Draining : stop requested\n";
  p "    Overflowed --> Crashed : fiber death\n";
  p "    Compacting --> Running : compact done\n";
  p "    Compacting --> Overflowed : compact failed (overflow persists)\n";
  p "    Compacting --> Failing : hb fail\n";
  p "    Compacting --> Crashed : fiber death\n";
  p "    Compacting --> Draining : stop requested\n";
  p "    HandingOff --> Running : handoff done\n";
  p "    HandingOff --> Failing : hb fail\n";
  p "    HandingOff --> Crashed : fiber death\n";
  p "    HandingOff --> Draining : stop requested\n";
  p "    Draining --> Stopped : drain done\n";
  p "    Draining --> Crashed : fiber death\n";
  p "    Paused --> Running : operator resume\n";
  p "    Paused --> Compacting : operator compact\n";
  p "    Paused --> Draining : stop requested\n";
  p "    Paused --> Stopped : stop requested\n";
  p "    Paused --> Crashed : fiber death\n";
  p "    Crashed --> Restarting : backoff elapsed\n";
  p "    Crashed --> Dead : explicit durable tombstone\n";
  p "    Restarting --> Running : fiber started\n";
  p "    Restarting --> Crashed : launch fail\n";
  p "    Restarting --> Dead : explicit durable tombstone\n";
  p "    Restarting --> Draining : stop requested\n";
  p "    Restarting --> Paused : operator pause\n";
  p "    Stopped --> [*]\n";
  p "    Dead --> [*]\n";
  (* Highlight current phase with classDef *)
  p "\n";
  p "    classDef active fill:#22c55e,stroke:#16a34a,color:#fff,stroke-width:3px\n";
  p "    classDef terminal fill:#6b7280,stroke:#4b5563,color:#fff\n";
  p "    classDef buffer fill:#f59e0b,stroke:#d97706,color:#fff\n";
  (match current with
   | Stopped | Dead ->
     p "    class %s terminal\n" (phase_to_mermaid_id current)
   | Failing | Overflowed | Compacting | HandingOff | Draining | Restarting | Crashed ->
     p "    class %s buffer\n" (phase_to_mermaid_id current)
   | Running | Offline | Paused ->
     p "    class %s active\n" (phase_to_mermaid_id current));
  Buffer.contents b
;;
