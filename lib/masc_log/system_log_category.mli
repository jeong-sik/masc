(** Closed-sum SSOT for operator-facing log categories.

    RFC-0155: replaces post-hoc substring-match classification in
    [memory/masc-oas-log-reduction-measure.py:76] with an emit-side
    typed variant. New categories require compile-time exhaustive match
    update on every reader. *)

type t =
  | Task_ownership_ambiguity_current_task_unset
  | State_store_current_task_path_corruption
  | Config_env_allowlist_drift
  | Telemetry_or_metadata_parse_drop
  | Host_fd_pressure
  | Docker_start_pressure
  | Keeper_stale_watchdog_lifecycle
  | Provider_timeout
  | Provider_cascade_exhaustion
  | Required_tool_contract_mismatch
  | Task_state_probe_misuse
  | Verifier_action_guard
  | Network_error_other
  | Other_boundary_unclassified of { hint : string }
(** 14 variants reverse-engineered from [measure.py:system_category]
    (PR #17146 reference). [Other_boundary_unclassified] is reserved
    for external boundary noise; its [hint] is the trace for promoting
    to a typed variant when frequency justifies. *)

val to_string : t -> string
(** Stable JSON-safe label. Constructor name in lowercase
    snake_case (matches the strings measure.py currently produces).
    [Other_boundary_unclassified] becomes
    [Printf.sprintf "other:%s" hint] for routing parity. *)

val of_string_opt : string -> t option
(** Inverse for known variants. [Other_boundary_unclassified] cannot
    be reconstructed via this function — it requires explicit
    construction with a hint at emit boundary. *)

val all : t list
(** Enumeration of structural variants (excludes [Other_boundary_unclassified]).
    Used by exhaustiveness tests and downstream tooling. *)
