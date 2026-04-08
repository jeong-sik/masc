(** Handover tools - Agent handover capsule *)

open Tool_args

(* Context required by handover tools - needs Eio filesystem *)
type context = {
  config: Room.config;
  agent_name: string;
  fs: Eio.Fs.dir_ty Eio.Path.t option;
  proc_mgr: Eio_unix.Process.mgr_ty Eio.Resource.t option;
  sw: Eio.Switch.t option;  (* Only needed when fs and proc_mgr are Some *)
}

type result = bool * string

(* Individual handlers *)
let handle_handover_create ctx args =
  let task_id = get_string args "task_id" "" in
  if task_id = "" then
    (false, "task_id is required")
  else
  let session_id = get_string args "session_id" "" in
  let reason_str = get_string args "reason" "explicit" in
  let reason = match reason_str with
    | "context_limit" -> Handover_eio.ContextLimit (get_int args "context_pct" 80)
    | "timeout" -> Handover_eio.Timeout 300
    | "error" -> Handover_eio.FatalError "Unknown error"
    | "complete" -> Handover_eio.TaskComplete
    | _ -> Handover_eio.Explicit
  in
  let h = {
    (Handover_eio.create_handover ~from_agent:ctx.agent_name ~task_id ~session_id ~reason) with
    current_goal = get_string args "goal" "";
    progress_summary = get_string args "progress" "";
    completed_steps = get_string_list args "completed_steps";
    pending_steps = get_string_list args "pending_steps";
    key_decisions = get_string_list args "decisions";
    assumptions = get_string_list args "assumptions";
    warnings = get_string_list args "warnings";
    unresolved_errors = get_string_list args "errors";
    modified_files = get_string_list args "files";
    context_usage_percent = get_int args "context_pct" 0;
  } in
  match ctx.fs with
  | Some fs ->
      (match Handover_eio.save_handover ~fs ctx.config h with
       | Ok () -> (true, Printf.sprintf "✅ Handover capsule created: %s" h.id)
       | Error e -> (false, Printf.sprintf "❌ Failed to save handover: %s" e))
  | None -> (false, "❌ Filesystem not available")

let handle_handover_list ctx args =
  let pending_only = get_bool args "pending_only" false in
  let limit = get_int args "limit" 20 |> max 1 |> min 50 in
  match ctx.fs with
  | Some fs ->
      let handovers =
        if pending_only then Handover_eio.get_pending_handovers ~fs ctx.config
        else Handover_eio.list_handovers ~fs ctx.config
      in
      let handovers = List.filteri (fun i _ -> i < limit) handovers in
      let json = `List (List.map Handover_eio.handover_to_json handovers) in
      (true, Yojson.Safe.to_string json)
  | None -> (false, "❌ Filesystem not available")

let handle_handover_claim ctx args =
  let handover_id = get_string args "handover_id" "" in
  if handover_id = "" then
    (false, "handover_id is required")
  else
  match ctx.fs with
  | Some fs ->
      (match Handover_eio.claim_handover ~fs ctx.config ~handover_id ~agent_name:ctx.agent_name with
       | Ok h -> (true, Printf.sprintf "✅ Handover %s claimed by %s" h.id ctx.agent_name)
       | Error e -> (false, Printf.sprintf "❌ Failed to claim handover: %s" e))
  | None -> (false, "❌ Filesystem not available")

let handle_handover_get ctx args =
  let handover_id = get_string args "handover_id" "" in
  if handover_id = "" then
    (false, "handover_id is required")
  else
  match ctx.fs with
  | Some fs ->
      (match Handover_eio.load_handover ~fs ctx.config handover_id with
       | Ok h -> (true, Handover_eio.format_as_markdown h)
       | Error e -> (false, Printf.sprintf "❌ Failed to load handover: %s" e))
  | None -> (false, "❌ Filesystem not available")

let schemas : Types.tool_schema list = [
  {
    name = "masc_handover_claim";
    description = "Claim a pending handover to continue the work. You become the successor agent. The handover capsule will be loaded into your context.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name (the successor)");
        ]);
        ("handover_id", `Assoc [
          ("type", `String "string");
          ("description", `String "ID of the handover to claim");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "handover_id"]);
    ];
  };
  (* masc_handover_create *)
  {
    name = "masc_handover_create";
    description = "Write a structured handover record (goal, progress, decisions, warnings) before context limit or session end. \\nCall when approaching context capacity, hitting a timeout, or completing a task phase. \\nSuccessor claims it via masc_handover_claim.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name (the dying agent)");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task being worked on");
        ]);
        ("session_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Current session identifier");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "context_limit"; `String "timeout"; `String "explicit"; `String "error"; `String "complete"]);
          ("description", `String "Why handover is triggered");
        ]);
        ("goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Current goal being pursued");
        ]);
        ("progress", `Assoc [
          ("type", `String "string");
          ("description", `String "Summary of progress made");
        ]);
        ("completed_steps", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Steps already completed");
        ]);
        ("pending_steps", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Steps remaining to do");
        ]);
        ("decisions", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Key decisions made and why (implicit knowledge transfer)");
        ]);
        ("assumptions", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "What we're assuming is true");
        ]);
        ("warnings", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Gotchas and things to watch out for");
        ]);
        ("errors", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Unresolved errors from PDCA loop");
        ]);
        ("files", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Files modified during this session");
        ]);
        ("context_pct", `Assoc [
          ("type", `String "integer");
          ("description", `String "Context usage percentage when handover triggered");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "task_id"; `String "reason"; `String "goal"]);
    ];
  };

  (* masc_handover_list *)
  {
    name = "masc_handover_list";
    description = "List handover records, optionally filtered to pending (unclaimed) only. \
Use when starting a session to find abandoned work waiting to be continued. \
After finding a handover, call masc_handover_get for details, then masc_handover_claim to take it.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("pending_only", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true, only show unclaimed handovers");
          ("default", `Bool false);
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max handovers to return (default: 20)");
          ("minimum", `Int 1);
          ("maximum", `Int 50);
          ("default", `Int 20);
        ]);
      ]);
    ];
  };

  (* masc_handover_get *)
  {
    name = "masc_handover_get";
    description = "Retrieve a handover record as formatted markdown showing goal, progress, decisions, and warnings. \
Use when reviewing a handover before deciding to claim it via masc_handover_claim. \
Pair with masc_handover_list to browse available handovers first.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("handover_id", `Assoc [
          ("type", `String "string");
          ("description", `String "ID of the handover to retrieve");
        ]);
      ]);
      ("required", `List [`String "handover_id"]);
    ];
  };

]

(* Dispatch function - returns None if tool not handled *)
let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_handover_create" -> Some (handle_handover_create ctx args)
  | "masc_handover_list" -> Some (handle_handover_list ctx args)
  | "masc_handover_claim" -> Some (handle_handover_claim ctx args)
  | "masc_handover_get" -> Some (handle_handover_get ctx args)
  | _ -> None

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_handover
           ~input_schema:s.input_schema
           ()))
    schemas
