(* Grep operation setup:
    coreutils resolution, Otel_metric_store metric, history observation,
    and the shared process-result renderer.

    Extracted from the Grep dispatcher as part of godfile near-threshold split. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime

(* RFC-0084 host-config-cleanup-C — coreutils path migration.
   Resolve the 6 absolute binary paths once at module-init time
   from the typed [Host_config.coreutils] field, then reference
   the bound names at each shell-op call-site.  Behaviour byte-
   identical today; a future PR can flip [host]
   to PATH-resolved binaries for portability without touching
   this module's call sites. *)
let coreutils = (Host_config.host ()).coreutils

(* Domain-owned Otel_metric_store metric (RFC-0043 Phase 0): the metric name
   and registration live next to the bumper here rather than in the
   central otel_metric_store.ml registry, keeping that file under the
   godfile-size-regression cap. *)
let metric_bash_history_append_failures =
  "masc_bash_history_append_failures_total"

let () =
  Otel_metric_store.register_counter
    ~name:metric_bash_history_append_failures
    ~help:
      "Total bash-history audit append failures observed at \
       Grep setup. Bash_history.append returned Error (Sys_error \
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
      Otel_metric_store.inc_counter
        metric_bash_history_append_failures ();
      Log.KeeperExec.warn
        "bash_history.append failed: keeper=%s base=%s exn=%s"
        keeper_name root (Printexc.to_string exn)
;;

(* Shared process-result renderer used by both host and sandbox shell
   execution paths. Extracted from handle_tool_search_files so the
   closure capture (root, keeper_name, op) becomes explicit parameters. *)
let render_completed_process_result
      ~root ~keeper_name ~op
      ?cwd ~cmd ?(extra = []) st out =
  let elapsed_ms =
    List.find_map (fun (k, v) ->
      if k = "execution_time_ms" then
        match v with `Int n -> Some n | _ -> None
      else None) extra
    |> Option.value ~default:0
  in
  let entry = Masc_exec.Bash_history.{
    ts = Unix.time ();
    command = cmd;
    duration_ms = elapsed_ms;
    status = Masc_exec.Bash_history.process_status_of_unix st;
  } in
  observe_history_append ~root ~keeper_name entry;
  let extra_with_via =
    if List.exists (fun (k, _) -> k = "via") extra then extra
    else ("via", `String "host") :: extra
  in
  Yojson.Safe.to_string
    (Exec_core.process_result_json
       ~extra:([
           "op", `String op;
           "cmd", `String cmd;
           ( "cwd", Json_util.string_opt_to_json cwd );
         ] @ extra_with_via)
       ~status:st
       ~output:out
       ())
