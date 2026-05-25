(* keeper_shell_ops_setup — module-level setup for keeper_shell_ops:
    coreutils resolution, Prometheus metric, history observation,
    and the shared process-result renderer.

    Extracted from keeper_shell_ops.ml as part of godfile near-threshold split. *)

open Keeper_types
open Keeper_exec_shared

(* RFC-0084 host-config-cleanup-C — coreutils path migration.
   Resolve the 6 absolute binary paths once at module-init time
   from the typed [Host_config.coreutils] field, then reference
   the bound names at each shell-op call-site.  Behaviour byte-
   identical today; a future PR can flip [host]
   to PATH-resolved binaries for portability without touching
   this module's call sites. *)
let coreutils = (Host_config.host ()).coreutils

(* Domain-owned Prometheus metric (RFC-0043 Phase 0): the metric name
   and registration live next to the bumper here rather than in the
   central prometheus.ml registry, keeping that file under the
   godfile-size-regression cap. *)
let metric_bash_history_append_failures =
  "masc_bash_history_append_failures_total"

let () =
  Prometheus.register_counter
    ~name:metric_bash_history_append_failures
    ~help:
      "Total bash-history audit append failures observed at \
       keeper_shell_ops. Bash_history.append returned Error (Sys_error \
       from open/write/close). Decoupled from tool-call success/failure. \
       No labels."
    ()

(* Bash_history.append now returns [Result] (audit-trail write
   decoupled from tool-call semantics). Centralise the swallow +
   observe at both call sites — Sys_error from open/write/close no
   longer surfaces as a keeper tool failure, but increments
   masc_bash_history_append_failures_total and emits a WARN with
   keeper/path/exn for correlation. *)
let observe_history_append ~root ~keeper_name entry =
  match Masc_exec.Bash_history.append ~base_path:root ~keeper_name entry with
  | Ok () -> ()
  | Error exn ->
      Prometheus.inc_counter
        metric_bash_history_append_failures ();
      Log.KeeperExec.warn
        "bash_history.append failed: keeper=%s base=%s exn=%s"
        keeper_name root (Printexc.to_string exn)
;;

(* Shared process-result renderer used by both host and sandbox shell
   execution paths.  Extracted from handle_keeper_shell so the
   closure capture (root, keeper_name, op) becomes explicit parameters. *)
let render_completed_process_result
      ~root ~keeper_name ~op
      ?cwd ~cmd ?(extra = []) st out =
  let success = st = Unix.WEXITED 0 in
  let cmd_prefix = Keeper_shell_command_words.cmd_prefix cmd in
  let elapsed_ms =
    List.find_map (fun (k, v) ->
      if k = "execution_time_ms" then
        match v with `Int n -> Some n | _ -> None
      else None) extra
    |> Option.value ~default:0
  in
  let entry = Masc_exec.Bash_history.{
    ts = Unix.time ();
    cmd_hash = Masc_exec.Bash_history.cmd_hash cmd;
    cmd_prefix;
    semantic_kind = op;
    duration_ms = elapsed_ms;
    success;
  } in
  observe_history_append ~root ~keeper_name entry;
  let insight_extra =
    let patterns = Masc_exec.Bash_history.failure_insight
      ~base_path:root ~keeper_name
    in
    if patterns = [] then []
    else [
      "failure_insight", `List (
        List.map Masc_exec.Bash_history.failure_pattern_to_json patterns)
    ]
  in
  let extra_with_via =
    if List.exists (fun (k, _) -> k = "via") extra then extra
    else ("via", `String "host") :: extra
  in
  Yojson.Safe.to_string
    (Exec_core.process_result_json
       ~artifact_policy:Exec_core.Inline_only
       ~base_path:root
       ~keeper_name
       ~cmd
       ~extra:([
           "op", `String op;
           "cmd", `String cmd;
           ( "cwd",
             match cwd with
             | Some dir -> `String dir
             | None -> `Null );
         ] @ extra_with_via @ insight_extra)
       ~status:st
       ~output:out
       ())
