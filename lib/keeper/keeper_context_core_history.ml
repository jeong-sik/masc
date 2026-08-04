(** History JSONL routing and persistence helpers for keeper context. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(* Note: this module is `include`d into Keeper_context_core which already
   exposes `module Message_json = Keeper_context_core_message_json`. Avoid
   re-declaring the alias here to prevent a duplicate-definition error at
   the include site; reference the underlying module qualified instead. *)

let normalize_system_context_prefix (text : string) : string =
  let trimmed = String.trim text in
  let prefix = "[system context]" in
  if String.starts_with ~prefix trimmed
  then (
    let prefix_len = String.length prefix in
    let rest_len = String.length trimmed - prefix_len in
    if rest_len <= 0 then "" else String.trim (String.sub trimmed prefix_len rest_len))
  else trimmed

let has_world_state_signature (text : string) : bool =
  let trimmed = normalize_system_context_prefix text in
  String_util.contains_substring_ci trimmed "## Current World State"
  &&
  (String_util.contains_substring_ci trimmed "### Namespace State"
   || String_util.contains_substring_ci trimmed "### Available Tools"
   || String_util.contains_substring_ci trimmed "### Continuity")

type history_line_action =
  | Keep_main
  | Move_internal
  | Drop_line

let classify_history_entry ~(source : string) ~(content : string) :
    history_line_action =
  (* World-state headings can appear in user-authored long-term memory.
     Only explicit prompt/internal sources control history routing. *)
  ignore content;
  if Keeper_types_support.is_prompt_history_source source
  then Drop_line
  else if Keeper_types_support.is_internal_history_source source
  then Move_internal
  else Keep_main

let history_path_for_source ~(session_dir : string) ~(source : string option) :
    string =
  match source with
  | Some source when Keeper_types_support.is_internal_history_source source ->
      Filename.concat session_dir "history.internal.jsonl"
  | _ -> Filename.concat session_dir "history.jsonl"

let persist_message ?source session msg =
  let msg = Inference_utils.sanitize_message_utf8 msg in
  let source_text =
    match source with
    | Some raw -> String.trim raw
    | None -> ""
  in
  let content_text = Agent_sdk.Types.visible_text_of_message msg in
  if classify_history_entry ~source:source_text ~content:content_text = Drop_line
  then ()
  else
    let path = history_path_for_source ~session_dir:session.session_dir ~source in
    let now_ts = Time_compat.now () in
    let payload =
      match Keeper_context_core_message_json.message_to_json msg with
      | `Assoc fields ->
          let fields =
            match source with
            | Some source when String.trim source <> "" ->
                ("source", `String source) :: fields
            | _ -> fields
          in
          `Assoc
            (("timestamp", `Float now_ts) :: ("ts_unix", `Float now_ts) :: fields)
      | j -> j
    in
    let line = Yojson.Safe.to_string payload ^ "\n" in
    Fs_compat.append_file path line
