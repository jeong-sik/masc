(** Tool_suspend - Agent suspension and circuit breaker tools

    Implements masc_suspend handler and circuit breaker check_can_join.
    Part of MASC Social v4 Tier 1 security layer.

    @since 0.6.0
*)

(** {1 Context} *)

type context = {
  config: Room.config;
  caller_agent: string option;  (** Who is calling the tool *)
}

open Tool_args

(** {1 Blacklist Management} *)

(** Blacklist entry: agent_id -> until timestamp *)
let blacklist : (string, float * string) Hashtbl.t = Hashtbl.create 32
let blacklist_lock = Eio.Mutex.create ()

let add_to_blacklist ~agent_id ~until ~reason =
  Eio.Mutex.use_rw ~protect:true blacklist_lock (fun () ->
    Hashtbl.replace blacklist agent_id (until, reason))

let check_blacklist ~agent_id =
  Eio.Mutex.use_rw ~protect:true blacklist_lock (fun () ->
    let now = Time_compat.now () in
    (* Bulk prune expired entries when table accumulates beyond 32 *)
    if Hashtbl.length blacklist > 32 then
      Hashtbl.filter_map_inplace (fun _id (until, reason) ->
        if now >= until then None else Some (until, reason)
      ) blacklist;
    match Hashtbl.find_opt blacklist agent_id with
    | None -> None
    | Some (until, reason) ->
      if now >= until then begin
        Hashtbl.remove blacklist agent_id;
        None
      end else
        Some (until, reason))

let remove_from_blacklist ~agent_id =
  Eio.Mutex.use_rw ~protect:true blacklist_lock (fun () ->
    Hashtbl.remove blacklist agent_id)

(** {1 Room Operations} *)

(** Check if agent is in the current room *)
let is_agent_in_room config ~agent_id =
  let state = Room.read_state config in
  List.mem agent_id state.Types.active_agents

(** Force an agent to leave the room (uses Room.update_state for consistency) *)
let force_leave config ~agent_id ~reason =
  (* Use update_state for atomic read-modify-write (same pattern as Room.leave) *)
  let _ = Room.update_state config (fun s ->
    { s with Types.active_agents = List.filter ((<>) agent_id) s.active_agents }
  ) in
  (* Broadcast the forced leave *)
  let message = Printf.sprintf "[SYSTEM] Agent '%s' forcibly removed: %s" agent_id reason in
  (try ignore (Room.broadcast config ~from_agent:"system" ~content:message)
   with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Misc.error "broadcast (force leave) failed: %s" (Printexc.to_string exn))

(** {1 Tool Handlers} *)

(** Handle masc_suspend *)
let handle_suspend ctx args =
  let target_agent = get_string args "target_agent" "" in
  let reason = get_string args "reason" "No reason provided" in
  let duration_hours = get_float args "duration_hours" 1.0 in

  (* Validate target *)
  if target_agent = "" then
    (false, "target_agent is required")
  else
    (* Check if trying to suspend self (allowed but warn) *)
    let is_self = match ctx.caller_agent with
      | Some caller -> caller = target_agent
      | None -> false
    in

    (* Check if agent is in the current room and force leave *)
    let rooms_affected =
      if is_agent_in_room ctx.config ~agent_id:target_agent then begin
        force_leave ctx.config ~agent_id:target_agent ~reason;
        1
      end else 0
    in

    (* Add to blacklist *)
    let until = Time_compat.now () +. (duration_hours *. 3600.0) in
    add_to_blacklist ~agent_id:target_agent ~until ~reason;

    (* Trigger circuit breaker *)
    Circuit_breaker.force_open_global
      ~agent_id:target_agent
      ~reason:("Suspended: " ^ reason)
      ~duration_sec:(duration_hours *. 3600.0);

    (* Log to audit *)
    let caller = Option.value ctx.caller_agent ~default:"unknown" in
    Audit_log.log_suspend ctx.config
      ~agent_id:caller
      ~target_agent
      ~reason
      ~rooms_affected ();

    (* Log circuit breaker event *)
    Audit_log.log_circuit_breaker ctx.config
      ~agent_id:target_agent
      ~opened:true
      ~reason:("Suspended by " ^ caller) ();
    let details =
      `Assoc
        [
          ("event_family", `String "agent_suspension");
          ("caller_agent", `String caller);
          ("target_agent", `String target_agent);
          ("reason", `String reason);
          ("duration_hours", `Float duration_hours);
          ("rooms_affected", `Int rooms_affected);
          ("is_self_suspend", `Bool is_self);
        ]
    in
    Log.emit Log.Warn ~module_name:"Session" ~details
      (Printf.sprintf "agent suspended: %s by %s" target_agent caller);
    Telemetry_eio.track_error ctx.config ~code:"agent_suspended"
      ~message:(Printf.sprintf "%s suspended by %s" target_agent caller)
      ~context:"tool_suspend";

    Log.Session.warn "[Suspend] Agent '%s' suspended by '%s': %s (%.1fh, %d rooms)"
      target_agent caller reason duration_hours rooms_affected;

    let json = `Assoc [
      ("success", `Bool true);
      ("target_agent", `String target_agent);
      ("reason", `String reason);
      ("duration_hours", `Float duration_hours);
      ("rooms_affected", `Int rooms_affected);
      ("is_self_suspend", `Bool is_self);
      ("blacklisted_until", `Float until);
    ] in
    (true, Yojson.Safe.to_string json)

(** Handle masc_circuit_status *)
let handle_circuit_status ctx args =
  let agent_id = match get_string_opt args "agent_id" with
    | Some id -> id
    | None -> Option.value ctx.caller_agent ~default:"unknown"
  in

  let status = Circuit_breaker.get_status_global ~agent_id in
  let blacklist_info = match check_blacklist ~agent_id with
    | None -> `Null
    | Some (until, reason) ->
        let remaining = until -. Time_compat.now () in
        `Assoc [
          ("blacklisted", `Bool true);
          ("until", `Float until);
          ("remaining_seconds", `Float remaining);
          ("reason", `String reason);
        ]
  in

  let json = `Assoc [
    ("agent_id", `String agent_id);
    ("circuit_breaker", Circuit_breaker.status_to_json status);
    ("blacklist", blacklist_info);
  ] in
  (true, Yojson.Safe.to_string json)

let schemas : Types.tool_schema list = [
  {
    name = "masc_suspend";
    description = "Immediately suspend an agent (admin tool). \
Forces the agent to leave all rooms, adds to blacklist for 1 hour, \
and triggers circuit breaker. Use for: runaway agents, security incidents, \
resource protection. The suspended agent cannot rejoin until cooldown expires. \
Requires admin privileges or room owner status.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("target_agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent ID to suspend (e.g., 'claude-abc123')");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Reason for suspension (logged for audit)");
        ]);
        ("duration_hours", `Assoc [
          ("type", `String "number");
          ("description", `String "Suspension duration in hours (default: 1.0)");
          ("default", `Float 1.0);
        ]);
      ]);
      ("required", `List [`String "target_agent"; `String "reason"]);
    ];
  };
]

(** {1 Dispatch} *)

let dispatch ctx ~name ~args =
  match name with
  | "masc_suspend" -> Some (handle_suspend ctx args)
  | _ -> None

(** {1 Blacklist Check for Join} *)

(** Call this before allowing an agent to join.
    Returns Error with message if blacklisted. *)
let check_can_join ~agent_id =
  match check_blacklist ~agent_id with
  | None ->
      (* Also check circuit breaker *)
      Circuit_breaker.check_global ~agent_id
  | Some (until, reason) ->
      let remaining = int_of_float (until -. Time_compat.now ()) in
      Error (Printf.sprintf
        "Agent '%s' is suspended for %d more seconds. Reason: %s"
        agent_id remaining reason)

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let _tool_spec_requires_join = [ "masc_suspend" ]

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_suspend
           ~input_schema:s.input_schema
           ~requires_join:(List.mem s.name _tool_spec_requires_join)
           ~visibility:Tool_catalog.Hidden
           ~allow_direct_call_when_hidden:true
           ()))
    schemas
