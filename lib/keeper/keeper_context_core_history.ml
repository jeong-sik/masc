(** History JSONL migration and persistence helpers for keeper context. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module StringSet = Set_util.StringSet

(* Note: this module is `include`d into Keeper_context_core which already
   exposes `module Message_json = Keeper_context_core_message_json`. Avoid
   re-declaring the alias here to prevent a duplicate-definition error at
   the include site; reference the underlying module qualified instead. *)

type history_migration_stats =
  { moved_lines : int
  ; dropped_lines : int
  ; kept_lines : int
  ; malformed_lines : int
  }

type history_migration_stage =
  | Internal_history
  | Main_history

type history_migration_error =
  | History_write_not_committed of
      { stage : history_migration_stage
      ; path : string
      ; report : unit Fs_compat.Durable_mutation.report
      }
  | History_write_committed_not_durable of
      { stage : history_migration_stage
      ; path : string
      ; report : unit Fs_compat.Durable_mutation.report
      }
  | History_directory_durability_not_confirmed of
      { stage : history_migration_stage
      ; path : string
      ; report : Fs_compat.Durable_mutation.durability_confirmation_report
      }

let history_migration_stage_to_string = function
  | Internal_history -> "internal_history"
  | Main_history -> "main_history"
;;

let history_migration_error_to_string = function
  | History_write_not_committed { stage; path; report } ->
    Printf.sprintf
      "history migration %s write not committed path=%s: %s"
      (history_migration_stage_to_string stage)
      path
      (Fs_compat.Durable_mutation.report_to_string report)
  | History_write_committed_not_durable { stage; path; report } ->
    Printf.sprintf
      "history migration %s write committed but not durable path=%s: %s"
      (history_migration_stage_to_string stage)
      path
      (Fs_compat.Durable_mutation.report_to_string report)
  | History_directory_durability_not_confirmed { stage; path; report } ->
    let detail =
      match report.confirmation with
      | Fs_compat.Durable_mutation.Not_confirmed { cause; _ } ->
        Printexc.to_string cause
      | Fs_compat.Durable_mutation.Confirmed -> "unexpected confirmed state"
    in
    Printf.sprintf
      "history migration %s directory durability not confirmed path=%s: %s"
      (history_migration_stage_to_string stage)
      path
      detail
;;

let empty_history_migration_stats =
  { moved_lines = 0; dropped_lines = 0; kept_lines = 0; malformed_lines = 0 }

let split_jsonl_lines (content : string) : string list =
  content
  |> String.split_on_char '\n'
  |> List.filter (fun line -> String.trim line <> "")

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

let classify_history_jsonl_line (line : string) : history_line_action option =
  try
    let json = Yojson.Safe.from_string line in
    let source =
      match Json_util.get_string json "source" with
      | Some raw -> String.trim raw
      | None -> ""
    in
    let content = String.trim (Keeper_context_core_message_json.text_of_history_jsonl_json json) in
    Some (classify_history_entry ~source ~content)
  with
  | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None

let render_jsonl_lines (lines : string list) : string =
  match lines with
  | [] -> ""
  | _ -> String.concat "\n" lines ^ "\n"

let dedupe_preserve_order (lines : string list) : string list =
  let rec go seen acc = function
    | [] -> List.rev acc
    | line :: rest ->
        if StringSet.mem line seen
        then go seen acc rest
        else go (StringSet.add line seen) (line :: acc) rest
  in
  go StringSet.empty [] lines

let migrate_session_history_logs_with
  ?(confirm_parent_durable =
    Fs_compat.Durable_mutation.confirm_directory_durable_blocking)
  writer
  ~(session_dir : string)
  =
  let main_path = Filename.concat session_dir "history.jsonl" in
  let internal_path = Filename.concat session_dir "history.internal.jsonl" in
  if (not (Fs_compat.file_exists main_path))
     && not (Fs_compat.file_exists internal_path)
  then Ok empty_history_migration_stats
  else
    let main_content =
      if Fs_compat.file_exists main_path then Fs_compat.load_file main_path else ""
    in
    let main_lines =
      split_jsonl_lines main_content
    in
    let existing_internal_content =
      if Fs_compat.file_exists internal_path
      then Fs_compat.load_file internal_path
      else ""
    in
    let existing_internal =
      split_jsonl_lines existing_internal_content
    in
    let kept_rev, moved_rev, dropped_main, malformed_main =
      List.fold_left
        (fun (kept_rev, moved_rev, dropped_lines, malformed_lines) line ->
          match classify_history_jsonl_line line with
          | Some Keep_main ->
              line :: kept_rev, moved_rev, dropped_lines, malformed_lines
          | Some Move_internal ->
              kept_rev, line :: moved_rev, dropped_lines, malformed_lines
          | Some Drop_line ->
              kept_rev, moved_rev, dropped_lines + 1, malformed_lines
          | None ->
              line :: kept_rev, moved_rev, dropped_lines, malformed_lines + 1)
        ([], [], 0, 0)
        main_lines
    in
    let kept_lines = List.rev kept_rev in
    let moved_lines = List.rev moved_rev in
    let internal_kept_rev, dropped_internal, malformed_internal =
      List.fold_left
        (fun (kept_rev, dropped_lines, malformed_lines) line ->
          match classify_history_jsonl_line line with
          | Some Drop_line -> kept_rev, dropped_lines + 1, malformed_lines
          | Some _ -> line :: kept_rev, dropped_lines, malformed_lines
          | None -> line :: kept_rev, dropped_lines, malformed_lines + 1)
        ([], 0, 0)
        existing_internal
    in
    let sanitized_internal = List.rev internal_kept_rev in
    let total_dropped = dropped_main + dropped_internal in
    let malformed_lines = malformed_main + malformed_internal in
    if moved_lines = [] && total_dropped = 0
    then
      Ok
        { moved_lines = 0
        ; dropped_lines = 0
        ; kept_lines = List.length kept_lines
        ; malformed_lines
        }
    else (
      let merged_internal =
        dedupe_preserve_order (sanitized_internal @ moved_lines)
      in
      let save_history ~stage ~path ~content ~operation =
        let report = writer path content in
        let report =
          Fs_compat.Durable_mutation.observe_and_retain
            (fun report ->
               match report.progress with
               | Fs_compat.Durable_mutation.Not_committed _ ->
                 Otel_metric_store.inc_counter
                   Keeper_metrics.(to_string CheckpointFailures)
                   ~labels:
                     [ ( "operation"
                       , Keeper_checkpoint_failure_operation.(to_label operation)
                       )
                     ]
                   ();
                 Log.Keeper.error
                   "migrate_session_history_logs: save not committed for %s: %s"
                   path
                   (Fs_compat.Durable_mutation.report_to_string report)
               | Fs_compat.Durable_mutation.Committed_not_durable _ ->
                 Log.Keeper.warn
                   "migrate_session_history_logs: committed with sync debt path=%s detail=%s"
                   path
                   (Fs_compat.Durable_mutation.report_to_string report)
               | Fs_compat.Durable_mutation.Durable () ->
                 (match report.diagnostics with
                  | [] -> ()
                  | _ ->
                    Log.Keeper.warn
                      "migrate_session_history_logs: durable with cleanup diagnostics path=%s detail=%s"
                      path
                      (Fs_compat.Durable_mutation.report_to_string report)))
            report
        in
        Fs_compat.Durable_mutation.fold_report report
          ~not_committed:(fun report ->
            Error (History_write_not_committed { stage; path; report }))
          ~committed_not_durable:(fun report ->
            Error (History_write_committed_not_durable { stage; path; report }))
          ~durable:(fun _report -> Ok ())
      in
      let confirm_history_parent ~stage ~path =
        let report = confirm_parent_durable (Filename.dirname path) in
        let report =
          Fs_compat.Durable_mutation.observe_confirmation_and_retain
            (fun report ->
               match report.confirmation_diagnostics with
               | [] -> ()
               | diagnostics ->
                 Log.Keeper.warn
                   "migrate_session_history_logs: directory durability confirmation has diagnostics path=%s detail=%s"
                   path
                   (String.concat
                      "; "
                      (List.map
                         Fs_compat.Durable_mutation.diagnostic_to_string
                         diagnostics)))
            report
        in
        match report.confirmation with
        | Fs_compat.Durable_mutation.Not_confirmed _ ->
          Error
            (History_directory_durability_not_confirmed
               { stage; path; report })
        | Fs_compat.Durable_mutation.Confirmed -> Ok ()
      in
      let next_internal_content = render_jsonl_lines merged_internal in
      let internal_result =
        if String.equal next_internal_content existing_internal_content
        then
          if moved_lines = []
          then Ok ()
          else confirm_history_parent ~stage:Internal_history ~path:internal_path
        else
          save_history
            ~stage:Internal_history
            ~path:internal_path
            ~content:next_internal_content
            ~operation:Keeper_checkpoint_failure_operation.Migrate_internal_history
      in
      match internal_result with
      | Error _ as error -> error
      | Ok () ->
        let next_main_content = render_jsonl_lines kept_lines in
        let main_result =
          if String.equal next_main_content main_content
          then Ok ()
          else
            save_history
              ~stage:Main_history
              ~path:main_path
              ~content:next_main_content
              ~operation:Keeper_checkpoint_failure_operation.Migrate_main_history
        in
        (match main_result with
         | Error _ as error -> error
         | Ok () ->
           Ok
             { moved_lines = List.length moved_lines
             ; dropped_lines = total_dropped
             ; kept_lines = List.length kept_lines
             ; malformed_lines
             }))
;;

let migrate_session_history_logs_blocking =
  migrate_session_history_logs_with Fs_compat.save_file_atomic_blocking
;;

let migrate_session_history_logs_eio ~session_dir =
  Eio.Cancel.protect (fun () ->
    Eio_unix.run_in_systhread ~label:"keeper-history-migration" (fun () ->
      migrate_session_history_logs_blocking ~session_dir))
;;

module For_testing = struct
  let migrate_session_history_logs_with = migrate_session_history_logs_with
end

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
