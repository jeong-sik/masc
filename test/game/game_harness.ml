(** MASC Reality Anchor Protocol (RAP) - Finalized Test Harness *)

open Masc_mcp_bridge.Event_bus

type world_state = {
  objects: (string * string) list;
}

let current_state = {
  objects = [("jail_door", "broken")];
}

let contains s1 s2 =
  try
    let _ = Str.search_forward (Str.regexp_string s2) s1 0 in true
  with Not_found -> false

let verify_causality agent_id intent =
  if List.exists (fun (id, status) -> contains intent id && status = "broken") current_state.objects then
    Error (Printf.sprintf "❌ Reality Anchor Failure: Agent [%s] attempted to act on a broken object." agent_id)
  else
    Ok ()

let run_final_test () =
  Random.self_init ();
  print_endline "🛡️ Starting MASC Reality Anchor Protocol (Yojson-Verified) v11...";

  (* 1. Intent Check *)
  let agent = "MISO" in
  let intent = "이미 부서진 jail_door를 다시 부수겠다." in
  (match verify_causality agent intent with
  | Error msg -> print_endline msg
  | Ok () -> print_endline "✅ Causality Verified.");

  (* 2. Yojson Broadcast Test *)
  broadcast (TurnStarted "KIM");
  broadcast (HeartbeatTick { agent = "KIM"; frustration = 10; sanity = 90; timestamp = Unix.gettimeofday () });

  print_endline "🏁 Finalized Simulation Finished."

let () = run_final_test ()
