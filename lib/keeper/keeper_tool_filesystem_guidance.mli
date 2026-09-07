(** Model-facing tool-result guidance for the filesystem tools, rendered from
    the managed [keeper.tool_filesystem.*] slots.

    Shared by the host lane ([Keeper_tool_filesystem_runtime]) and the remote
    lane ([Keeper_tool_filesystem_remote_write]): the runtime already calls
    into the remote lane, so the variant and its renderer live here to keep
    that the only direction between the two lanes. *)

type t =
  | Offset_not_1_based of { offset : int }
  | Limit_not_positive of { limit : int }
  | Available_cwds_partial of
      { limit : string
      ; cwds : string
      }
  | Checkout_scan_failed of { detail : string }
  | Cwd_not_directory of { cwd : string }
  | Offset_beyond_window of
      { offset : int
      ; window_bytes : int
      }
  | Offset_beyond_scan_budget of
      { offset : int
      ; file_bytes : int
      ; budget : int
      }
  | Capability_unavailable
  | Publication_failed
  | Directory_publication_failed
  | Append_capability_failed
  | Append_incomplete
  | Recovery_lane_committed
  | Recovery_lane_effect_observed
  | Recovery_lane_not_executed
  | Recovery_lane_indeterminate
  | Recovery_lane_cleanup_detail
  | Gate_record_unavailable
  | Path_required
  | Patch_requires_old_string
  | Patch_target_missing

(** Render the arm's managed template; on render failure log and return the
    bare data (never inline prose). *)
val text : t -> string

val patch_requires_old_string_text : unit -> string

(** Both lanes render these two no-payload sentences through these accessors
    so an operator override rewrites host and remote results together. *)
val patch_target_missing_text : unit -> string
