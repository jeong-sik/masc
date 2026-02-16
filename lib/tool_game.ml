
(** Game Tools - Authoritative MCP interface with improved safety *)

open Masc_mcp_bridge.Event_bus

let is_authorized_gm agent_id =
  agent_id = "SYSTEM_GM" || agent_id = "DM"

let handle_declare_intent ~agent_id ~intent =
  broadcast (IntentDeclared { agent = agent_id; intent });
  Ok "✅ Intent broadcasted to world."

let handle_resolve_judgment ~caller_id ~target_agent_id ~ability ~proposed_narrative ~difficulty_score =
  if not (is_authorized_gm caller_id) then
    Error (Printf.sprintf "Agent [%s] is not authorized as a GM." caller_id)
  else
    (* A. 동적 난이도 반영 및 RNG 판정 *)
    let roll = 1 + Random.int 20 in
    let actual_success = roll >= difficulty_score in
    
    (* B. 결과 브로드캐스트 *)
    broadcast (JudgmentResolved { 
      agent = target_agent_id; 
      ability; 
      success = actual_success; 
      narrative = proposed_narrative; 
      impact = (if actual_success then 80 else 20);
      gm_frustration = 0
    });
    
    Ok (Printf.sprintf "Judgment resolved: %s (Roll: %d vs DC: %d)" 
      (if actual_success then "SUCCESS" else "FAILURE") roll difficulty_score)

let handle_status_update ~agent_id ~frustration ~sanity =
  let timestamp = Unix.gettimeofday () in
  broadcast (HeartbeatTick { 
    agent = agent_id; 
    frustration; 
    sanity; 
    timestamp 
  });
  Ok "✅ Personal state synced."
