
(** Tool_registration_check — Startup validation of Tool_spec vs TOML coverage. *)

type validation_result = {
  orphan_toml : string list;
  (** Configured in tool_policy.toml but missing from the runtime keeper tool universe. *)
  uncovered : string list;
  (** Reserved for reverse-coverage diagnostics; currently non-fatal and may be empty. *)
}

val validate : unit -> validation_result
(** Returns empty validation result. Policy-driven validation removed
    with keeper_tool_policy_config deletion. *)

val log_validation_result : validation_result -> unit
(** Log warnings for any mismatches. *)
