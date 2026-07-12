(** Feature Flag Registry — single source of truth for all MASC boolean feature flags.

    Each flag has a canonical default, description, category, and lifecycle state.
    The registry does NOT replace env_config modules (they still read env vars).
    Instead, it provides:

    1. Runtime enumeration: operators can query all flags and their values
    2. Consistency verification: CI lint compares registry defaults against actual get_bool calls
    3. Lifecycle tracking: Active → Deprecated → Removed state machine
    4. Documentation: machine-readable flag catalog

    @since 2.162.0
    @see <docs/design/inventory-gap-analysis-rfc.md> H5 Feature Flags *)

open Env_config_core

(** Flag lifecycle state machine: Active → Deprecated → (removed from registry) *)
type lifecycle =
  | Active
  | Deprecated of string  (** reason for deprecation *)
  | Experimental          (** not yet stable, may change without notice *)

type flag = {
  env_name : string;         (** Environment variable name (MASC_* prefix) *)
  description : string;      (** What the flag controls *)
  default : bool;            (** Canonical default value *)
  category : string;         (** Grouping: transport, keeper, dashboard, tool, inference, runtime *)
  lifecycle : lifecycle;     (** Current state in the lifecycle *)
  since : string;            (** Version when flag was introduced *)
}

(** The canonical registry. Alphabetically ordered within each category.
    CI script [check-feature-flag-consistency.sh] verifies that every
    [get_bool ... "MASC_*"] call in lib/config/ has a matching entry here
    with the same default value. *)
let all_flags : flag list = [
  (* ── Transport ────────────────────────────────────────────── *)
  { env_name = "MASC_GRPC_ENABLED";
    description = "gRPC transport server";
    default = true; category = "transport";
    lifecycle = Active; since = "2.0.0" };

  { env_name = "MASC_WS_ENABLED";
    description = "WebSocket transport server";
    default = true; category = "transport";
    lifecycle = Active; since = "2.0.0" };

  { env_name = "MASC_WEBRTC_ENABLED";
    description = "WebRTC DataChannel transport (opt-out via =0)";
    default = true; category = "transport";
    lifecycle = Active; since = "2.120.0" };

  { env_name = "MASC_HTTP_AUTH_STRICT";
    description = "Require auth for all HTTP endpoints (not just /mcp)";
    default = false; category = "transport";
    lifecycle = Active; since = "2.140.0" };

  { env_name = Env_config_core.telemetry_enabled_env_key;
    description = "Telemetry/span collection";
    default = true; category = "transport";
    lifecycle = Active; since = "2.50.0" };

  (* ── Tool Surface ─────────────────────────────────────────── *)
  (* RFC-0084 host-config-cleanup-J — MASC_DISPATCH_V2 entry removed.
     The Hashtbl dispatch path is the only path. *)

  { env_name = "MASC_FULL_SURFACE";
    description = "Include hidden/developer tools in tool list";
    default = false; category = "tool";
    lifecycle = Active; since = "2.90.0" };

  { env_name = Env_config_core.parse_warn_env_key;
    description = "Escalate malformed env parses to Config_error";
    default = false; category = "tool";
    lifecycle = Active; since = "2.60.0" };

  (* ── Keeper ───────────────────────────────────────────────── *)
  { env_name = "MASC_KEEPER_DOMAIN_POOL_ENABLED";
    description = "Historical keeper DomainPool pilot flag. Supervisor keepalive fibers now stay on the owning Eio domain because they use switches, clocks, and provider streams.";
    default = false; category = "keeper";
    lifecycle = Experimental; since = "2.170.0" };

  { env_name = "MASC_KEEPER_BOOTSTRAP_ENABLED";
    description = "Startup keeper auto-bootstrap scan";
    default = true; category = "keeper";
    lifecycle = Active; since = "2.130.0" };

  (* RFC-0297 P0-1: global lifecycle kill-switches. Before these existed,
     [reactive]/[proactive]/[autonomous] enabled in runtime.toml were
     silently dropped (no key_to_env mapping). Default true preserves the
     historical always-on behaviour; operators opt into a kill-switch by
     setting the flag false. Consumed via Keeper_lifecycle_gate. *)
  { env_name = "MASC_KEEPER_REACTIVE_ENABLED";
    description = "Global kill-switch for keeper reactive turns (mention/board/scope/event-queue triggers)";
    default = true; category = "keeper";
    lifecycle = Active; since = "2.253.0" };

  { env_name = "MASC_KEEPER_PROACTIVE_ENABLED";
    description = "Global kill-switch for keeper proactive (scheduled) turns";
    default = true; category = "keeper";
    lifecycle = Active; since = "2.253.0" };

  { env_name = "MASC_KEEPER_AUTONOMOUS_ENABLED";
    description = "Global kill-switch for keeper autonomous keepalive/PR fan-out";
    default = true; category = "keeper";
    lifecycle = Active; since = "2.253.0" };

  { env_name = "MASC_KEEPER_WORK_AS_HEARTBEAT";
    description = "Count successful workspace heartbeat after a turn as presence proof";
    default = true; category = "keeper";
    lifecycle = Active; since = "2.162.0" };

  { env_name = "MASC_KEEPER_SMART_HEARTBEAT";
    description = "Skip heartbeat cycles when busy (task proves liveness) or extend interval when idle";
    default = true; category = "keeper";
    lifecycle = Active; since = "2.163.0" };

  { env_name = "MASC_KEEPER_VISIBILITY_GATE";
    description = "Delay proactive idle turns when no SSE consumer is observing and no pending signal exists";
    default = true; category = "keeper";
    lifecycle = Active; since = "2.250.0" };

  { env_name = "MASC_KEEPER_WIRE_CAPTURE";
    description = "Default-off diagnostic MASC-to-OAS request/response wire capture";
    default = false; category = "keeper";
    lifecycle = Experimental; since = "2.254.0" };

  { env_name = "MASC_CONNECTOR_AMBIENT_WAKE_ENABLED";
    description = "Wake an idle keeper on an ambient connector message via an external-attention edge stimulus (RFC-connector-ambient-attention-wake). Off until the spurious-wake throttle (P4) lands; enabling without it would run a turn on every ambient line.";
    default = false; category = "keeper";
    lifecycle = Experimental; since = "2.252.0" };

  { env_name = "MASC_KEEPER_DEBUG";
    description = "Keeper debug logging";
    default = false; category = "keeper";
    lifecycle = Active; since = "2.50.0" };

  { env_name = "MASC_KEEPER_DOCKER_PLAYGROUND";
    description = "Route Execute commands through Docker container";
    default = false; category = "keeper";
    lifecycle = Active; since = "2.233.0" };

  (* ── Dashboard & Governance ───────────────────────────────── *)
  { env_name = "MASC_DISABLE_HITL";
    description = "Disable Human-in-the-loop (HITL) approval gates globally";
    default = false; category = "dashboard";
    lifecycle = Active; since = "2.250.0" };

  { env_name = "MASC_DASHBOARD_FIXTURES_ENABLED";
    description = "Load dashboard fixture data for testing";
    default = false; category = "dashboard";
    lifecycle = Active; since = "2.140.0" };

  { env_name = "MASC_DASHBOARD_GOVERNANCE_JUDGE_ENABLED";
    description = "Governance judgment background loop";
    default = true; category = "dashboard";
    lifecycle = Active; since = "2.140.0" };

  { env_name = "MASC_OPERATOR_JUDGE_ENABLED";
    description = "Operator background judgment loop";
    default = true; category = "dashboard";
    lifecycle = Active; since = "2.140.0" };

  { env_name = "MASC_OPERATOR_CACHE_BACKGROUND_REVALIDATE";
    description = "Serve stale operator snapshots while recomputing in the background";
    default = true; category = "dashboard";
    lifecycle = Active; since = "2.150.0" };

  (* ── Inference & Chain ────────────────────────────────────── *)
  { env_name = "MASC_INFERENCE_CACHE_ENABLED";
    description = "L1+L2 inference response caching";
    default = true; category = "inference";
    lifecycle = Active; since = "2.110.0" };

  (* ── Runtime ──────────────────────────────────────────────── *)
  { env_name = Env_config_core.orchestrator_enabled_env_key;
    description = "Auto-orchestration background loop (superseded by zero-zombie cleanup)";
    default = false; category = "runtime";
    lifecycle = Deprecated "superseded by zero-zombie cleanup since v2.130.0"; since = "2.0.0" };

  { env_name = "MASC_LOCAL_RUNTIME_DEBUG";
    description = "Local LLM runtime debug output";
    default = false; category = "runtime";
    lifecycle = Active; since = "2.200.0" };

  { env_name = "MASC_SHELL_IR_APPROVAL_GATE_ENABLED";
    description = "Route Execute tool calls through the capability-based Shell IR approval policy gate";
    default = true; category = "runtime";
    lifecycle = Active; since = "2.234.0" };
  { env_name = "MASC_SLOT_YIELD_ENABLED";
    description = "Release LLM slot during tool execution so other agents can use it";
    default = true; category = "runtime";
    lifecycle = Active; since = "2.208.0" };

  (* ── Contract verification ───────────────────────────────── *)
  { env_name = "MASC_VERIFICATION_FSM_ENABLED";
    description = "Task verification FSM: AwaitingVerification state and cross-agent approval";
    default = true; category = "runtime";
    lifecycle = Active; since = "0.9.3" };

  (* RFC-0323 G-5 Phase B: route all task completion through submit→approve
     (verification-required) regardless of contract.strict. Default off —
     flip only when the readiness gate §5 holds (≥2 distinct verifier
     identities per submitting room, else solo-room starvation with no timer
     backstop, RFC-0220 §5/§11). Only the done guard flips; the evidence
     gate stays on contract.strict (Phase A scope). *)
  { env_name = "MASC_VERIFICATION_DEFAULT_ON";
    description = "RFC-0323 G-5 Phase B: verification-required by default (submit→approve)";
    default = false; category = "runtime";
    lifecycle = Active; since = "0.20.0" };

]

(** Lookup a flag by env var name. O(n) — acceptable for ~30 flags. *)
let find_opt env_name =
  List.find_opt (fun f -> f.env_name = env_name) all_flags

(** Read runtime value using canonical default. *)
let runtime_value flag =
  get_bool ~default:flag.default flag.env_name

(** Source: "env", "boot_override", or "default". *)
let runtime_source flag =
  Config_boot_overrides.source flag.env_name


(** Lookup the runtime value of a flag using its registry default. *)
let get_bool env_name =
  match find_opt env_name with
  | Some flag -> runtime_value flag
  | None ->
      Log.Misc.warn "feature flag %s not found in registry" env_name;
      Env_config_core.get_bool ~default:false env_name

let lifecycle_to_string = function
  | Active -> "active"
  | Deprecated reason -> "deprecated: " ^ reason
  | Experimental -> "experimental"

(** Serialize a single flag to JSON with its runtime value. *)
let flag_to_json flag =
  `Assoc [
    ("env_name", `String flag.env_name);
    ("description", `String flag.description);
    ("canonical_default", `Bool flag.default);
    ("runtime_value", `Bool (runtime_value flag));
    ("source", `String (runtime_source flag));
    ("category", `String flag.category);
    ("lifecycle", `String (lifecycle_to_string flag.lifecycle));
    ("since", `String flag.since);
  ]

(** Serialize all flags grouped by category. *)
let to_json () =
  let categories = ["transport"; "tool"; "keeper"; "dashboard"; "inference"; "runtime"] in
  let flags_in cat = List.filter (fun f -> f.category = cat) all_flags in
  `Assoc [
    ("total_flags", `Int (List.length all_flags));
    ("categories", `Assoc (List.map (fun cat ->
      (cat, `List (List.map flag_to_json (flags_in cat)))
    ) categories));
  ]

(** Flags where runtime value differs from canonical default. *)
let overridden_flags () =
  List.filter (fun f -> runtime_value f <> f.default) all_flags

(** Flags in deprecated lifecycle state. *)
let deprecated_flags () =
  List.filter (fun f -> match f.lifecycle with Deprecated _ -> true | Active | Experimental -> false) all_flags
