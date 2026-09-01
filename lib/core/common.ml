(* Local boolean-env helper for [masc_core]. It intentionally treats only
   1/true/yes/on as true and every other value as false; it does not mirror
   the richer [Env_config_core.get_bool] surface in [masc.config]. *)
let env_true name =
  match Sys.getenv_opt name with
  | None -> false
  | Some v ->
      let v = String.trim v |> String.lowercase_ascii in
      v = "1" || v = "true" || v = "yes" || v = "on"

let strict_finalizers () = env_true "MASC_STRICT_FINALIZERS"

let handle_finalizer_error ~module_name ~label ~during_exception ~backtrace ex =
  let suffix = if during_exception then " (during exception)" else "" in
  Log.Misc.error "%s %s failed in finalizer%s: %s"
    module_name label suffix (Printexc.to_string ex);
  if (not during_exception) && strict_finalizers () then
    Printexc.raise_with_backtrace ex backtrace

let protect ~module_name ~finally_label ~finally f =
  match f () with
  | v ->
      (try finally () with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | ex ->
           let bt = Printexc.get_raw_backtrace () in
           handle_finalizer_error ~module_name ~label:finally_label
             ~during_exception:false ~backtrace:bt ex);
      v
  | exception ex ->
      let bt = Printexc.get_raw_backtrace () in
      (try finally () with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | ex2 ->
           let bt2 = Printexc.get_raw_backtrace () in
           handle_finalizer_error ~module_name ~label:finally_label
             ~during_exception:true ~backtrace:bt2 ex2);
      Printexc.raise_with_backtrace ex bt

let masc_dirname = ".masc"

(* OUTPUT root segment for server-written keeper runtime state (meta json +
   metrics/memory/decisions/receipts sidecars). The SINGLE literal behind both
   keeper-dir SSOT functions; the input/output relocation (RFC) flips this one
   string (e.g. to "runtime/keepers"). *)
let keepers_runtime_dirname = "keepers"

let masc_dir_from_base_path ~base_path =
  Filename.concat base_path masc_dirname

(* Default-cluster keeper OUTPUT dir for callers holding only [base_path].
   Low-level on purpose: the cluster-aware [Workspace.keepers_runtime_dir]
   cannot be called from workspace-internal or accountability modules without a
   dependency cycle, so those route through here (matching their prior
   default-cluster behavior). *)
let keepers_runtime_dir_of_base ~base_path =
  Filename.concat (masc_dir_from_base_path ~base_path) keepers_runtime_dirname

type keeper_runtime_store =
  | Keeper_tool_usage
  | Keeper_runtime_manifests
  | Keeper_metrics
  | Keeper_execution_receipts
  | Keeper_turn_records
  | Keeper_provider_inputs
  | Keeper_reaction_ledger
  | Keeper_trajectories
  | Keeper_crash_events

let keeper_runtime_store_dirname = function
  | Keeper_tool_usage -> "tool_usage"
  | Keeper_runtime_manifests -> "runtime-manifests"
  | Keeper_metrics -> "metrics"
  | Keeper_execution_receipts -> "execution-receipts"
  | Keeper_turn_records -> "turn-records"
  | Keeper_provider_inputs -> "provider-inputs"
  | Keeper_reaction_ledger -> "reaction-ledger"
  | Keeper_trajectories -> "trajectories"
  | Keeper_crash_events -> "crash-events"

let keeper_runtime_stores =
  [ Keeper_tool_usage
  ; Keeper_runtime_manifests
  ; Keeper_metrics
  ; Keeper_execution_receipts
  ; Keeper_turn_records
  ; Keeper_provider_inputs
  ; Keeper_reaction_ledger
  ; Keeper_trajectories
  ; Keeper_crash_events
  ]

type keeper_runtime_store_placement =
  | Keeper_scoped_dated
  | Keeper_scoped_versioned
  | Keeper_scoped_rotated
  | Workspace_scoped

let keeper_runtime_store_placement = function
  | Keeper_metrics
  | Keeper_execution_receipts
  | Keeper_turn_records
  | Keeper_provider_inputs
  | Keeper_crash_events -> Keeper_scoped_dated
  | Keeper_reaction_ledger -> Keeper_scoped_versioned
  | Keeper_runtime_manifests -> Keeper_scoped_rotated
  | Keeper_tool_usage | Keeper_trajectories -> Workspace_scoped

let keeper_runtime_store_of_dirname name =
  List.find_opt
    (fun store -> String.equal name (keeper_runtime_store_dirname store))
    keeper_runtime_stores

let auth_dir_from_base_path ~base_path =
  Filename.concat (masc_dir_from_base_path ~base_path) "auth"

let agents_dir_from_base_path ~base_path =
  Filename.concat (auth_dir_from_base_path ~base_path) "agents"

(** Maximum output bytes for tool responses. SSOT for the 64KB cap.
    Inline-vs-blob threshold only; see [max_process_capture_*_bytes] for the
    separate ceiling on what the runtime accepts from a subprocess. *)
let max_tool_output_bytes = 65_536

(** Acceptance ceiling for one captured subprocess stream, split head/tail.

    Head is an [Exec_buffer] head buffer, which grows only as far as the
    output actually reaches, so a large head budget costs nothing on the
    common short-output call. Tail is a ring buffer allocated eagerly at
    [tail_cap], so it is sized to the 256KB already used per keeper by the
    dashboard retained-stream buffer rather than to the head budget.

    claude-code's comparable ceiling is 64 MiB, but it streams bash output to
    a file on disk; MASC retains the capture in memory for the turn, so the
    ceiling here is set lower. 8 MiB still leaves the blob store 128x the
    64KB inline budget for range reads. *)
let max_process_capture_head_bytes = 8 * 1024 * 1024

let max_process_capture_tail_bytes = 256 * 1024

(** BUG-016: Truncate large tool responses to prevent MCP transport overload.
    Default max: 64KB. Appends truncation metadata when trimmed. *)

(* One spelling of "this string is going into a path component". It lived in
   [Workspace_utils_ops], which sits above [masc_auth], so the auth layer built
   its credential paths by concatenating [agent_name] raw while the workspace
   layer sanitised the same value. Two answers for one question, and the
   unsanitised one was the layer holding tokens. *)
let safe_filename name =
  let buf = Buffer.create (String.length name * 3) in
  String.iter
    (fun c ->
      let c_lower = Char.lowercase_ascii c in
      let valid =
        (c_lower >= 'a' && c_lower <= 'z')
        || (c_lower >= '0' && c_lower <= '9')
        || c_lower = '.'
        || c_lower = '_'
        || c_lower = '-'
      in
      if valid then Buffer.add_char buf c_lower
      else Printf.bprintf buf "_%02x" (Char.code c))
    name;
  Buffer.contents buf
