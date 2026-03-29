(** Keeper_types_support — model selection, path utilities,
    and JSONL append/rotation helpers.

    Extracted from keeper_types.ml to reduce file size.
    Depends only on Keeper_config (no Keeper_types dependency). *)

include Keeper_config

(* Duplicated from Keeper_types to avoid circular dependency. *)
let mkdir_p_ path =
  Fs_compat.mkdir_p path

(* Directory-creation cache: avoid repeated mkdir_p syscalls for the same path. *)
let _ensured_dirs_ : (string, unit) Hashtbl.t = Hashtbl.create 8

let ensure_dir_ d =
  if not (Hashtbl.mem _ensured_dirs_ d) then begin
    mkdir_p_ d;
    Hashtbl.replace _ensured_dirs_ d ()
  end;
  d

let keeper_dir_ (config : Room.config) =
  let d = Filename.concat (Room.masc_root_dir config) "keepers" in
  ensure_dir_ d

let session_base_dir_ (config : Room.config) =
  let d = Filename.concat (Room.masc_root_dir config) "traces" in
  ensure_dir_ d

(** Check API key availability using model label strings.
    Delegates to Oas_model_resolve which uses OAS Provider_registry directly. *)
let ensure_api_keys_for_labels (labels : string list) : (unit, string) result =
  Oas_model_resolve.ensure_api_keys_for_labels labels

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

let keeper_memory_bank_path config name =
  Filename.concat (keeper_dir_ config) (name ^ ".memory.jsonl")

let keeper_session_dir config trace_id =
  Filename.concat (session_base_dir_ config) trace_id

let keeper_history_path config trace_id =
  Filename.concat (keeper_session_dir config trace_id) "history.jsonl"

let keeper_policy_log_path config name =
  Filename.concat (keeper_dir_ config) (name ^ ".policy.jsonl")

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
    match (try Some (Unix.stat path) with Unix.Unix_error _ -> None) with
    | None -> ()
    | Some st ->
        if st.Unix.st_size >= max_bytes then begin
          for i = max_rotated downto 2 do
            let src = Printf.sprintf "%s.%d" path (i - 1) in
            let dst = Printf.sprintf "%s.%d" path i in
            (try Sys.rename src dst with Sys_error _ -> ())
          done;
          let rotated = Printf.sprintf "%s.1" path in
          (try Sys.rename path rotated with Sys_error _ -> ())
        end

let append_jsonl_line path (json : Yojson.Safe.t) =
  maybe_rotate_file path;
  let line = utf8_repair_string (Yojson.Safe.to_string json) ^ "\n" in
  Fs_compat.append_file path line
