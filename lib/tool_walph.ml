(** Tool_walph - Walph transition handlers *)

open Tool_args

type 'a context = {
  config: Room.config;
  agent_name: string;
  clock: 'a Eio.Time.clock;
}

(* Handle masc_walph_control *)
let handle_walph_control ctx args =
  let command = get_string args "command" "STATUS" in
  let target_agent = get_string_opt args "target_agent" in
  (true, Room_walph_eio.walph_control ctx.config ~from_agent:ctx.agent_name ~command ~args:"" ~target_agent ())

(* Handle masc_walph_natural *)
let handle_walph_natural ctx args =
  let message = get_string args "message" "" in
  if message = "" then
    (false, "❌ message is required for natural language control")
  else begin
    (* Phase 1: Heuristic-based intent classification (fast, no network) *)
    let msg_lower = String.lowercase_ascii message in
    let contains s = try let _ = Str.search_forward (Str.regexp_string s) msg_lower 0 in true with Not_found -> false in

    let intent =
      if contains "stop" || contains "정지" || contains "그만" || contains "멈춰" then
        `Stop
      else if contains "pause" || contains "일시" || contains "잠깐" then
        `Pause
      else if contains "resume" || contains "재개" || contains "계속" || contains "다시" then
        `Resume
      else if contains "status" || contains "상태" || contains "뭐해" || contains "진행" then
        `Status
      else if contains "start" || contains "시작" || contains "커버리지" || contains "coverage" then
        `Start_removed
      else if contains "refactor" || contains "리팩" || contains "lint" then
        `Start_removed
      else if contains "docs" || contains "문서" || contains "doc" then
        `Start_removed
      else if contains "drain" || contains "태스크" || contains "task" then
        `Start_removed
      else
        `Ignore
    in

    match intent with
    | `Ignore ->
        (true, "ℹ️ Message not recognized as Walph command. Try: start, stop, pause, resume, status")
    | `Stop ->
        (true, Room_walph_eio.walph_control ctx.config ~from_agent:ctx.agent_name ~command:"STOP" ~args:"" ())
    | `Pause ->
        (true, Room_walph_eio.walph_control ctx.config ~from_agent:ctx.agent_name ~command:"PAUSE" ~args:"" ())
    | `Resume ->
        (true, Room_walph_eio.walph_control ctx.config ~from_agent:ctx.agent_name ~command:"RESUME" ~args:"" ())
    | `Status ->
        (true, Room_walph_eio.walph_control ctx.config ~from_agent:ctx.agent_name ~command:"STATUS" ~args:"" ())
    | `Start_removed ->
        (true, "🚫 Walph loop has been removed. Use Team Session + Supervisor for supervised swarm execution.")
  end

(* Handle masc_walph_status *)
let handle_walph_status ctx _args =
  let json = Room_walph_eio.walph_status_json ctx.config ~agent_name:ctx.agent_name in
  (true, Yojson.Safe.to_string json)

let schemas : Types.tool_schema list = [
  {
    name = "masc_walph_status";
    description = "Get transition-only status for the current agent's Walph state. Use when checking for leftover Walph state after the loop removal.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent requesting the status");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };

  (* masc_walph_control *)
  {
    name = "masc_walph_control";
    description = "Send a control command (STOP, PAUSE, RESUME, STATUS) to leftover Walph state during the transition away from Walph loop execution.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("command", `Assoc [
          ("type", `String "string");
          ("description", `String "Control command");
          ("enum", `List [`String "STOP"; `String "PAUSE"; `String "RESUME"; `String "STATUS"]);
        ]);
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent sending the command (for audit trail)");
        ]);
      ]);
      ("required", `List [`String "command"; `String "agent_name"]);
    ];
  };

  (* masc_walph_natural *)
  {
    name = "masc_walph_natural";
    description = "Inspect or stop leftover Walph state using natural language in Korean or English. Start intents are rejected because Walph loop execution has been removed.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "Natural language message to interpret (e.g., '커버리지 좀 올려줘', 'stop the loop', '지금 진행상황 알려줘')");
        ]);
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent sending the command (for audit trail)");
        ]);
      ]);
      ("required", `List [`String "message"; `String "agent_name"]);
    ];
  };

]

(* Dispatch handler *)
let dispatch ctx ~name ~args =
  match name with
  | "masc_walph_control" -> Some (handle_walph_control ctx args)
  | "masc_walph_natural" -> Some (handle_walph_natural ctx args)
  | "masc_walph_status" -> Some (handle_walph_status ctx args)
  | _ -> None
