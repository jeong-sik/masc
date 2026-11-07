(* The write mode is defined once in [Keeper_tool_write_mode], shared with the
   remote-lane handler; the names below keep this module's surface. *)
type fs_write_mode = Keeper_tool_write_mode.t =
  | Overwrite
  | Append
  | Patch

type prepared_edit = Keeper_prepared_file.t
type prepared_read = Keeper_prepared_file.t
type prepared_write = Keeper_prepared_file.Write.t

type edit_preparation_error =
  | Edit_path_refused of Keeper_alerting_path.path_refusal
  | Edit_resource_unavailable of string

let fs_write_mode_to_string = Keeper_tool_write_mode.to_string
let valid_fs_write_mode_strings = Keeper_tool_write_mode.valid_strings

let fs_guidance_text = Keeper_tool_filesystem_guidance.text
