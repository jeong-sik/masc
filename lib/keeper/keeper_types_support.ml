(** Keeper_types_support — model selection, path utilities,
    and JSONL append/rotation helpers.

    Extracted from keeper_types.ml to reduce file size.
    Depends only on Keeper_config (no Keeper_types dependency). *)

include Keeper_config

(* Delegated to Keeper_fs — single fiber-safe ensure_dir implementation. *)
let mkdir_p_ path = Fs_compat.mkdir_p path
let ensure_dir_ = Keeper_fs.ensure_dir

(** Backward-compatible mkdir_p: delegates to Keeper_fs.ensure_dir.
    Used by external callers via [Keeper_types.mkdir_p]. *)
let mkdir_p path = ignore (Keeper_fs.ensure_dir path)

let keeper_dir_ (config : Coord.config) =
  let d = Filename.concat (Coord.masc_root_dir config) "keepers" in
  ensure_dir_ d

let session_base_dir_ (config : Coord.config) =
  let d = Filename.concat (Coord.masc_root_dir config) "traces" in
  ensure_dir_ d

(** Check API key availability using model label strings.
    Delegates to Cascade_runtime which owns MASC cascade resolution. *)
let ensure_api_keys_for_labels (labels : string list) : (unit, string) result =
  Cascade_runtime.ensure_api_keys_for_labels labels

(** Single-file metrics path kept for fallback reads. *)
let keeper_metrics_path config name =
  Filename.concat (keeper_dir_ config) (name ^ ".metrics.jsonl")

(** Date-split metrics store: [.masc/keepers/<name>/metrics/YYYY-MM/DD.jsonl].
    Cached per keeper name so all callers share the same Eio.Mutex. *)
let metrics_store_cache : (string, Dated_jsonl.t) Hashtbl.t = Hashtbl.create 8
let metrics_store_mu = Eio.Mutex.create ()

let keeper_metrics_store config name : Dated_jsonl.t =
  let dir = Filename.concat (keeper_dir_ config) (name ^ "/metrics") in
  let lookup () =
    match Hashtbl.find_opt metrics_store_cache dir with
    | Some store -> store
    | None ->
      let store = Dated_jsonl.create ~base_dir:dir () in
      Hashtbl.replace metrics_store_cache dir store;
      store
  in
  Eio_guard.with_mutex metrics_store_mu lookup

let execution_receipt_store_cache : (string, Dated_jsonl.t) Hashtbl.t =
  Hashtbl.create 8

let execution_receipt_store_mu = Eio.Mutex.create ()

let keeper_execution_receipt_store config name : Dated_jsonl.t =
  let dir =
    Filename.concat (keeper_dir_ config) (name ^ "/execution-receipts")
  in
  let lookup () =
    match Hashtbl.find_opt execution_receipt_store_cache dir with
    | Some store -> store
    | None ->
      let store = Dated_jsonl.create ~base_dir:dir () in
      Hashtbl.replace execution_receipt_store_cache dir store;
      store
  in
  Eio_guard.with_mutex execution_receipt_store_mu lookup

let keeper_memory_bank_path config name =
  Filename.concat (keeper_dir_ config) (name ^ ".memory.jsonl")

let keeper_progress_path config name =
  let d = Filename.concat (keeper_dir_ config) name in
  ignore (ensure_dir_ d);
  Filename.concat d "progress.md"

let keeper_generation_index_path config name =
  Filename.concat (keeper_dir_ config) (name ^ ".generation_index.jsonl")

let keeper_session_dir config trace_id =
  Filename.concat (session_base_dir_ config) trace_id

let keeper_generation_manifest_path config trace_id =
  Filename.concat (keeper_session_dir config trace_id) "generation_manifest.json"

let keeper_history_path config trace_id =
  Filename.concat (keeper_session_dir config trace_id) "history.jsonl"

let keeper_internal_history_path config trace_id =
  Filename.concat (keeper_session_dir config trace_id) "history.internal.jsonl"

let normalize_history_source (source : string) =
  source |> String.trim |> String.lowercase_ascii

let is_prompt_history_source (source : string) =
  String.equal (normalize_history_source source) "world_state_prompt"

let is_internal_history_source (source : string) =
  match normalize_history_source source with
  | "world_state_prompt" | "internal_assistant" -> true
  | _ -> false

let keeper_policy_log_path config name =
  Filename.concat (keeper_dir_ config) (name ^ ".policy.jsonl")

let keeper_decision_log_path config name =
  Filename.concat (keeper_dir_ config) (name ^ ".decisions.jsonl")

let keeper_feedback_log_path config name =
  Filename.concat (keeper_dir_ config) (name ^ ".feedback.jsonl")

let keeper_dataset_export_path config name =
  Filename.concat (keeper_dir_ config) (name ^ ".dataset.json")

let keeper_alerts_path config =
  Filename.concat (keeper_dir_ config) "_alerts.jsonl"

let keeper_alert_retry_path config =
  Filename.concat (keeper_dir_ config) "_alerts.retry.jsonl"

let keeper_alert_deadletter_path config =
  Filename.concat (keeper_dir_ config) "_alerts.deadletter.jsonl"

(** Rotate [path] if it exceeds the configured size threshold.
    Keeps at most [max_rotated] numbered backups (.1, .2, ...). *)
let maybe_rotate_file path =
  let max_bytes = Env_config.KeeperMetrics.max_file_bytes in
  let max_rotated = Env_config.KeeperMetrics.max_rotated_files in
  if max_bytes <= 0 then ()
  else
    match Fs_compat.file_size path with
    | None -> ()
    | Some size ->
        if size >= max_bytes then begin
          for i = max_rotated downto 2 do
            let src = Printf.sprintf "%s.%d" path (i - 1) in
            let dst = Printf.sprintf "%s.%d" path i in
            try Fs_compat.rename src dst with
            | Sys_error msg when String.contains msg "No such file" -> ()
            | Sys_error msg ->
              Log.Misc.warn "rotate: cannot rename %s -> %s: %s" src dst msg
          done;
          let rotated = Printf.sprintf "%s.1" path in
          try Fs_compat.rename path rotated with
          | Sys_error msg when String.contains msg "No such file" -> ()
          | Sys_error msg ->
            Log.Misc.warn "rotate: cannot rename %s -> %s: %s" path rotated msg
        end

let append_jsonl_line path (json : Yojson.Safe.t) =
  maybe_rotate_file path;
  let line = utf8_repair_string (Yojson.Safe.to_string json) ^ "\n" in
  Fs_compat.append_file path line
