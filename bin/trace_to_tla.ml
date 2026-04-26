(** trace_to_tla — Convert .tla-trace.jsonl to TraceData.tla for TLC trace validation.

    Usage: trace_to_tla <input.jsonl> [output.tla]
    If output is omitted, writes to specs/keeper-state-machine/TraceData.tla *)

let bool_to_tla b = if b then "TRUE" else "FALSE"

let get_bool json key =
  match Yojson.Safe.Util.member key json with
  | `Bool b -> b
  | _ -> false
;;

let get_int json key =
  match Yojson.Safe.Util.member key json with
  | `Int n -> n
  | _ -> 0
;;

let get_string json key =
  match Yojson.Safe.Util.member key json with
  | `String s -> s
  | _ -> ""
;;

let tla_phase = function
  | "offline" -> "Offline"
  | "running" -> "Running"
  | "failing" -> "Failing"
  | "overflowed" -> "Overflowed"
  | "compacting" -> "Compacting"
  | "handing_off" -> "HandingOff"
  | "draining" -> "Draining"
  | "paused" -> "Paused"
  | "stopped" -> "Stopped"
  | "crashed" -> "Crashed"
  | "restarting" -> "Restarting"
  | "dead" -> "Dead"
  | other -> other
;;

let emit_record oc json =
  let c = Yojson.Safe.Util.member "conditions_after" json in
  Printf.fprintf
    oc
    "  [launch_pending |-> %s, fiber_alive |-> %s, heartbeat_healthy |-> %s, \
     turn_healthy |-> %s, context_within_budget |-> %s, context_handoff_needed |-> %s, \
     compaction_active |-> %s, handoff_active |-> %s, operator_paused |-> %s, \
     stop_requested |-> %s, restart_budget_remaining |-> %s, backoff_elapsed |-> %s, \
     guardrail_triggered |-> %s, drain_complete |-> %s, context_overflow |-> %s, \
     compact_retry_exhausted |-> %s, restart_count |-> %d, recorded_phase |-> %S]"
    (bool_to_tla (get_bool c "launch_pending"))
    (bool_to_tla (get_bool c "fiber_alive"))
    (bool_to_tla (get_bool c "heartbeat_healthy"))
    (bool_to_tla (get_bool c "turn_healthy"))
    (bool_to_tla (get_bool c "context_within_budget"))
    (bool_to_tla (get_bool c "context_handoff_needed"))
    (bool_to_tla (get_bool c "compaction_active"))
    (bool_to_tla (get_bool c "handoff_active"))
    (bool_to_tla (get_bool c "operator_paused"))
    (bool_to_tla (get_bool c "stop_requested"))
    (bool_to_tla (get_bool c "restart_budget_remaining"))
    (bool_to_tla (get_bool c "backoff_elapsed"))
    (bool_to_tla (get_bool c "guardrail_triggered"))
    (bool_to_tla (get_bool c "drain_complete"))
    (bool_to_tla (get_bool c "context_overflow"))
    (bool_to_tla (get_bool c "compact_retry_exhausted"))
    (get_int json "restart_count")
    (tla_phase (get_string json "new_phase"))
;;

let () =
  let args = Sys.argv in
  if Array.length args < 2
  then (
    Printf.eprintf "Usage: %s <input.jsonl> [output.tla]\n" args.(0);
    exit 1);
  let input_path = args.(1) in
  let output_path =
    if Array.length args >= 3
    then args.(2)
    else "specs/keeper-state-machine/TraceData.tla"
  in
  let ic = open_in input_path in
  let lines = ref [] in
  (try
     while true do
       let line = input_line ic in
       if String.length line > 0 then lines := Yojson.Safe.from_string line :: !lines
     done
   with
   | End_of_file -> ());
  close_in ic;
  let steps = List.rev !lines in
  let n = List.length steps in
  if n = 0
  then (
    Printf.eprintf "Error: empty trace file\n";
    exit 1);
  let oc = open_out output_path in
  Printf.fprintf oc "---- MODULE TraceData ----\n";
  Printf.fprintf oc "\\* Auto-generated from %s\n" (Filename.basename input_path);
  Printf.fprintf oc "\\* %d trace steps\n\n" n;
  Printf.fprintf oc "EXTENDS Naturals\n\n";
  Printf.fprintf oc "TraceLength == %d\n\n" n;
  Printf.fprintf oc "Trace == <<\n";
  List.iteri
    (fun i json ->
       emit_record oc json;
       if i < n - 1 then Printf.fprintf oc ",\n" else Printf.fprintf oc "\n")
    steps;
  Printf.fprintf oc ">>\n\n";
  Printf.fprintf oc "====\n";
  close_out oc;
  Printf.printf "Generated %s (%d steps)\n" output_path n
;;
