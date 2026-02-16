
(** Event Bus - Standardized JSON Broadcasting via Yojson *)

type event_type = 
  | TurnStarted of string
  | IntentDeclared of { agent: string; intent: string }
  | JudgmentProcessing of { agent: string; roll_hint: int }
  | JudgmentResolved of { 
      agent: string; 
      ability: string; 
      success: bool; 
      narrative: string; 
      impact: int;
      gm_frustration: int 
    }
  | HeartbeatTick of { 
      agent: string; 
      frustration: int; 
      sanity: int; 
      timestamp: float 
    }
  | MentalBreakdown of { 
      agent: string; 
      reason: string; 
      severity: int 
    }
  | MetaConflictAlert of { source_gm: string; target_agent: string; reason: string }
  | DialogueSpoken of { agent: string; text: string }

let to_yojson = function
  | TurnStarted agent ->
      `Assoc [("type", `String "TurnStarted"); ("agent", `String agent)]
  | IntentDeclared { agent; intent } ->
      `Assoc [("type", `String "IntentDeclared"); ("agent", `String agent); ("intent", `String intent)]
  | JudgmentProcessing { agent; roll_hint } ->
      `Assoc [("type", `String "JudgmentProcessing"); ("agent", `String agent); ("roll_hint", `Int roll_hint)]
  | JudgmentResolved { agent; ability; success; narrative; impact; gm_frustration } ->
      `Assoc [
        ("type", `String "JudgmentResolved");
        ("agent", `String agent);
        ("ability", `String ability);
        ("success", `Bool success);
        ("narrative", `String narrative);
        ("impact", `Int impact);
        ("gm_frustration", `Int gm_frustration)
      ]
  | HeartbeatTick { agent; frustration; sanity; timestamp } ->
      `Assoc [
        ("type", `String "HeartbeatTick");
        ("agent", `String agent);
        ("frustration", `Int frustration);
        ("sanity", `Int sanity);
        ("timestamp", `Float timestamp)
      ]
  | MentalBreakdown { agent; reason; severity } ->
      `Assoc [
        ("type", `String "MentalBreakdown");
        ("agent", `String agent);
        ("reason", `String reason);
        ("severity", `Int severity)
      ]
  | MetaConflictAlert { source_gm; target_agent; reason } ->
      `Assoc [
        ("type", `String "MetaConflictAlert");
        ("source_gm", `String source_gm);
        ("target_agent", `String target_agent);
        ("reason", `String reason)
      ]
  | DialogueSpoken { agent; text } ->
      `Assoc [("type", `String "DialogueSpoken"); ("agent", `String agent); ("text", `String text)]

let broadcast event =
  let json_string = Yojson.Safe.to_string (to_yojson event) in
  print_endline ("📡 [BRIDGE] " ^ json_string)
