(** Keeper_types_support — model selection, path utilities,
    and JSONL append/rotation helpers.

    Extracted from keeper_types.ml to reduce file size.
    Depends only on Keeper_config (no Keeper_types dependency). *)

include Keeper_config

let ensure_dir_ = Keeper_fs.ensure_dir

let keeper_dir_ (config : Workspace.config) =
  let d = Workspace.keepers_runtime_dir config in
  ensure_dir_ d

let session_base_dir_ (config : Workspace.config) =
  let d = Filename.concat (Workspace.masc_root_dir config) "traces" in
  ensure_dir_ d

(** RFC-0206 single-binding: API keys for the default runtime are resolved at
    startup, so there is no per-label key check. Retained as a total no-op so
    callers keep their result-shaped contract.
    Runtime behavior changed: per-label key availability is no longer probed;
    verify keeper turn startup at deploy. *)
let ensure_api_keys_for_labels (_labels : string list) : (unit, string) result =
  Ok ()

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

let execution_receipt_v1_schema = "keeper.execution_receipt.v1"
let execution_receipt_schema = execution_receipt_v1_schema
let execution_receipts_dirname = "execution-receipts"

let keeper_execution_receipt_store config name : Dated_jsonl.t =
  let dir =
    Filename.concat (Filename.concat (keeper_dir_ config) name) execution_receipts_dirname
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

(* RFC-0233 PR-3: TurnRecord JSONL store next to the receipt store. *)
let turn_record_store_cache : (string, Dated_jsonl.t) Hashtbl.t = Hashtbl.create 8
let turn_record_store_mu = Eio.Mutex.create ()

let keeper_turn_record_store config name : Dated_jsonl.t =
  let dir = Filename.concat (keeper_dir_ config) (name ^ "/turn-records") in
  let lookup () =
    match Hashtbl.find_opt turn_record_store_cache dir with
    | Some store -> store
    | None ->
      let store = Dated_jsonl.create ~base_dir:dir () in
      Hashtbl.replace turn_record_store_cache dir store;
      store
  in
  Eio_guard.with_mutex turn_record_store_mu lookup

let keeper_runtime_dir config name =
  let dir = Filename.concat (keeper_dir_ config) name in
  ensure_dir_ dir

(* Per-keeper OAS raw-trace store: one JSONL file per keeper turn under
   [.masc/keepers/<name>/raw-traces/].  A fresh file per turn keeps
   [Agent_sdk.Raw_trace.create] from ever scanning previous turns' data
   (OAS [create -> scan_next_seq -> read_all] parses the whole target
   file to resume its seq counter), so a corrupt or oversized historical
   trace cannot block keeper dispatch and per-turn sink creation stays
   O(1) in lifetime trace volume.  Each turn's [run_ref] (path + seq
   range) recorded in the run result is the index into this store. *)
let raw_traces_dirname = "raw-traces"
let raw_trace_file_extension = ".jsonl"

(** Retention bound for the per-turn raw-trace store.  This is log
    retention, not a behavioral cap: every turn still runs and still
    traces; only the oldest persisted turn files beyond this count are
    deleted at sink-creation time.  The steady-state on-disk bound is
    [raw_trace_retained_turn_files + 1] files per keeper (the freshly
    created turn file materializes after the prune that precedes it). *)
let raw_trace_retained_turn_files = 200

let keeper_raw_trace_dir config name =
  Filename.concat
    (Filename.concat (Workspace.keepers_runtime_dir config) name)
    raw_traces_dirname

(* Strictly-increasing per-process discriminator so two turns created in
   the same millisecond never share a file name. *)
let raw_trace_turn_counter = Atomic.make 0

(* Cross-process same-millisecond collisions are disambiguated by the pid
   fragment; the bounded retry below covers even that residue.  If the
   bound is ever exhausted the candidate is still safe: [Raw_trace.create]
   resume-appends to the (tiny, same-millisecond) existing file. *)
let raw_trace_fresh_name_attempts = 8

(* Shape mirrors OAS [Raw_trace.next_worker_run_id] (ts + pid + counter). *)
let raw_trace_turn_basename () =
  let now_ms =
    (* NDT-OK: file-name prefix only — zero-padded ms sorts retention
       chronologically; keeper control flow never branches on it. *)
    Int64.of_float (Unix.gettimeofday () *. 1000.0)
  in
  let pid_fragment =
    (* NDT-OK: pid only disambiguates cross-process same-millisecond
       file names; no control flow reads it. *)
    Unix.getpid () land 0xFFFF
  in
  Printf.sprintf "turn-%013Ld-%04x-%06d%s" now_ms pid_fragment
    (Atomic.fetch_and_add raw_trace_turn_counter 1)
    raw_trace_file_extension

let keeper_raw_trace_turn_path config name =
  (* [keeper_runtime_dir] keeps the keeper dir creation of the receipt /
     checkpoint stores; the raw-traces subdir is ensured on top of it. *)
  let dir =
    ensure_dir_
      (Filename.concat (keeper_runtime_dir config name) raw_traces_dirname)
  in
  let rec fresh attempts =
    let candidate = Filename.concat dir (raw_trace_turn_basename ()) in
    if Fs_compat.file_exists candidate && attempts < raw_trace_fresh_name_attempts
    then fresh (attempts + 1)
    else candidate
  in
  fresh 0

(** Delete the oldest per-turn raw-trace files beyond
    [raw_trace_retained_turn_files].  Deterministic: candidates are the
    [.jsonl] entries of the raw-traces dir sorted by file name ascending
    (the zero-padded timestamp prefix makes that chronological), and the
    excess prefix of that order is removed.  Total: a missing dir or a
    failed unlink is logged and skipped, never raised — retention runs on
    the turn dispatch path and must not gate keeper liveness.  Returns the
    number of files removed. *)
let prune_keeper_raw_trace_turn_files config name =
  let dir = keeper_raw_trace_dir config name in
  let entries =
    try Sys.readdir dir with
    | Sys_error _ -> [||]
  in
  let trace_files =
    entries
    |> Array.to_list
    |> List.filter (fun entry ->
      Filename.check_suffix entry raw_trace_file_extension)
    |> List.sort String.compare
  in
  let excess = List.length trace_files - raw_trace_retained_turn_files in
  if excess <= 0 then 0
  else begin
    let removed = ref 0 in
    List.iteri
      (fun idx entry ->
        if idx < excess then begin
          let path = Filename.concat dir entry in
          try
            Sys.remove path;
            incr removed
          with
          | Sys_error msg ->
            Log.Keeper.warn ~keeper_name:name
              "raw-trace retention: failed to remove %s: %s" path msg
        end)
      trace_files;
    !removed
  end

let keeper_memory_bank_path config name =
  Filename.concat (keeper_dir_ config) (name ^ ".memory.jsonl")

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
            let _renamed = Fs_compat.rename_if_exists ~src ~dst in
            ()
          done;
          let rotated = Printf.sprintf "%s.1" path in
          let _renamed = Fs_compat.rename_if_exists ~src:path ~dst:rotated in
          ()
        end

let append_jsonl_line path (json : Yojson.Safe.t) =
  maybe_rotate_file path;
  let line = utf8_repair_string (Yojson.Safe.to_string json) ^ "\n" in
  Fs_compat.append_file path line
