(** The names that the read path and the write path of
    [Keeper_tool_filesystem_runtime] share.

    [fs_write_mode] is [Keeper_tool_write_mode.t]. [prepared_edit],
    [prepared_read] and [prepared_write] are the handles of a prepared file.
    [edit_preparation_error] says why an edit could not be prepared.
    [fs_write_mode_to_string] and [valid_fs_write_mode_strings] name the write
    modes, and [fs_guidance_text] renders a guidance value as the text of a
    tool answer.
    [Keeper_tool_filesystem_runtime] includes this module. *)

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

val fs_write_mode_to_string : fs_write_mode -> string

val valid_fs_write_mode_strings : string list

val fs_guidance_text : Keeper_tool_filesystem_guidance.t -> string
