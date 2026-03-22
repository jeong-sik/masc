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

(* Connect CP cleanup callback to Room_gc to break the circular dependency.
   Room_gc cannot directly reference Cp_cleanup (which depends on Room via
   Cp_io -> Cp_paths -> Room), so we use a ref-based callback. *)
let () =
  Room_hooks.cp_cleanup_connected := true;
  Room_hooks.cp_cleanup_fn :=
    (fun config ->
      let r = Cp_cleanup.cleanup_cp config in
      {
        Room_hooks.dead_units_removed = r.Cp_cleanup.dead_units_removed;
        orphaned_units_removed = r.Cp_cleanup.orphaned_units_removed;
        operations_archived = r.Cp_cleanup.operations_archived;
        detachments_removed = r.Cp_cleanup.detachments_removed;
        intents_removed = r.Cp_cleanup.intents_removed;
      })
