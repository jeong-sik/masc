open Keeper_types
open Keeper_exec_shared

(* Emit a ("gh_exit_class", "…") JSON field when [cmd] targets gh.
   Callers append the returned list to their `Assoc payload
   unconditionally — it is empty for non-gh commands, so call sites
   keep their shape. *)
let gh_exit_class_field ~stages ~status ~output : (string * Yojson.Safe.t) list =
  if not (Keeper_shell_command_semantics.stages_targets_gh stages)
  then []
  else (
    let exit_code =
      match status with
      | Unix.WEXITED n -> n
      | Unix.WSIGNALED n -> 128 + n
      | Unix.WSTOPPED n -> 256 + n
    in
    (* Docker shell captures stdout+stderr combined into [output];
       Gh_exit_class rules match on substrings so passing the combined
       buffer as [stderr] is sound. *)
    let class_ = Gh_exit_class.classify ~exit_code ~stderr:output in
    [ "gh_exit_class", `String (Gh_exit_class.to_string class_) ])
;;

let docker_command_semantic_status ~cmd ~status ~output =
  Exec_core.semantic_status_of_process ~cmd ~output status

let semantic_ok_of_status = function
  | Exec_core.Ok | Exec_core.No_match -> true
  | Exec_core.Partial | Exec_core.Blocked | Exec_core.Timeout | Exec_core.Runtime_error ->
    false
