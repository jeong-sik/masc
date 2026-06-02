
(** Tool_registration_check — Startup validation of Tool_spec vs TOML coverage. *)

type validation_result = {
  orphan_toml : string list;
  (** Configured in tool_policy.toml but missing from the runtime keeper tool universe. *)
  uncovered : string list;
  (** Reserved for reverse-coverage diagnostics; currently non-fatal and may be empty. *)
}

type policy_config = { configured_tools : string list }
(** Keeper-facing policy snapshot supplied by the runtime boundary. *)

val validate : ?policy_config:policy_config -> unit -> validation_result
(** Cross-validate tool_policy.toml against the runtime keeper tool universe.
    Returns orphan/uncovered tool names. Safe to call when policy not loaded. *)

val log_validation_result : validation_result -> unit
(** Log warnings for any mismatches. *)
