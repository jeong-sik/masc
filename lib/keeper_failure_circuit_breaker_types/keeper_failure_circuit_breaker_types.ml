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
module Path_rejection = Keeper_path_rejection

let classify_typed_path_check (error : Path_check_error.t) : error_class =
  match error with
  | Path_check_error.Cwd_not_directory _ -> Cwd_not_directory
  | Path_check_error.Path_outside_whitelist _ -> Path_not_allowed
;;

let classify_typed_path_rejection (error : Path_rejection.t) : error_class =
  match error with
  | Path_rejection.Not_found_relative _ -> Path_not_found
  | Path_rejection.Absolute_path_rejected _
  | Path_rejection.Outside_project_root _
  | Path_rejection.Outside_sandbox _
  | Path_rejection.Task_state_file_path_blocked _ -> Path_not_allowed
  | Path_rejection.Path_required
  | Path_rejection.Allowed_paths_normalized_empty _
  | Path_rejection.Ambiguous_relative_read_path _ -> Other
;;

let classify_path_check_prefix (error_msg : string) : error_class option =
  match Path_check_error.parse_prefix error_msg with
  | Some error -> Some (classify_typed_path_check error)
  | None -> None
;;

let classify_path_rejection_prefix (error_msg : string) : error_class option =
  match Path_rejection.parse_rejection_prefix error_msg with
  | Some error -> Some (classify_typed_path_rejection error)
  | None -> None
;;

let structured_error_text (error_msg : string) : string option =
  let json_text =
    let trimmed = String.trim error_msg in
    let strip_prefix prefix =
      let plen = String.length prefix in
      if String.length trimmed >= plen && String.sub trimmed 0 plen = prefix
      then Some (String.trim (String.sub trimmed plen (String.length trimmed - plen)))
      else None
    in
    match strip_prefix "error:" with
    | Some json -> json
    | None ->
      (match strip_prefix "tool_error:" with
       | Some json -> json
       | None -> trimmed)
  in
  match
    try Some (Yojson.Safe.from_string json_text) with
    | Yojson.Json_error _ -> None
  with
  | Some (`Assoc fields) ->
    (match List.assoc_opt "error" fields with
     | Some (`String error) -> Some error
     | _ ->
       (match List.assoc_opt "message" fields with
        | Some (`String message) -> Some message
        | _ -> None))
  | _ -> None
;;

let classify_path_error_text error_msg =
  match classify_path_check_prefix error_msg with
  | Some cls -> Some cls
  | None -> classify_path_rejection_prefix error_msg
;;

let classify_error (error_msg : string) : error_class =
  if String.length error_msg = 0 then Other
  else
    match classify_path_error_text error_msg with
    | Some cls -> cls
    | None ->
      (match structured_error_text error_msg with
       | Some error ->
         (match classify_path_error_text error with
          | Some cls -> cls
          | None ->
            if String_util.contains_substring error "No such file or directory"
            then Path_not_found
            else Other)
       | None ->
         let contains sub = String_util.contains_substring error_msg sub in
         if contains "No such file or directory" then Path_not_found
         else if contains "exit" && contains "code" then Shell_exit_nonzero
         else Other)

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
