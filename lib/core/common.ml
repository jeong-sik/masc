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

let auth_dir_from_base_path ~base_path =
  Filename.concat (masc_dir_from_base_path ~base_path) "auth"

let agents_dir_from_base_path ~base_path =
  Filename.concat (auth_dir_from_base_path ~base_path) "agents"

(** Maximum output bytes for tool responses. SSOT for the 64KB cap. *)
let max_tool_output_bytes = 65_536

(** BUG-016: Truncate large tool responses to prevent MCP transport overload.
    Default max: 64KB. Appends truncation metadata when trimmed. *)
let truncate_response ?(max_bytes=max_tool_output_bytes) ~total_count response =
  let len = String.length response in
  if len <= max_bytes then response
  else
    let truncated = String.sub response 0 max_bytes in
    Printf.sprintf "%s\n\n... [truncated: %d/%d bytes shown, total_count=%d]"
      truncated max_bytes len total_count
