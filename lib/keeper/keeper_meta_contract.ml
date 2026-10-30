(** Keeper meta policy/runtime contract and pure helpers.

    Included by [Keeper_types] so existing [Keeper_types.*] callers keep
    their public API while the type-heavy contract is separated from JSON
    parsing and store I/O. *)

open Keeper_types_profile

let now_iso () = Masc_domain.now_iso ()

(* -- Policy types (remain in keeper_meta top-level) -- *)

type proactive_cycle_outcome =
  | Proactive_never_started
  | Proactive_unknown
  | Proactive_silent
  | Proactive_text_response
  | Proactive_tool_use
  | Proactive_mixed_response
  | Proactive_error
[@@deriving enumerate]

(* -- Runtime types (moved into agent_runtime_state) -- *)

type proactive_runtime =
  { count_total : int
  ; last_ts : float
  ; visible_count_total : int
  ; last_visible_ts : float
  ; last_outcome : proactive_cycle_outcome
  ; last_reason : string
  ; last_preview : string
  }

(* ── Structured blocker classification ──────────────────────── *)

type runtime_exhaustion_reason = Keeper_internal_error.runtime_exhaustion_reason =
  | Connection_refused
  | Dns_failure
  | No_providers_available
  | All_providers_failed
  | Candidates_filtered_after_cycles
  | Session_conflict
  | Other_detail of string

(** Total typed retryability for a runtime-exhaustion reason.

    Replaces a former string-prefix reparse in
    [keeper_supervisor_pause_policy] that matched on the wire form of
    [runtime_exhaustion_reason_code] and biased every unlisted reason to
    non-retryable via a [_ -> false] catch-all.  That polarity was wrong
    for transient/connectivity faults (Connection_refused, Dns_failure,
    No_providers_available, All_providers_failed), which the supervisor should retry.

    Exhaustive match: adding a new [runtime_exhaustion_reason] variant
    fails compilation here, forcing an explicit retryability decision
    rather than silently defaulting. *)
let runtime_exhaustion_reason_retryable (reason : runtime_exhaustion_reason) : bool =
  Keeper_internal_error.runtime_exhaustion_reason_retryable reason
;;

type runtime_attempt_record =
  { provider_id : string
  ; http_status : int option
  ; outcome : [ `Success | `Failure of string ]
  ; timestamp : float
  }

let runtime_attempt_outcome_to_json = function
  | `Success -> `Assoc [ "kind", `String "success" ]
  | `Failure message ->
    `Assoc [ "kind", `String "failure"; "message", `String message ]
;;

let runtime_attempt_record_to_json (record : runtime_attempt_record) : Yojson.Safe.t =
  `Assoc
    [ "provider_id", `String record.provider_id
    ; ( "http_status"
      , match record.http_status with
        | Some status -> `Int status
        | None -> `Null )
    ; "outcome", runtime_attempt_outcome_to_json record.outcome
    ; "timestamp", `Float record.timestamp
    ]
;;

type usage_metrics =
  { total_turns : int
  ; total_input_tokens : int
  ; total_output_tokens : int
  ; total_tokens : int
  ; total_cost_usd : Keeper_cost_coverage.t
  ; last_turn_ts : float
  ; last_input_tokens : int
  ; last_output_tokens : int
  ; last_total_tokens : int
  ; last_usage_reported_at : float option
  ; last_latency_ms : int
  }

let with_last_reported_usage
      (metrics : usage_metrics)
      ~(usage_reported : bool)
      ~(input_tokens : int)
      ~(output_tokens : int)
      ~(total_tokens : int)
      ~(observed_at : float)
  =
  if usage_reported then
    {
      metrics with
      last_input_tokens = input_tokens;
      last_output_tokens = output_tokens;
      last_total_tokens = total_tokens;
      last_usage_reported_at = Some observed_at;
    }
  else metrics
;;

type agent_runtime_state =
  { usage : usage_metrics
  ; usage_cursor : Keeper_usage_resolution.cursor option
  ; last_usage_resolution : Keeper_usage_resolution.t option
  ; proactive_rt : proactive_runtime
  ; trace_id : Keeper_id.Trace_id.t
  ; last_runtime_attempt : runtime_attempt_record option
  ; message_scope_ack_id : string option
    (** Stable chat-row id of the newest message-scope row actually injected
        into a completed Keeper turn. Rows after this id remain pending. *)
  }

type keeper_meta =
  { (* -- Identity & profile -- *)
    id : Ids.Keeper_id.t option [@default None]
  ; name : string
  ; instructions : string
  ; (* -- Policy -- *)
    sandbox_profile : Keeper_types_profile.sandbox_profile
  ; sandbox_image : string option
  ; network_mode : Keeper_types_profile.network_mode
  ; microvm_backend : Keeper_microvm_backend.t option
  ; microvm_memory : Keeper_microvm_guest_size.memory option
  ; microvm_cpus : Keeper_microvm_guest_size.cpus option
  ; mention_targets : string list
  ; board_interests : string list
  ; (* -- Lifecycle -- *)
    created_at : string
  ; updated_at : string
  ; (* -- Performance & Limits -- *)
    max_context_override : int option
  ; (* -- Operational control (top-level, not runtime) -- *)
    paused : bool
  ; latched_reason : Keeper_latched_reason.t option
    (** Typed companion to [paused]: the operator pause that set it
        ([Keeper_latched_reason.Operator_paused]). [None] while paused is a
        fail-closed unclassified state that requires operator action. *)
  ; input_policy : Keeper_input_policy.t
  ; activation_mode : Keeper_activation_mode.t
  ; current_task_id : Keeper_id.Task_id.t option
    (** Currently claimed task ID for cost attribution.
      Set when keeper claims a task; cleared on masc_transition action=done.
      Propagated to trajectory accumulator for per-task cost tracking. *)
  ; telemetry_feedback_enabled : bool option
  ; telemetry_feedback_window_hours : int option
  ; always_allow : bool option
  ; voice_always_allow : bool option
  ; (* -- Agent runtime state (usage, tracing, autonomy metrics) -- *)
    runtime : agent_runtime_state
  ; (* -- Identity & concurrency -- *)
    keeper_id : Keeper_id.Uid.t option
  ; agent_core_env : (string * string) list
  }

(* Sanctioned generic unpause transform. Every latch this type can carry is an
   explicit operator pause, so resume clears it. *)
let mark_resumed (m : keeper_meta) : keeper_meta =
  { m with
    paused = false
  ; latched_reason = None
  }
;;

let apply_profile_default opt current =
  match opt with
  | Some value -> value
  | None -> current
;;

let apply_profile_default_opt opt current =
  match opt with
  | Some _ -> opt
  | None -> current
;;

let missing_required_sandbox_profile_error ~keeper_name
    (defaults : Keeper_types_profile.keeper_profile_defaults) =
  let manifest_hint =
    match defaults.manifest_path with
    | Some path -> Printf.sprintf " (loaded from %s)" path
    | None -> ""
  in
  Printf.sprintf
    "keeper %s rejected: sandbox_profile is required (allowed: %s)%s. \
     Add e.g. `sandbox_profile = \"docker\"` to the keeper TOML."
    keeper_name
    (String.concat ", " Keeper_types_profile.valid_sandbox_profile_strings)
    manifest_hint
;;

(* #37523. A profile that runs a container has to name the image it runs in,
   the same way it has to name the profile. Filling the gap with the general
   image looked like the safe answer, but that image carries no language
   toolchain, and in 2026-09 five Keepers whose instructions ran pnpm or dune
   came up on it and met `command not found` in their first turn. Nothing
   upstream of the turn said the image had been chosen for them. A Keeper
   that wants the general image names it by its catalog name; that is a
   choice on record rather than a default nobody made. This asks only that a
   name is there. Whether the name resolves to a build on this host is asked
   where the Keeper boots and at keeper up
   ([Keeper_sandbox_image_admission]). Remote_ssh runs on a host, not from an
   image, so it is not asked. *)
let missing_required_sandbox_image_error ~keeper_name
    (sandbox_profile : Keeper_types_profile.sandbox_profile)
    (defaults : Keeper_types_profile.keeper_profile_defaults) =
  match sandbox_profile with
  | Remote_ssh -> None
  | Docker | Micro_vm ->
    (match Option.map String.trim defaults.sandbox_image with
     | Some tag when not (String.equal tag "") -> None
     | Some _ | None ->
       let manifest_hint =
         match defaults.manifest_path with
         | Some path -> Printf.sprintf " (loaded from %s)" path
         | None -> ""
       in
       Some
         (Printf.sprintf
            "keeper %s rejected: sandbox_image is required for sandbox_profile \
             %S%s. Add e.g. `sandbox_image = \"%s\"` to the keeper TOML, a \
             name from the host's image catalog (sandbox-images.toml); that \
             image has no language toolchain, so a Keeper that builds code \
             names an image that carries one."
            keeper_name
            (Keeper_types_profile.sandbox_profile_to_string sandbox_profile)
            manifest_hint
            Keeper_sandbox_image_version.(base_embedded.name)))
;;

(* RFC-0405. The keeper TOML names the runtime; a keeper that names none takes
   the host's. Keeper-up reads this to find the image store a new guest would
   start from, so it cannot drift from what the overlay below resolves. *)
let microvm_backend_of_profile_defaults
    (defaults : Keeper_types_profile.keeper_profile_defaults) =
  match defaults.microvm_backend with
  | Some _ as declared -> declared
  | None -> Keeper_microvm_backend.default_for_host ()

;;

let effective_meta_of_profile_defaults
    (defaults : Keeper_types_profile.keeper_profile_defaults)
    (meta : keeper_meta) : (keeper_meta, string) result =
  let open Keeper_types_profile in
  let has_profile_source = Option.is_some defaults.manifest_path in
  let target_sandbox_profile =
    match defaults.sandbox_profile, defaults.manifest_path with
    | Some profile, _ -> Ok profile
    (* [meta.sandbox_profile] is the JSON decoder's placeholder, not a
       declaration, so a keeper with no declared profile has no profile. *)
    | None, None | None, Some _ ->
      Error
        (missing_required_sandbox_profile_error
           ~keeper_name:meta.name
           defaults)
  in
  match target_sandbox_profile with
  | Error _ as err -> err
  (* Phase 1 SSH lane: [Remote_ssh] is the intended new lane, so the local
     gate must NOT reject it — but it is undispatchable without the
     [remote_endpoint] naming its [exec.ssh.endpoints.<name>] registry
     entry, so config-load validation fails closed here instead of
     letting the keeper boot into a dispatch that can only error. A blank
     or whitespace-only value counts as missing (same trim idiom as
     [runtime_id] below). The masc_keeper_up tool-arg side of this check
     is Phase 1 task 9. *)
  | Ok Remote_ssh
    when (match defaults.remote_endpoint with
          | None -> true
          | Some endpoint -> String.trim endpoint = "") ->
      Error
        (Printf.sprintf
           "keeper %s rejected: remote_ssh_endpoint_missing: sandbox_profile \
            \"remote_ssh\" requires remote_endpoint = \"<name>\" in the keeper \
            TOML (registry: [exec.ssh.endpoints.<name>] in runtime config)"
           meta.name)
  (* RFC-0405. Micro_vm says the tree sits on a guest behind a hypervisor; a
     runtime has to supply one. macOS has an assumed answer, other hosts do
     not, and a keeper whose TOML names none there would otherwise boot into
     a dispatch that can only error. Refusing names both ways out — declare a
     backend, or use a profile this host can serve — rather than handing the
     keeper an isolation weaker than the one it asked for. *)
  | Ok Micro_vm
    when Option.is_none (microvm_backend_of_profile_defaults defaults) ->
      Error
        (Printf.sprintf
           "keeper %s rejected: microvm_backend_unresolved: sandbox_profile \
            \"microvm\" has no runtime on this host. Set microvm_backend to \
            one of: %s, or declare a sandbox_profile this host can serve"
           meta.name
           (String.concat ", " Keeper_microvm_backend.valid_strings))
  | Ok ((Docker | Micro_vm | Remote_ssh) as sandbox_profile) ->
    match
      missing_required_sandbox_image_error ~keeper_name:meta.name
        sandbox_profile defaults
    with
    | Some reason -> Error reason
    | None ->
      let default_network_mode =
        if has_profile_source then default_network_mode_for_profile sandbox_profile
        else meta.network_mode
      in
      let network_mode =
        apply_profile_default defaults.network_mode default_network_mode
      in
      Ok
        { meta with
          instructions =
            apply_profile_default defaults.instructions meta.instructions;
          input_policy = apply_profile_default defaults.input_policy Keeper_input_policy.default;
          activation_mode =
            apply_profile_default defaults.activation_mode meta.activation_mode;
          mention_targets =
            (match defaults.mention_targets with
             | [] -> meta.mention_targets
             | targets -> targets);
          board_interests =
            (match defaults.board_interests with
             | [] -> meta.board_interests
             | interests -> interests);
          max_context_override =
            apply_profile_default_opt defaults.max_context_override
              meta.max_context_override;
          sandbox_profile;
          sandbox_image =
            apply_profile_default_opt defaults.sandbox_image meta.sandbox_image;
          network_mode;
          (* RFC-0405. Which runtime serves a Micro_vm guest is TOML-owned, so
             it is resolved here rather than read off durable meta, where the
             decoder leaves [None]. A keeper that declared no backend takes
             the host's, and where the host has none the boot below refuses
             rather than choosing one for it. Off the Micro_vm profile the
             field stays [None]: the TOML load already refuses the key there,
             and carrying a value no dispatch reads would be a second place
             for the answer to live. *)
          microvm_backend =
            (match sandbox_profile with
             | Micro_vm -> microvm_backend_of_profile_defaults defaults
             | Docker | Remote_ssh -> None);
          (* The guest's size is TOML-owned for the same reason, and only a
             Micro_vm keeper has a guest to size. [None] is the workspace
             default, resolved where the guest boots. *)
          microvm_memory =
            (match sandbox_profile with
             | Micro_vm -> defaults.microvm_memory
             | Docker | Remote_ssh -> None);
          microvm_cpus =
            (match sandbox_profile with
             | Micro_vm -> defaults.microvm_cpus
             | Docker | Remote_ssh -> None);
          (* RFC vision-delegation §2.4: TOML profile overrides the carried
             value; absent -> keep [meta]'s (defaults to Inherit). *)
          telemetry_feedback_enabled =
            apply_profile_default_opt defaults.telemetry_feedback_enabled
              meta.telemetry_feedback_enabled;
          telemetry_feedback_window_hours =
            apply_profile_default_opt defaults.telemetry_feedback_window_hours
              meta.telemetry_feedback_window_hours;
          always_allow =
            apply_profile_default_opt defaults.always_allow
              meta.always_allow;
          voice_always_allow =
            apply_profile_default_opt defaults.voice_always_allow
              meta.voice_always_allow;
          agent_core_env =
            (match defaults.agent_core_env with
             | [] -> meta.agent_core_env
             | env -> env);
        }
;;

let effective_meta_result ~base_path (meta : keeper_meta) : (keeper_meta, string) result =
  match
    Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
      ~base_path
      meta.name
  with
  | Error error ->
      Error
        (Printf.sprintf
           "invalid keeper profile for keeper %s: %s"
           meta.name
           (Keeper_types_profile.keeper_toml_load_error_to_string error))
  | Ok defaults -> effective_meta_of_profile_defaults defaults meta
;;

(* A keeper's runtime is assigned in runtime.toml ([[runtime.assignments]],
   the sole SSOT), keyed by keeper name. An unassigned keeper uses the default
   runtime. The id is opaque here; only the AGENT_CORE adapter parses it. *)
let runtime_id_of_meta (meta : keeper_meta) =
  match Runtime.runtime_id_for_keeper meta.name with
  | Some runtime_id when String.trim runtime_id <> "" -> String.trim runtime_id
  (* schema-compat: this changes only the fallback route accessor; no
     [keeper_meta] wire field or persisted variant is removed. *)
  (* The route, not the runtime it enters on: [\[runtime\].default] may name a
     declared lane, and a keeper with no assignment walks that lane's
     candidates the same way an assigned one does. *)
  | Some _ | None -> Runtime.get_default_route ()
;;

let proactive_cycle_outcome_to_string = function
  | Proactive_never_started -> "never_started"
  | Proactive_unknown -> "unknown"
  | Proactive_silent -> "silent"
  | Proactive_text_response -> "text_response"
  | Proactive_tool_use -> "tool_use"
  | Proactive_mixed_response -> "mixed_response"
  | Proactive_error -> "error"
;;

(* The inverse of [proactive_cycle_outcome_to_string] over every variant, so
   a new variant is parsed as soon as it has a label. *)
let proactive_cycle_outcome_of_string raw =
  List.find_opt
    (fun outcome -> String.equal raw (proactive_cycle_outcome_to_string outcome))
    all_of_proactive_cycle_outcome
;;

let all_proactive_cycle_outcomes = all_of_proactive_cycle_outcome

(* -- Updater helpers -- *)

let map_usage (f : usage_metrics -> usage_metrics) (m : keeper_meta) : keeper_meta =
  { m with runtime = { m.runtime with usage = f m.runtime.usage } }
;;

let zero_usage : usage_metrics =
  { total_turns = 0
  ; total_input_tokens = 0
  ; total_output_tokens = 0
  ; total_tokens = 0
  ; total_cost_usd = Keeper_cost_coverage.empty
  ; last_turn_ts = 0.0
  ; last_input_tokens = 0
  ; last_output_tokens = 0
  ; last_total_tokens = 0
  ; last_usage_reported_at = None
  ; last_latency_ms = 0
  }
;;

let reset_runtime_state (m : keeper_meta) : keeper_meta =
  map_usage (fun _ -> zero_usage) m
;;
