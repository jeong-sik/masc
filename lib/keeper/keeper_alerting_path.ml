(** Keeper_alerting path safety and tool output helpers. *)

include Keeper_path_rejection

(** Operator-facing telemetry — single call site for all path-rejection
    counters.  The [kind] label is derived from the constructor name,
    eliminating hard-coded label strings scattered across the resolver. *)
let rejection_to_telemetry (r : keeper_path_rejection) : unit =
  let kind =
    match r with
    | Path_required -> "path_required"
    | Allowed_paths_normalized_empty _ -> "allowed_paths_normalized_empty"
    | Outside_sandbox _ -> "out_of_roots"
  in
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string PathRejection)
    ~labels:[ "kind", kind ]
    ()
;;

let project_root_of_config (config : Workspace.config) : string =
  let base = config.base_path in
  if Filename.basename base = Common.masc_dirname then Filename.dirname base else base
;;

let strip_trailing_slashes = Env_config_core.strip_trailing_slashes

let normalize_path_for_check (path : string) : string =
  try Fs_compat.realpath path with
  | Unix.Unix_error _ ->
    (* Walk up the directory tree until we find an ancestor that exists and
       can be resolved via realpath, then reconstruct the suffix.
       This handles symlinks (e.g., /tmp -> /private/tmp on macOS) even when
       intermediate directories do not exist on disk.
       Tail-recursive to avoid stack overflow on deep untrusted paths. *)
    let rec collect_suffix p acc =
      let parent = Filename.dirname p in
      if parent = p
      then
        (* Reached filesystem root without a successful realpath. *)
        p, acc
      else (
        match
          try Some (Fs_compat.realpath p) with
          | Unix.Unix_error _ -> None
        with
        | Some resolved -> resolved, acc
        | None -> collect_suffix parent (Filename.basename p :: acc))
    in
    let resolved_base, suffix_parts = collect_suffix path [] in
    List.fold_left Filename.concat resolved_base suffix_parts
;;

let normalize_path_for_check_stripped path =
  normalize_path_for_check path |> strip_trailing_slashes
;;

let normalize_allowed_path_for_check ~(root : string) (path : string) : string option =
  let raw = String.trim path in
  if raw = ""
  then None
  else (
    let candidate = if Filename.is_relative raw then Filename.concat root raw else raw in
    let normalized = normalize_path_for_check candidate |> strip_trailing_slashes in
    if normalized = "" then None else Some normalized)
;;

let is_within_root_norm ~(root_norm : string) (path : string) : bool =
  let normalized = normalize_path_for_check path |> strip_trailing_slashes in
  normalized = root_norm || String.starts_with ~prefix:(root_norm ^ "/") normalized
;;

let is_within_allowed_norms ~(target_norm : string) (allowed_norms : string list) : bool =
  List.exists
    (fun allowed_norm ->
       target_norm = allowed_norm || String.starts_with ~prefix:(allowed_norm ^ "/") target_norm)
    allowed_norms
;;

let absolute_allowed_paths ~(config : Workspace.config) ~(allowed_paths : string list)
  : string list
  =
  let root = project_root_of_config config in
  allowed_paths |> List.filter_map (normalize_allowed_path_for_check ~root)
;;

let absolute_allowed_paths_result ~(config : Workspace.config) ~(allowed_paths : string list)
  : (string list, string) result
  =
  let normalized = absolute_allowed_paths ~config ~allowed_paths in
  if allowed_paths <> [] && normalized = []
  then
    (* Tier A3 / Cycle 6: redact the raw [allowed_paths] list — those
       strings frequently include host-absolute prefixes that should
       not flow back to the LLM caller. The count is enough for the
       caller to know "you provided N entries, none were valid". *)
    Error
      (Printf.sprintf
         "allowed_paths_normalized_empty: %d entries provided, none resolved to a valid \
          path"
         (List.length allowed_paths))
  else Ok normalized
;;

(* Build a sandbox boundary error message that teaches the LLM
   *why* the path was rejected — not just *that* it was. Bare "X not allowed"
   triggers retry loops; including the resolved candidate plus the
   sandbox boundary rule lets the keeper correct on the next call without
   re-trying the same broken interpretation. See
   [memory/feedback_tool-error-messages-teach-llm.md]. *)

let resolve_keeper_path_within_allowed_roots
      ~(config : Workspace.config)
      ~(allowed_paths : string list)
      ~(raw_path : string)
  : (string, keeper_path_rejection) result
  =
  let raw = String.trim raw_path in
  if raw = ""
  then Error Path_required
  else (
    let root = project_root_of_config config in
    let candidate = if Filename.is_relative raw then Filename.concat root raw else raw in
    let target_norm = normalize_path_for_check_stripped candidate in
    let root_norm = normalize_path_for_check_stripped root in
    let allowed_norms =
      if allowed_paths = []
      then [ root_norm ]
      else
        List.filter_map
          (normalize_allowed_path_for_check ~root)
          allowed_paths
    in
    if allowed_norms = []
    then Error (Allowed_paths_normalized_empty { count = List.length allowed_paths })
    else if is_within_allowed_norms ~target_norm allowed_norms
    then Ok candidate
    else Error (Outside_sandbox { raw }))
;;

let resolve_keeper_target_path = resolve_keeper_path_within_allowed_roots

(* Playground path SSOT lives in [Playground_paths] (masc_config). These
   names preserve the historical keeper-facing API. Do not re-implement
   the literal ".masc/playground" layout here — edit [Playground_paths]
   if it ever changes. *)
let sanitize_keeper_name = Playground_paths.sanitize_keeper_name
let playground_path_of_keeper = Playground_paths.bundle_root
let playground_mind_path = Playground_paths.mind_path
let playground_repos_path = Playground_paths.repos_path
let playground_bundle_paths = Playground_paths.bundle_paths

let sandbox_path_of_meta ~(meta : Keeper_meta_contract.keeper_meta) =
  Keeper_sandbox.allowed_root_rel_of_meta ~meta
;;

let sandbox_bundle_paths_of_meta ~(meta : Keeper_meta_contract.keeper_meta) =
  let root = sandbox_path_of_meta ~meta |> strip_trailing_slashes in
  [ root ^ "/"; root ^ "/mind/"; root ^ "/repos/" ]
;;

let ensure_playground_bundle ~(config : Workspace.config) ~(name : string) : string list =
  let root = project_root_of_config config in
  playground_bundle_paths name
  |> List.map (Filename.concat root)
  |> List.map Keeper_fs.ensure_dir
;;

let ensure_sandbox_bundle ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta)
  : string list
  =
  let root = project_root_of_config config in
  sandbox_bundle_paths_of_meta ~meta
  |> List.map (Filename.concat root)
  |> List.map Keeper_fs.ensure_dir
;;

let ensure_sandbox_bundle_for_profile
      ~(config : Workspace.config)
      ~(name : string)
      ~(sandbox_profile : Keeper_types_profile_sandbox.sandbox_profile)
  : string list
  =
  let root = project_root_of_config config in
  let sandbox_root =
    Keeper_sandbox.host_root_rel_of_profile sandbox_profile name |> strip_trailing_slashes
  in
  [ sandbox_root ^ "/"; sandbox_root ^ "/mind/"; sandbox_root ^ "/repos/" ]
  |> List.map (Filename.concat root)
  |> List.map Keeper_fs.ensure_dir
;;

(** Compute effective read allowed_paths from keeper meta.
    Returns the single sandbox root plus any explicit [allowed_paths]
    entries. Every additional path must be listed explicitly in
    [allowed_paths]. *)
let effective_allowed_paths ~(meta : Keeper_meta_contract.keeper_meta) : string list =
  let sandbox_paths = Keeper_sandbox.allowed_path_roots_of_meta ~meta in
  sandbox_paths @ meta.allowed_paths
;;

(** Compute effective write allowed_paths from keeper meta.
    Returns the single sandbox root plus any explicit [allowed_paths]
    entries. Every additional path must be listed explicitly in
    [allowed_paths]. *)
let effective_write_allowed_paths ~(meta : Keeper_meta_contract.keeper_meta) : string list =
  let sandbox_paths = Keeper_sandbox.allowed_path_roots_of_meta ~meta in
  sandbox_paths @ meta.allowed_paths
;;

(** Resolve a path for read-only access within the keeper's effective
    allowlist. The allowlist is usually the keeper sandbox root
    plus any explicit custom paths. *)
let resolve_keeper_read_path
      ~(config : Workspace.config)
      ~(allowed_paths : string list)
      ~(raw_path : string)
  : (string, keeper_path_rejection) result
  =
  resolve_keeper_path_within_allowed_roots ~config ~allowed_paths ~raw_path
;;

let process_status_to_json (st : Unix.process_status) : Yojson.Safe.t =
  Exec_core.process_status_to_json st
;;

let extract_user_messages (ctx_work : Keeper_types.working_context) : string list =
  Keeper_context_runtime.messages_of_context ctx_work
  |> List.filter_map (fun (m : Agent_sdk.Types.message) ->
    if m.role = Agent_sdk.Types.User
    then (
      let c = String.trim (Agent_sdk.Types.text_of_message m) in
      if c = "" then None else Some c)
    else None)
;;
