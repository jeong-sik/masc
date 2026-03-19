(** Internal guardian loops (no external watchdog dependency).
    Migrated to Pulse tick engine for unified timer/cancellation.
    OAS-integrated: exports Agent Card, publishes events via Event_bus. *)

open Printf

(* -- OAS Agent Card -- *)

let agent_card : Agent_card.agent_card = {
  name = "guardian";
  version = "2.114.0";
  description = Some "Internal housekeeping: zombie cleanup, garbage collection";
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
  updated_at = "2026-03-18T00:00:00Z";
}

(* -- Event_bus ref (set once at start, shared across consumers) -- *)

let bus_ref : Agent_sdk.Event_bus.t option ref = ref None

let publish_event name payload =
  match !bus_ref with
  | Some bus ->
      Agent_sdk.Event_bus.publish bus
        (Agent_sdk.Event_bus.Custom (name, payload))
  | None -> ()

let enabled = Env_config.Guardian.enabled
let masc_enabled = enabled

(* Warn if legacy Lodge mode is configured *)
let () =
  match String.lowercase_ascii Env_config.Guardian.mode with
  | "lodge" | "both" | "all" ->
      Log.Guardian.warn
        "MASC_GUARDIAN_MODE=%s is deprecated; Lodge heartbeat removed (#1596). Running MASC loops only."
        Env_config.Guardian.mode
  | _ -> ()

let zombie_interval_s = Env_config.Guardian.zombie_interval_seconds
let gc_interval_s = Env_config.Guardian.gc_interval_seconds
let gc_days = Env_config.Guardian.gc_days

let last_zombie_cleanup : string option ref = ref None
let last_gc : string option ref = ref None
let last_zombie_result : string option ref = ref None
let last_gc_result : string option ref = ref None
let zombie_loop_started = ref false
let gc_loop_started = ref false

type masc_runtime_owner =
  | Guardian_runtime
  | Sentinel_runtime

let masc_loops_owner : masc_runtime_owner option ref = ref None

(* Pulse instances -- stored for nudge/shutdown/stats access. *)
let zombie_pulse : Pulse.t option ref = ref None
let gc_pulse : Pulse.t option ref = ref None

let log_debug msg = Log.Guardian.debug "%s" msg
let log_info msg = Log.Guardian.info "%s" msg
let log_warn msg = Log.Guardian.warn "%s" msg

let set_last r =
  r := Some (Types.now_iso ())

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
  zombie_loop_started := false;
  gc_loop_started := false;
  last_zombie_cleanup := None;
  last_gc := None;
  last_zombie_result := None;
  last_gc_result := None

(* -- Pulse Consumer Factories -- *)

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

let make_gc_consumer ~sw ~clock config : (module Pulse.Consumer) =
  (module struct
    let name = "guardian-gc"
    let should_act _beat = true
    let on_beat _beat =
      try
        let result = Room.gc config ~days:gc_days () in
        let keeper_ctx : _ Tool_keeper.context =
          { config; agent_name = "guardian"; sw; clock; proc_mgr = None }
        in
        let keeper_bootstrap = Keeper_runtime.bootstrap_existing_keepers keeper_ctx in
        (* Periodic cache eviction — piggyback on GC cycle *)
        let cache_evicted = Cache_eio.evict_expired config in
        last_gc_result :=
          Some
            (Printf.sprintf
               "%s\n✅ Keeper reconcile scanned=%d started=%d stale=%d recovering=%d"
               result keeper_bootstrap.scanned keeper_bootstrap.started
               keeper_bootstrap.stale keeper_bootstrap.recovering);
        set_last last_gc;
        log_debug
          (sprintf
             "gc: %s (cache evicted: %d, keeper started=%d recovering=%d)"
             result cache_evicted keeper_bootstrap.started
             keeper_bootstrap.recovering);
        publish_event "masc:guardian:gc"
          (`Assoc [
            ("agent_name", `String "guardian");
            ("result", `String result);
            ("gc_days", `Int gc_days);
            ("cache_evicted", `Int cache_evicted);
            ("keeper_bootstrap_started", `Int keeper_bootstrap.started);
            ("keeper_bootstrap_recovering", `Int keeper_bootstrap.recovering);
            ("timestamp", `Float (Time_compat.now ()));
          ]);
        Ok ()
      with exn ->
        let msg = sprintf "gc failed: %s" (Printexc.to_string exn) in
        log_warn msg;
        Error msg
  end)

(* -- Status -- *)

let status_json () : Yojson.Safe.t =
  let assoc = ref [
    ("enabled", `Bool enabled);
    ("masc_enabled", `Bool masc_enabled);
    ("masc_loops_running", `Bool (masc_loops_running ()));
    ("runtime_owner", `String (masc_runtime_owner_label ()));
    ("zombie_loop_running", `Bool !zombie_loop_started);
    ("gc_loop_running", `Bool !gc_loop_started);
    ("zombie_interval_s", `Float zombie_interval_s);
    ("gc_interval_s", `Float gc_interval_s);
    ("gc_days", `Int gc_days);
  ] in
  let add_opt name = function
    | None -> ()
    | Some v -> assoc := (name, `String v) :: !assoc
  in
  add_opt "last_zombie_cleanup" !last_zombie_cleanup;
  add_opt "last_gc" !last_gc;
  (match !last_zombie_result with
   | None -> ()
   | Some v -> assoc := ("last_zombie_result", `String v) :: !assoc);
  (match !last_gc_result with
   | None -> ()
   | Some v -> assoc := ("last_gc_result", `String v) :: !assoc);
  `Assoc (List.rev !assoc)

(* -- Start -- *)

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
        ~consumers:[make_gc_consumer ~sw ~clock config]
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

let start ?bus ~sw ~clock room_config =
  if not enabled then begin
    log_debug "guardian disabled (set MASC_GUARDIAN_ENABLED=true)";
  end else begin
    start_masc_loops ?bus ~sw ~clock room_config;
    log_info "guardian started"
  end
