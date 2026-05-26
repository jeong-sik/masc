(** Keeper_failure_circuit_breaker_types — error classification and
    breaker state types extracted from [Keeper_failure_circuit_breaker]
    (507 LoC).  Mutable state and core logic remain in the parent.
    @since Keeper 500-line decomposition *)

type error_class =
  | Path_not_found
  | Path_not_allowed
  | Cwd_not_directory
  | Shell_exit_nonzero
  | Other

module Path_check_error = Keeper_path_check_error

let classify_path_check_prefix (error_msg : string) : error_class option =
  match Path_check_error.parse_prefix error_msg with
  | Some (Path_check_error.Cwd_not_directory _) -> Some Cwd_not_directory
  | Some (Path_check_error.Path_outside_whitelist _) -> Some Path_not_allowed
  | None -> None
;;

let classify_error (error_msg : string) : error_class =
  if String.length error_msg = 0 then Other
  else
    match classify_path_check_prefix error_msg with
    | Some cls -> cls
    | None ->
      let contains sub = String_util.contains_substring error_msg sub in
      if contains "path_not_found" then Path_not_found
      else if contains "path_not_in_allowed" || contains "path_outside_sandbox" then Path_not_allowed
      else if contains "cwd_not_directory" then Cwd_not_directory
      else if contains "No such file or directory" then Path_not_found
      else if contains "exit" && contains "code" then Shell_exit_nonzero
      else Other

let error_class_to_string = function
  | Path_not_found -> "path_not_found"
  | Path_not_allowed -> "path_not_allowed"
  | Cwd_not_directory -> "cwd_not_directory"
  | Shell_exit_nonzero -> "shell_exit_nonzero"
  | Other -> "other"

(* ================================================================ *)
(* Per-keeper state                                                  *)
(* ================================================================ *)

(** A single failure signature captured for diagnostics.
    [fingerprint] is a single-line, size-bounded slice of the raw
    [error_msg] — enough for an operator to recognise the failure mode
    without dumping full payloads into logs. *)
type failure_signature = {
  ts : float;
  cls : error_class;
  fingerprint : string;
}

(** Bounded ring-buffer capacity for [recent_failures]. Matches
    [threshold] so a trip log can always name the three failures that
    caused it. Not exposed — an operator-visible knob would imply a
    policy change, which is out of scope for LT-16-KCB diagnostics. *)
let recent_failures_capacity = 3

type breaker_state = {
  mutable consecutive_class : error_class;
  mutable consecutive_count : int;
  mutable total_tripped : int;
  mutable last_tripped_at : float option;
  (* Newest-first; length bounded by [recent_failures_capacity].
     Retained across trips so "cooling" inspection still has context. *)
  mutable recent_failures : failure_signature list;
}

