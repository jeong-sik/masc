(** Tool_walph - Walph loop control handlers *)

open Tool_args

type 'a context = {
  config: Room.config;
  agent_name: string;
  clock: 'a Eio.Time.clock;
}

(** Walph response validator — moved from room_walph_eio.ml to remove
    Oas_response dependency from Room sub-modules. *)
let walph_response_is_valid (resp : Oas_response.api_response) =
  let content = String.trim (Oas_response.text_of_response resp) in
  let lower = String.lowercase_ascii content in
  let len = String.length content in
  len > 0
  && not (len >= 5 && String.sub lower 0 5 = "error")
  && not (len >= 14 && String.sub content 0 14 = "Empty response")
  && not (len >= 9 && String.sub content 0 9 = "{\"error\":")

(** Default model dispatch — moved from room_walph_eio.ml to remove
    Oas_worker dependency from Room sub-modules. *)
let default_model_dispatch ~tool_name:_ ~model:_ ~prompt ~timeout_sec:_ ~max_chars () =
  match
    Oas_worker.run_named ~cascade_name:"walph"
      ~goal:prompt ~max_turns:1
      ~max_tokens:max_chars ~accept:walph_response_is_valid ()
  with
  | Ok result -> Oas_response.text_of_response result.Oas_worker.response
  | Error err -> failwith err

(* Handle masc_walph_loop *)
let handle_walph_loop ctx args =
  let preset = get_string args "preset" "drain" in
  let max_iterations = get_int args "max_iterations" 10 in
  let max_consecutive_errors = get_int args "max_consecutive_errors" 5 in
  let error_backoff_sec = get_int args "error_backoff_sec" 2 in
  let target = get_string_opt args "target" in
  (true, Room_walph_eio.walph_loop ctx.config ~clock:ctx.clock ~agent_name:ctx.agent_name
    ~preset ~max_iterations ~max_consecutive_errors ~error_backoff_sec ?target
    ~model_dispatch:default_model_dispatch ())

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
        `Start_coverage
      else if contains "refactor" || contains "리팩" || contains "lint" then
        `Start_refactor
      else if contains "docs" || contains "문서" || contains "doc" then
        `Start_docs
      else if contains "drain" || contains "태스크" || contains "task" then
        `Start_drain
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
    | `Start_coverage ->
        (true, Room_walph_eio.walph_loop ctx.config ~clock:ctx.clock ~agent_name:ctx.agent_name ~preset:"coverage" ~max_iterations:10 ~model_dispatch:default_model_dispatch ())
    | `Start_refactor ->
        (true, Room_walph_eio.walph_loop ctx.config ~clock:ctx.clock ~agent_name:ctx.agent_name ~preset:"refactor" ~max_iterations:10 ~model_dispatch:default_model_dispatch ())
    | `Start_docs ->
        (true, Room_walph_eio.walph_loop ctx.config ~clock:ctx.clock ~agent_name:ctx.agent_name ~preset:"docs" ~max_iterations:10 ~model_dispatch:default_model_dispatch ())
    | `Start_drain ->
        (true, Room_walph_eio.walph_loop ctx.config ~clock:ctx.clock ~agent_name:ctx.agent_name ~preset:"drain" ~max_iterations:10 ~model_dispatch:default_model_dispatch ())
  end

(* Handle masc_walph_status *)
let handle_walph_status ctx _args =
  let json = Room_walph_eio.walph_status_json ctx.config ~agent_name:ctx.agent_name in
  (true, Yojson.Safe.to_string json)

let schemas : Types.tool_schema list = [
  {
    name = "masc_walph_status";
    description = "Get detailed status for the current agent's Walph loop, including iterations, claimed/done counts, error counters, backoff settings, and last stop reason.";
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

  (* masc_walph_loop *)
  {
    name = "masc_walph_loop";
    description = "Start an automated claim-work-done loop that keeps claiming and completing tasks until a stop condition is met. \
Use when you want to drain a task backlog or run a preset feedback loop (coverage, refactor, docs, figma, drain). \
Control with masc_walph_control (STOP/PAUSE/RESUME/STATUS) or via broadcast '@walph STOP'.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name for claiming tasks");
        ]);
        ("preset", `Assoc [
          ("type", `String "string");
          ("enum", `List [
            `String "coverage";
            `String "refactor";
            `String "docs";
            `String "review";
            `String "figma";
            `String "drain"
          ]);
          ("description", `String "Loop preset: coverage (80%+ test coverage), refactor (0 lint errors), docs (90%+ doc coverage), review (PR self-review), figma (SSIM visual fidelity loop), drain (empty backlog)");
          ("default", `String "drain");
        ]);
        ("max_iterations", `Assoc [
          ("type", `String "integer");
          ("description", `String "Maximum iterations before forced stop (default: 10)");
          ("default", `Int 10);
          ("minimum", `Int 1);
          ("maximum", `Int 100);
        ]);
        ("max_consecutive_errors", `Assoc [
          ("type", `String "integer");
          ("description", `String "Stop loop after this many consecutive errors (default: 5)");
          ("default", `Int 5);
          ("minimum", `Int 1);
          ("maximum", `Int 100);
        ]);
        ("error_backoff_sec", `Assoc [
          ("type", `String "integer");
          ("description", `String "Sleep seconds after an error before retrying (default: 2)");
          ("default", `Int 2);
          ("minimum", `Int 0);
          ("maximum", `Int 300);
        ]);
        ("target", `Assoc [
          ("type", `String "string");
          ("description", `String "Target file or directory for preset (e.g., src/utils.ts)");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };

  (* masc_walph_control *)
  {
    name = "masc_walph_control";
    description = "Send a control command (STOP, PAUSE, RESUME, STATUS) to a running walph loop. \
Use when you need to halt, pause, or inspect a walph loop mid-execution. \
After masc_walph_loop starts a loop; also triggerable via broadcast '@walph STOP'.";
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
    description = "Control a walph loop using natural language in Korean or English (e.g., 'stop the loop', 'coverage up'). \
Use when sending free-form instructions instead of explicit STOP/PAUSE/RESUME commands. \
Translates intent into masc_walph_control commands; falls back to the MODEL for ambiguous messages.";
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
  | "masc_walph_loop" -> Some (handle_walph_loop ctx args)
  | "masc_walph_control" -> Some (handle_walph_control ctx args)
  | "masc_walph_natural" -> Some (handle_walph_natural ctx args)
  | "masc_walph_status" -> Some (handle_walph_status ctx args)
  | _ -> None
