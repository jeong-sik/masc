(* Every model-facing guidance sentence the filesystem tools emit lives in a
   managed template under the keeper.tool_filesystem prefix; the execution
   path only picks the variant and supplies the data. A template that does
   not render is logged and falls back to the bare data, never to prose
   written here — the same contract [render_gate_replay_prompt] established.

   This machinery is its own module because BOTH lanes render these slots:
   the host lane ([Keeper_tool_filesystem_runtime]) and the remote lane
   ([Keeper_tool_filesystem_remote_write]), while the runtime already calls
   into the remote lane. Keeping the variant here is what lets both lanes
   share the sentences — and the operator overrides that rewrite them —
   without a module cycle. *)
type t =
  | Offset_not_1_based of { offset : int }
  | Limit_not_positive of { limit : int }
  | Invalid_read_integer of
      { coordinate : Keeper_tool_read_window.coordinate; value : Yojson.Safe.t }
  | Invalid_read_arguments of { value : Yojson.Safe.t }
  | Available_cwds_partial of
      { limit : string
      ; cwds : string
      }
  | Checkout_scan_failed of { detail : string }
  | Offset_beyond_window of
      { offset : int
      ; window_bytes : int
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

let key = function
  | Offset_not_1_based _ -> Prompt_names.keeper_tool_filesystem_offset_not_1_based
  | Limit_not_positive _ -> Prompt_names.keeper_tool_filesystem_limit_not_positive
  | Invalid_read_integer _ -> Prompt_names.keeper_tool_filesystem_invalid_read_integer
  | Invalid_read_arguments _ -> Prompt_names.keeper_tool_filesystem_invalid_read_arguments
  | Available_cwds_partial _ -> Prompt_names.keeper_tool_filesystem_available_cwds_partial
  | Checkout_scan_failed _ -> Prompt_names.keeper_tool_filesystem_checkout_scan_failed
  | Offset_beyond_window _ -> Prompt_names.keeper_tool_filesystem_offset_beyond_window
  | Capability_unavailable -> Prompt_names.keeper_tool_filesystem_capability_unavailable
  | Publication_failed -> Prompt_names.keeper_tool_filesystem_publication_failed
  | Directory_publication_failed ->
    Prompt_names.keeper_tool_filesystem_directory_publication_failed
  | Append_capability_failed ->
    Prompt_names.keeper_tool_filesystem_append_capability_failed
  | Append_incomplete -> Prompt_names.keeper_tool_filesystem_append_incomplete
  | Recovery_lane_committed -> Prompt_names.keeper_tool_filesystem_recovery_lane_committed
  | Recovery_lane_effect_observed ->
    Prompt_names.keeper_tool_filesystem_recovery_lane_effect_observed
  | Recovery_lane_not_executed ->
    Prompt_names.keeper_tool_filesystem_recovery_lane_not_executed
  | Recovery_lane_indeterminate ->
    Prompt_names.keeper_tool_filesystem_recovery_lane_indeterminate
  | Recovery_lane_cleanup_detail ->
    Prompt_names.keeper_tool_filesystem_recovery_lane_cleanup_detail
  | Gate_record_unavailable -> Prompt_names.keeper_tool_filesystem_gate_record_unavailable
  | Path_required -> Prompt_names.keeper_tool_filesystem_path_required
  | Patch_requires_old_string ->
    Prompt_names.keeper_tool_filesystem_patch_requires_old_string
  | Patch_target_missing -> Prompt_names.keeper_tool_filesystem_patch_target_missing
;;

let coordinate_name = function
  | Keeper_tool_read_window.Offset -> "offset"
  | Keeper_tool_read_window.Limit -> "limit"
;;

(* Rejected values may not be serializable JSON (for example a nonfinite
   number). Their type remains useful diagnostic data; encoding failure must
   not turn an argument rejection into an exception. *)
let diagnostic_value value =
  match Yojson.Safe.to_string value with
  | rendered -> rendered
  | exception Yojson.Json_error _ -> Json_util.kind_name value
;;

let vars = function
  | Offset_not_1_based { offset } -> [ "offset", string_of_int offset ]
  | Limit_not_positive { limit } -> [ "limit", string_of_int limit ]
  | Invalid_read_integer { coordinate; value } ->
    [ "coordinate", coordinate_name coordinate
    ; "value", diagnostic_value value
    ; "maximum", string_of_int max_int ]
  | Invalid_read_arguments { value } -> [ "value", diagnostic_value value ]
  | Available_cwds_partial { limit; cwds } -> [ "limit", limit; "cwds", cwds ]
  | Checkout_scan_failed { detail } -> [ "detail", detail ]
  | Offset_beyond_window { offset; window_bytes } ->
    [ "offset", string_of_int offset; "window_bytes", string_of_int window_bytes ]
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
  | Patch_target_missing -> []
;;

(* Bare data, never prose written here: the model still gets the payload the
   guidance was annotating, and the operator gets the log line naming the
   missing asset (#32848 precedent). *)
let fallback guidance =
  match guidance with
  | Offset_not_1_based { offset } -> Printf.sprintf "offset=%d" offset
  | Limit_not_positive { limit } -> Printf.sprintf "limit=%d" limit
  | Invalid_read_integer { coordinate; value } ->
    Printf.sprintf "%s=%s" (coordinate_name coordinate) (diagnostic_value value)
  | Invalid_read_arguments { value } -> diagnostic_value value
  | Available_cwds_partial { limit; cwds } -> Printf.sprintf "limit=%s cwds=%s" limit cwds
  | Checkout_scan_failed { detail } -> detail
  | Offset_beyond_window { offset; window_bytes } ->
    Printf.sprintf "offset=%d window_bytes=%d" offset window_bytes
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
  | Patch_target_missing -> key guidance
;;

let text guidance =
  let key = key guidance in
  match Prompt_registry.render_prompt_template key (vars guidance) with
  | Ok text -> String.trim text
  | Error detail ->
    Log.Keeper.error
      "filesystem tool guidance %s did not render, falling back to the bare data: %s"
      key
      detail;
    fallback guidance
;;

(* Both lanes render these two no-payload sentences through the accessors
   below so an operator override rewrites host and remote results together. *)
let patch_requires_old_string_text () = text Patch_requires_old_string
let patch_target_missing_text () = text Patch_target_missing
