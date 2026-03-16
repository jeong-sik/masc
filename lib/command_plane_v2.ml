(** Command_plane_v2 — backward-compatible facade.

    All definitions have been extracted into smaller modules.
    This file re-exports them so that external callers
    (tool_command_plane, operator_control, swarm_status, etc.)
    continue to work without any changes.

    Module dependency chain:
      Cp_types -> Cp_paths -> Cp_serde -> Cp_io
        -> Cp_unit -> Cp_snapshot -> Cp_lifecycle -> Cp_lifecycle_policy
*)

include Cp_lifecycle_policy
