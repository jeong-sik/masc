(** History JSONL routing and persistence helpers for keeper context. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(* Note: this module is `include`d into Keeper_context_core which already
   exposes `module Message_json = Keeper_context_core_message_json`. Avoid
   re-declaring the alias here to prevent a duplicate-definition error at
   the include site; reference the underlying module qualified instead. *)

type history_line_action =
  | Keep_main
  | Move_internal
  | Drop_line

(* Only explicitly classified user/assistant turns belong in the dashboard-facing
   history. Missing and unknown labels are quarantined in the internal file so
   legacy or typo'd world-state rows cannot become conversation records. *)
let is_main_history_source (source : string) =
  match String.lowercase_ascii (String.trim source) with
  | "direct_user" | "direct_assistant" -> true
  | _ -> false

let classify_history_entry ~(source : string) : history_line_action =
  if Keeper_types_support.is_prompt_history_source source
  then Drop_line
  else if is_main_history_source source
  then Keep_main
  else Move_internal

let history_path_for_source ~(session_dir : string) ~(source : string option) :
    string =
  match source with
  | Some source when classify_history_entry ~source = Keep_main ->
      Filename.concat session_dir "history.jsonl"
  | _ -> Filename.concat session_dir "history.internal.jsonl"

let persist_message ?source session msg =
  let msg = Inference_utils.sanitize_message_utf8 msg in
  let source_text =
    match source with
    | Some raw -> String.trim raw
    | None -> ""
  in
  if classify_history_entry ~source:source_text = Drop_line
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
