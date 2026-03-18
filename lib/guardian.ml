(** Internal guardian loops (no external watchdog dependency).
    Migrated to Pulse tick engine for unified timer/cancellation.
    OAS-integrated: exports Agent Card, publishes events via Event_bus. *)

open Printf

(* ── OAS Agent Card ──────────────────────────────────────── *)

let agent_card : Agent_card.agent_card = {
  name = "guardian";
  version = "2.95.1";
  description = Some "Internal housekeeping: zombie cleanup, garbage collection, lodge loops";
  provider = Some { organization = "MASC"; url = None };
  protocol_versions = ["0.3"];
  capabilities = { streaming = false; push_notifications = false; extended_agent_card = false };
  skills = [
    { id = "zombie-cleanup"; name = "Zombie Cleanup";
      description = Some "Remove stale room entries";
      tags = ["maintenance"]; tool_count = 1;
      input_modes = []; output_modes = ["application/json"] };
    { id = "garbage-collection"; name = "Garbage Collection";
      description = Some "Purge old records beyond retention window";
      tags = ["maintenance"]; tool_count = 1;
      input_modes = []; output_modes = ["application/json"] };
  ];
  supported_interfaces = [];
  security_schemes = [];
  default_input_modes = ["application/json"];
  default_output_modes = ["application/json"];
  extensions = [];
  signatures = [];
  icon_url = None;
  documentation_url = None;
  created_at = "2026-03-16T00:00:00Z";
  updated_at = "2026-03-16T00:00:00Z";
}

(* ── Event_bus ref (set once at start, shared across consumers) ── *)

let bus_ref : Agent_sdk.Event_bus.t option ref = ref None

let publish_event name payload =
  match !bus_ref with
  | Some bus ->
      Agent_sdk.Event_bus.publish bus
        (Agent_sdk.Event_bus.Custom (name, payload))
  | None -> ()

module Mode = struct
  type t = Masc | Lodge | Both

  let of_string s =
    match String.lowercase_ascii s with
    | "masc" | "mcp" -> Masc
    | "lodge" -> Lodge
    | "both" | "all" -> Both
    | _ -> Masc

  let to_string = function
    | Masc -> "masc"
    | Lodge -> "lodge"
    | Both -> "both"
end

let enabled = Env_config.Guardian.enabled
let mode = Mode.of_string Env_config.Guardian.mode
let masc_enabled =
  enabled && (match mode with Masc | Both -> true | Lodge -> false)

let lodge_enabled =
  enabled
  && Env_config.LodgeV2.enabled
  && (match mode with Lodge | Both -> true | Masc -> false)

let zombie_interval_s = Env_config.Guardian.zombie_interval_seconds
let gc_interval_s = Env_config.Guardian.gc_interval_seconds
let gc_days = Env_config.Guardian.gc_days

let lodge_interval_s = Env_config.Guardian.lodge_interval_seconds
let lodge_iterations = Env_config.Guardian.lodge_iterations
let lodge_delay_ms = Env_config.Guardian.lodge_delay_ms
let lodge_verbose = Env_config.Guardian.lodge_verbose
let lodge_respect_quiet_hours = Env_config.Guardian.lodge_respect_quiet_hours

let last_zombie_cleanup : string option ref = ref None
let last_gc : string option ref = ref None
let last_lodge : string option ref = ref None
let last_zombie_result : string option ref = ref None
let last_gc_result : string option ref = ref None
let last_lodge_result : (bool * string) option ref = ref None
let lodge_running = ref false
let zombie_loop_started = ref false
let gc_loop_started = ref false
let lodge_loop_started = ref false

type masc_runtime_owner =
  | Guardian_runtime
  | Sentinel_runtime

let masc_loops_owner : masc_runtime_owner option ref = ref None

(* Pulse instances — stored for nudge/shutdown/stats access. *)
let zombie_pulse : Pulse.t option ref = ref None
let gc_pulse : Pulse.t option ref = ref None
let lodge_pulse_inst : Pulse.t option ref = ref None

let log_debug msg = Log.Guardian.debug "%s" msg
let log_info msg = Log.Guardian.info "%s" msg
let log_warn msg = Log.Guardian.warn "%s" msg

let set_last r =
  r := Some (Types.now_iso ())

let is_quiet_hours () =
  if not lodge_respect_quiet_hours then false
  else
    let tm = Unix.localtime (Time_compat.now ()) in
    let hour = tm.Unix.tm_hour in
    let quiet_start = Runtime_params.get Governance_registry.lodge_quiet_start in
    let quiet_end = Runtime_params.get Governance_registry.lodge_quiet_end in
    quiet_start < quiet_end && hour >= quiet_start && hour < quiet_end

(* ── Pulse helpers ─────────────────────────────────────────── *)

(** Fixed-interval rhythm with no quiet hours. *)
let fixed_rhythm base_s =
  { Pulse.base_s; min_s = base_s; max_s = base_s; quiet = (0, 0) }

let runtime_owner_to_string = function
  | Guardian_runtime -> "guardian"
  | Sentinel_runtime -> "sentinel"

let masc_runtime_owner_label () =
  match !masc_loops_owner with
  | None -> "none"
  | Some owner -> runtime_owner_to_string owner

let masc_loops_running () =
  !zombie_loop_started || !gc_loop_started

let note_embedded_masc_loops_started_for_tests () =
  zombie_loop_started := true;
  gc_loop_started := true;
  masc_loops_owner := Some Sentinel_runtime

let reset_runtime_state_for_tests () =
  masc_loops_owner := None;
  zombie_pulse := None;
  gc_pulse := None;
  lodge_pulse_inst := None;
  lodge_running := false;
  zombie_loop_started := false;
  gc_loop_started := false;
  lodge_loop_started := false;
  last_zombie_cleanup := None;
  last_gc := None;
  last_lodge := None;
  last_zombie_result := None;
  last_gc_result := None;
  last_lodge_result := None

(* ── Pulse Consumer Factories ──────────────────────────────── *)

let make_zombie_consumer config : (module Pulse.Consumer) =
  (module struct
    let name = "guardian-zombie"
    let should_act _beat = true
    let on_beat _beat =
      try
        let result = Room.cleanup_zombies config in
        last_zombie_result := Some result;
        set_last last_zombie_cleanup;
        log_debug result;
        publish_event "masc:guardian:zombie_cleanup"
          (`Assoc [
            ("agent_name", `String "guardian");
            ("result", `String result);
            ("timestamp", `Float (Time_compat.now ()));
          ]);
        Ok ()
      with exn ->
        let msg = sprintf "zombie cleanup failed: %s" (Printexc.to_string exn) in
        log_warn msg;
        Error msg
  end)

let make_gc_consumer config : (module Pulse.Consumer) =
  (module struct
    let name = "guardian-gc"
    let should_act _beat = true
    let on_beat _beat =
      try
        let result = Room.gc config ~days:gc_days () in
        (* Periodic cache eviction — piggyback on GC cycle *)
        let cache_evicted = Cache_eio.evict_expired config in
        last_gc_result := Some result;
        set_last last_gc;
        log_debug (sprintf "gc: %s (cache evicted: %d)" result cache_evicted);
        publish_event "masc:guardian:gc"
          (`Assoc [
            ("agent_name", `String "guardian");
            ("result", `String result);
            ("gc_days", `Int gc_days);
            ("cache_evicted", `Int cache_evicted);
            ("timestamp", `Float (Time_compat.now ()));
          ]);
        Ok ()
      with exn ->
        let msg = sprintf "gc failed: %s" (Printexc.to_string exn) in
        log_warn msg;
        Error msg
  end)

let make_lodge_consumer ~net : (module Pulse.Consumer) =
  (module struct
    let name = "guardian-lodge"

    let should_act _beat =
      if is_quiet_hours () then begin
        log_debug "quiet hours - skipping lodge loop";
        false
      end else
        true

    let on_beat _beat =
      lodge_running := true;
      let args = `Assoc [
        ("iterations", `Int lodge_iterations);
        ("delay_ms", `Int lodge_delay_ms);
        ("verbose", `Bool lodge_verbose);
      ] in
      let result =
        try Tool_lodge.autonomous_loop ~net args
        with exn ->
          (false, sprintf "exception: %s" (Printexc.to_string exn))
      in
      last_lodge_result := Some result;
      set_last last_lodge;
      lodge_running := false;
      match result with
      | (true, msg) -> log_info (sprintf "lodge loop ok: %s" msg); Ok ()
      | (false, msg) -> log_warn (sprintf "lodge loop failed: %s" msg); Error msg
  end)

(* ── Status ────────────────────────────────────────────────── *)

let status_json () : Yojson.Safe.t =
  let assoc = ref [
    ("enabled", `Bool enabled);
    ("mode", `String (Mode.to_string mode));
    ("masc_enabled", `Bool masc_enabled);
    ("masc_loops_running", `Bool (masc_loops_running ()));
    ("runtime_owner", `String (masc_runtime_owner_label ()));
    ("zombie_loop_running", `Bool !zombie_loop_started);
    ("gc_loop_running", `Bool !gc_loop_started);
    ("lodge_enabled", `Bool lodge_enabled);
    ("lodge_loop_started", `Bool !lodge_loop_started);
    ("zombie_interval_s", `Float zombie_interval_s);
    ("gc_interval_s", `Float gc_interval_s);
    ("gc_days", `Int gc_days);
    ("lodge_interval_s", `Float lodge_interval_s);
    ("lodge_iterations", `Int lodge_iterations);
    ("lodge_delay_ms", `Int lodge_delay_ms);
    ("lodge_verbose", `Bool lodge_verbose);
    ("lodge_respect_quiet_hours", `Bool lodge_respect_quiet_hours);
    ("lodge_running", `Bool !lodge_running);
  ] in
  let add_opt name = function
    | None -> ()
    | Some v -> assoc := (name, `String v) :: !assoc
  in
  add_opt "last_zombie_cleanup" !last_zombie_cleanup;
  add_opt "last_gc" !last_gc;
  add_opt "last_lodge" !last_lodge;
  (match !last_zombie_result with
   | None -> ()
   | Some v -> assoc := ("last_zombie_result", `String v) :: !assoc);
  (match !last_gc_result with
   | None -> ()
   | Some v -> assoc := ("last_gc_result", `String v) :: !assoc);
  (match !last_lodge_result with
   | None -> ()
   | Some (ok, msg) ->
       assoc := ("last_lodge_result", `Assoc [
         ("ok", `Bool ok);
         ("message", `String msg);
       ]) :: !assoc);
  `Assoc (List.rev !assoc)

(* ── Start ─────────────────────────────────────────────────── *)

let start_masc_loops_internal ~owner ~respect_guardian_toggle ?bus ~sw ~clock config =
  bus_ref := bus;
  let can_start = if respect_guardian_toggle then masc_enabled else true in
  if not can_start then begin
    log_debug "masc guardian disabled";
    ()
  end else if masc_loops_running () then begin
    log_debug
      (sprintf "masc guardian loops already running (owner=%s)"
         (masc_runtime_owner_label ()))
  end else begin
    let started_any = ref false in
    if zombie_interval_s > 0.0 then begin
      let p = Pulse.create
        ~clock
        ~rhythm:(fixed_rhythm zombie_interval_s)
        ~lifecycle:Perpetual
        ~consumers:[make_zombie_consumer config]
      in
      zombie_pulse := Some p;
      Pulse.run ~sw p;
      zombie_loop_started := true;
      started_any := true
    end;
    if gc_interval_s > 0.0 then begin
      let p = Pulse.create
        ~clock
        ~rhythm:(fixed_rhythm gc_interval_s)
        ~lifecycle:Perpetual
        ~consumers:[make_gc_consumer config]
      in
      gc_pulse := Some p;
      Pulse.run ~sw p;
      gc_loop_started := true;
      started_any := true
    end;
    if !started_any then
      masc_loops_owner := Some owner
    else
      log_debug "masc guardian loops disabled by interval configuration"
  end

let start_masc_loops ?bus ~sw ~clock config =
  start_masc_loops_internal ~owner:Guardian_runtime ~respect_guardian_toggle:true
    ?bus ~sw ~clock config

let start_embedded_masc_loops ?bus ~sw ~clock config =
  start_masc_loops_internal ~owner:Sentinel_runtime ~respect_guardian_toggle:false
    ?bus ~sw ~clock config

let start_lodge_loop ~sw ~clock ~net =
  if not lodge_enabled then begin
    log_debug "lodge guardian disabled";
    ()
  end else if Option.is_some !lodge_pulse_inst then begin
    log_debug "guardian lodge loop already running";
    ()
  end else if lodge_interval_s <= 0.0 || lodge_iterations <= 0 then begin
    log_debug "lodge guardian disabled by interval/iterations";
    ()
  end else begin
    let p = Pulse.create
      ~clock
      ~rhythm:(fixed_rhythm lodge_interval_s)
      ~lifecycle:Perpetual
      ~consumers:[make_lodge_consumer ~net]
    in
    lodge_pulse_inst := Some p;
    lodge_loop_started := true;
    Pulse.run ~sw p
  end

let start ?bus ~sw ~clock ~net room_config =
  if not enabled then begin
    log_debug "guardian disabled (set MASC_GUARDIAN_ENABLED=true)";
  end else begin
    start_masc_loops ?bus ~sw ~clock room_config;
    start_lodge_loop ~sw ~clock ~net;
    log_info (sprintf "guardian started (mode=%s)" (Mode.to_string mode))
  end
