(** Tool_registration_check — Startup validation of Tool_spec vs TOML coverage. *)

type validation_result =
  { orphan_toml : string list
    (** Configured in tool_policy.toml but missing from the runtime keeper tool universe. *)
  ; uncovered : string list
    (** Reserved for reverse-coverage diagnostics; currently non-fatal and may be empty. *)
  }

(** Cross-validate tool_policy.toml against the runtime keeper tool universe.
    Returns orphan/uncovered tool names. Safe to call when policy not loaded. *)
val validate : unit -> validation_result

(** Log warnings for any mismatches. *)
val log_validation_result : validation_result -> unit
