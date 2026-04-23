(** P13 — Exit code semantic interpretation.

    Pure module: maps [Unix.process_status] to human/LLM-readable
    meanings so agents can self-correct without blind retry loops.

    Signal numbers follow POSIX.  128+N convention covers cases
    where the shell reports signal death as an exit code. *)

type category =
  | Success
  | General_error
  | Usage_error
  | Data_error        (** missing file, format mismatch *)
  | Permission_error
  | Not_found
  | Timeout
  | Oom_killed
  | Segfault
  | Signal of int
  | Unknown of int

type t = {
  raw : Unix.process_status;
  code : int;
  category : category;
  label : string;
  hint : string;
}

(** POSIX signal names for the most common signals agents encounter. *)
let signal_name = function
  | 1  -> "SIGHUP"
  | 2  -> "SIGINT"
  | 3  -> "SIGQUIT"
  | 6  -> "SIGABRT"
  | 9  -> "SIGKILL"
  | 11 -> "SIGSEGV"
  | 13 -> "SIGPIPE"
  | 14 -> "SIGALRM"
  | 15 -> "SIGTERM"
  | 24 -> "SIGXFSZ"
  | n  -> Printf.sprintf "signal %d" n

let of_process_status = function
  | Unix.WEXITED 0 ->
    { raw = Unix.WEXITED 0; code = 0;
      category = Success;
      label = "success";
      hint = "" }
  | Unix.WEXITED 1 ->
    { raw = Unix.WEXITED 1; code = 1;
      category = General_error;
      label = "general_error";
      hint = "The command failed. Check stderr for details." }
  | Unix.WEXITED 2 ->
    { raw = Unix.WEXITED 2; code = 2;
      category = Usage_error;
      label = "usage_error";
      hint = "Wrong arguments or flags. Run the command with --help to see valid options." }
  | Unix.WEXITED 126 ->
    { raw = Unix.WEXITED 126; code = 126;
      category = Permission_error;
      label = "not_executable";
      hint = "Permission denied or not executable. Check file permissions with ls -la." }
  | Unix.WEXITED 127 ->
    { raw = Unix.WEXITED 127; code = 127;
      category = Not_found;
      label = "command_not_found";
      hint = "Command not found in PATH. Check spelling or install the required tool." }
  | Unix.WEXITED n when n = 124 ->
    { raw = Unix.WEXITED n; code = n;
      category = Timeout;
      label = "timeout";
      hint = "Command timed out. Try increasing timeout or simplifying the operation." }
  | Unix.WEXITED n when n >= 128 ->
    let signum = n - 128 in
    let cat = match signum with
      | 9 -> Oom_killed
      | 11 -> Segfault
      | _ -> Signal signum
    in
    let lab = match cat with
      | Oom_killed -> "oom_killed"
      | Segfault -> "segfault"
      | Signal s -> Printf.sprintf "killed_by_%s" (signal_name s)
      | _ -> "signal" (* unreachable for this branch *)
    in
    let hnt = match cat with
      | Oom_killed ->
        "Process was killed (likely OOM). Reduce data size or add memory."
      | Segfault ->
        "Segmentation fault. This is a bug in the tool — try a simpler invocation."
      | Signal s ->
        Printf.sprintf "Process received %s. May have been killed externally."
          (signal_name s)
      | _ -> ""
    in
    { raw = Unix.WEXITED n; code = n;
      category = cat; label = lab; hint = hnt }
  | Unix.WEXITED n ->
    { raw = Unix.WEXITED n; code = n;
      category = Unknown n;
      label = Printf.sprintf "exit_%d" n;
      hint = "Non-zero exit code. Check command output for details." }
  | Unix.WSIGNALED signum ->
    let cat = match signum with
      | 9 -> Oom_killed
      | 11 -> Segfault
      | _ -> Signal signum
    in
    let lab = match cat with
      | Oom_killed -> "oom_killed"
      | Segfault -> "segfault"
      | Signal s -> Printf.sprintf "killed_by_%s" (signal_name s)
      | _ -> "signal"
    in
    let hnt = match cat with
      | Oom_killed ->
        "Process was killed (likely OOM). Reduce data size or add memory."
      | Segfault ->
        "Segmentation fault. This is a bug in the tool — try a simpler invocation."
      | Signal s ->
        Printf.sprintf "Process received %s. May have been killed externally."
          (signal_name s)
      | _ -> ""
    in
    { raw = Unix.WSIGNALED signum;
      code = 128 + signum;
      category = cat; label = lab; hint = hnt }
  | Unix.WSTOPPED signum ->
    { raw = Unix.WSTOPPED signum;
      code = 128 + signum;
      category = Signal signum;
      label = Printf.sprintf "stopped_by_%s" (signal_name signum);
      hint = Printf.sprintf "Process was stopped by %s (job control)."
        (signal_name signum) }

let is_success t = t.category = Success

(** Serialize to a JSON-safe association list for inclusion in
    tool response payloads. *)
let to_assoc t =
  let base = [
    ("exit_code", `Int t.code);
    ("label", `String t.label);
  ] in
  let with_hint =
    if t.hint = "" then base
    else ("hint", `String t.hint) :: base
  in
  with_hint

let to_json t = `Assoc (to_assoc t)
