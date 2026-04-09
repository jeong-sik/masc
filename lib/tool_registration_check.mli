(** Tool_registration_check — Startup validation of Tool_spec vs TOML coverage. *)

type validation_result = {
  orphan_toml : string list;
  (** In TOML groups but no Tool_spec registration *)
  uncovered : string list;
  (** Registered in Tool_spec but not in any TOML group *)
}

val validate : unit -> validation_result
(** Cross-validate registered Tool_spec names against tool_policy.toml groups.
    Returns orphan/uncovered tool names. Safe to call when policy not loaded. *)

val log_validation_result : validation_result -> unit
(** Log warnings for any mismatches. *)
