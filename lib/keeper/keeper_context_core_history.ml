(** History JSONL routing and persistence for keeper context.

    Every line names the turn that wrote it ([turn_ref]), so a reader takes a
    turn's fragments by identity and not by wall clock (RFC librarian-lifecycle
    §10-3). A line is either a conversation message or a tool observation: the
    name of a tool the turn called and how the call ended. Observations are
    what an official-client turn leaves behind for the Librarian; the call's
    arguments and result body are not conversation and never land here.

    Lines are appended with the locked, durable primitive the turn-boundary
    log uses. A crash mid-append leaves a torn tail that the next append cuts
    under the lock; a plain append could leave a torn middle that a reader
    would meet as a permanent unreadable row. A line that cannot be written is
    reported and the turn goes on: the turn's own record is the checkpoint,
    and a history line is evidence for a later reader. *)

open Keeper_types

(* Note: this module is `include`d into Keeper_context_core which already
   exposes `module Message_json = Keeper_context_core_message_json`. Avoid
   re-declaring the alias here to prevent a duplicate-definition error at
   the include site; reference the underlying module qualified instead. *)

let main_history_path ~(session_dir : string) : string =
  Filename.concat session_dir Keeper_types_support.history_file_name

let internal_history_path ~(session_dir : string) : string =
  Filename.concat session_dir Keeper_types_support.internal_history_file_name

(* The file a message goes to, or [None] when it is not written. *)
let history_path_for_source ~(session_dir : string)
    (source : Keeper_types_support.history_source) : string option =
  match source with
  | Keeper_types_support.Direct_user | Keeper_types_support.Direct_assistant ->
      Some (main_history_path ~session_dir)
  | Keeper_types_support.Internal_assistant ->
      Some (internal_history_path ~session_dir)
  | Keeper_types_support.World_state_prompt -> None

(* Wire vocabulary shared with the reader. *)
let key_ts_unix = "ts_unix"
let key_turn_ref = "turn_ref"
let key_kind = "kind"
let key_source = "source"
let key_tool_name = "tool_name"
let key_outcome = "outcome"
let kind_message = "message"
let kind_tool_observation = "tool_observation"

let not_recorded ~keeper_name ~turn_ref ~path ~site detail =
  Log.Keeper.error
    ~keeper_name
    "history fragment not recorded turn_ref=%s site=%s path=%s: %s"
    (Ids.Turn_ref.to_string turn_ref)
    site
    path
    detail;
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string HistoryFragmentFailures)
    ~labels:[ "keeper", keeper_name; "site", site ]
    ()

(* The session directory appears when something is stored in it; the append
   primitive creates the parent, as it does for the turn-boundary log. Past
   the cancellation arm every exception is reported and swallowed: the turn
   that called has its checkpoint and owes the reader nothing here. *)
let append_line ~keeper_name ~turn_ref ~session_dir ~path line =
  let failed = not_recorded ~keeper_name ~turn_ref ~path ~site:"append" in
  let report = function
  | Fs_compat.Private_file_succeeded () -> ()
  | Fs_compat.Private_file_succeeded_with_cleanup_failure { value = (); cleanup_failure } ->
      Log.Keeper.warn
        ~keeper_name
        "history fragment committed; descriptor settlement failed path=%s: %s"
        path
        (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
  | Fs_compat.Private_file_failed error ->
      failed (Fs_compat.private_jsonl_append_error_to_string error)
  | Fs_compat.Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
      failed
        (Printf.sprintf
           "%s; descriptor settlement also failed: %s"
           (Fs_compat.private_jsonl_append_error_to_string error)
           (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
  in
  (* The stable sibling session lock also owns subtree deletion and the
     official Librarian's source capture. Keep the existing file append
     protocol inside it, using the configured pathname shared by readers:
     Fs_compat keys its same-process file mutex by that exact spelling.
     The outer session owner still uses its canonical lock identity.
     Preserve a completed outcome if releasing the outer lock fails. *)
  let completed = ref None in
  match
    Keeper_checkpoint_store.with_session_lock ~session_dir (fun _canonical_session_dir ->
      let outcome = Fs_compat.append_private_jsonl_durable_locked_result path line in
      completed := Some outcome;
      outcome)
  with
  | Ok outcome -> report outcome
  | Error detail ->
    (match !completed with
     | None -> failed detail
     | Some outcome ->
       report outcome;
       Log.Keeper.warn ~keeper_name
         "history session lock settlement failed after completed append path=%s: %s"
         path detail)
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception Sys_error message -> failed message
  | exception Unix.Unix_error (code, fn, arg) ->
      failed (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))
  | exception exn -> failed (Printexc.to_string exn)

let line_of_fields fields = Yojson.Safe.to_string (`Assoc fields) ^ "\n"

let persist_message ~keeper_name ~turn_ref ~source session msg =
  let msg = Inference_utils.sanitize_message_utf8 msg in
  match history_path_for_source ~session_dir:session.session_dir source with
  | None -> ()
  | Some path ->
    let now_ts = Time_compat.now () in
    match Keeper_context_core_message_json.message_to_json msg with
    | `Assoc fields ->
        let fields =
          (key_source, `String (Keeper_types_support.history_source_to_string source))
          :: fields
        in
        let fields =
          (key_ts_unix, `Float now_ts)
          :: (key_turn_ref, Ids.Turn_ref.to_yojson turn_ref)
          :: (key_kind, `String kind_message)
          :: fields
        in
        append_line ~keeper_name ~turn_ref ~session_dir:session.session_dir
          ~path (line_of_fields fields)
    | json ->
        not_recorded
          ~keeper_name
          ~turn_ref
          ~path
          ~site:"encode"
          (Printf.sprintf
             "message json is not an object: %s"
             (Yojson.Safe.to_string json))

let persist_tool_observation ~keeper_name ~turn_ref session ~tool_name
    ~(outcome : Tool_result.tool_call_outcome) =
  let path = internal_history_path ~session_dir:session.session_dir in
  let fields =
    [ (key_ts_unix, `Float (Time_compat.now ()))
    ; (key_turn_ref, Ids.Turn_ref.to_yojson turn_ref)
    ; (key_kind, `String kind_tool_observation)
    ; (key_tool_name, `String tool_name)
    ; (key_outcome, `String (Tool_result.string_of_tool_call_outcome outcome))
    ]
  in
  append_line ~keeper_name ~turn_ref ~session_dir:session.session_dir
    ~path (line_of_fields fields)
