(* RFC-0042 PR-5 / SSOT-1: typed SSOT for "why a keeper is latched".

   Wire form is informational only and is parsed by [of_wire] into a
   closed sum; never used as a classifier by consumers in this repo.

   Equality and hashing are typed ([equal] / [hash]); the wire string is
   a derived view, never the source of truth. *)

type contract_violation_detail =
  { reason_code :
      [ `No_tool_use_block
      | `No_keeper_tool_returned
      | `Repeated_text_only_response
      | `Unspecified
      ]
  ; raw_error_summary : string
  }

type runtime_exhaustion_reason =
  | All_providers_failed
  | No_providers_available
  | Structural_attempt_timeout of { stage : string }
  | Unspecified_runtime

type turn_budget_detail =
  { dimension :
      [ `Turns
      | `Wall_clock_seconds
      | `Idle_turns
      ]
  ; source :
      [ `Oas_sdk
      | `Keeper_runtime
      | `User_config
      ]
  }

type turn_budget_exhausted =
  { detail : turn_budget_detail
  ; used : int
  ; limit : int
  }

type operator_actor =
  | Grpc_directive
  | Keeper_down

type t =
  | No_progress_loop of
      { consecutive_idle_cycles : int
      ; detector_kind :
          [ `Consecutive_idle_turns
          | `Consecutive_no_progress
          | `Both
          ]
      }
  | Completion_contract_violation of contract_violation_detail
  | Idle_detected of { consecutive_idle_turns : int }
  | Runtime_exhausted of runtime_exhaustion_reason
  | Turn_budget_exhausted of turn_budget_exhausted
  | Stale_storm
  | Provider_timeout_loop of { consecutive_timeouts : int }
  | Operator_paused of { operator_actor : operator_actor }
  | Dead_tombstone

(* -------------------------------------------------------------------- *)
(* Polymorphic-variant equality helpers (closed set; new variants are a  *)
(* compile-time change).                                                  *)
(* -------------------------------------------------------------------- *)

let poly_equal a b =
  match (a, b) with
  | `Turns, `Turns -> true
  | `Wall_clock_seconds, `Wall_clock_seconds -> true
  | `Idle_turns, `Idle_turns -> true
  | `Turns, _ | `Wall_clock_seconds, _ | `Idle_turns, _ -> false
;;

let poly_equal_source a b =
  match (a, b) with
  | `Oas_sdk, `Oas_sdk -> true
  | `Keeper_runtime, `Keeper_runtime -> true
  | `User_config, `User_config -> true
  | `Oas_sdk, _ | `Keeper_runtime, _ | `User_config, _ -> false
;;

let poly_equal_reason_code a b =
  match (a, b) with
  | `No_tool_use_block, `No_tool_use_block -> true
  | `No_keeper_tool_returned, `No_keeper_tool_returned -> true
  | `Repeated_text_only_response, `Repeated_text_only_response -> true
  | `Unspecified, `Unspecified -> true
  | (`No_tool_use_block | `No_keeper_tool_returned | `Repeated_text_only_response | `Unspecified), _
    ->
    false
;;

let poly_equal_detector a b =
  match (a, b) with
  | `Consecutive_idle_turns, `Consecutive_idle_turns -> true
  | `Consecutive_no_progress, `Consecutive_no_progress -> true
  | `Both, `Both -> true
  | (`Consecutive_idle_turns | `Consecutive_no_progress | `Both), _ -> false
;;

(* -------------------------------------------------------------------- *)
(* Equal / hash                                                          *)
(* -------------------------------------------------------------------- *)

let equal a b =
  match (a, b) with
  | ( No_progress_loop { consecutive_idle_cycles = c1; detector_kind = d1 }
    , No_progress_loop { consecutive_idle_cycles = c2; detector_kind = d2 } ) ->
    Int.equal c1 c2 && poly_equal_detector d1 d2
  | Completion_contract_violation d1, Completion_contract_violation d2 ->
    poly_equal_reason_code d1.reason_code d2.reason_code
    && String.equal d1.raw_error_summary d2.raw_error_summary
  | Idle_detected { consecutive_idle_turns = i1 }, Idle_detected { consecutive_idle_turns = i2 } ->
    Int.equal i1 i2
  | Runtime_exhausted r1, Runtime_exhausted r2 ->
    (match (r1, r2) with
     | All_providers_failed, All_providers_failed -> true
     | No_providers_available, No_providers_available -> true
     | Structural_attempt_timeout { stage = s1 }, Structural_attempt_timeout { stage = s2 } ->
       String.equal s1 s2
     | Unspecified_runtime, Unspecified_runtime -> true
     | ( All_providers_failed | No_providers_available | Structural_attempt_timeout _
       | Unspecified_runtime )
     , _ ->
       false)
  | ( Turn_budget_exhausted
        { detail = { dimension = d1; source = s1 }; used = u1; limit = l1 }
    , Turn_budget_exhausted
        { detail = { dimension = d2; source = s2 }; used = u2; limit = l2 } ) ->
    poly_equal d1 d2 && Int.equal u1 u2 && Int.equal l1 l2 && poly_equal_source s1 s2
  | Stale_storm, Stale_storm -> true
  | ( Provider_timeout_loop { consecutive_timeouts = c1 }
    , Provider_timeout_loop { consecutive_timeouts = c2 } ) ->
    Int.equal c1 c2
  | Operator_paused { operator_actor = a1 }, Operator_paused { operator_actor = a2 } ->
    (match (a1, a2) with
     | Grpc_directive, Grpc_directive -> true
     | Keeper_down, Keeper_down -> true
     | (Grpc_directive | Keeper_down), _ -> false)
  | Dead_tombstone, Dead_tombstone -> true
  | ( ( No_progress_loop _
      | Completion_contract_violation _
      | Idle_detected _
      | Runtime_exhausted _
      | Turn_budget_exhausted _
      | Stale_storm
      | Provider_timeout_loop _
      | Operator_paused _
      | Dead_tombstone )
    , _ ) ->
    false
;;

(* Closed sum: pattern-match every variant, no [hash] reuse from
   external libraries. Hash by [Hashtbl.hash] of structural fields. *)
let hash = function
  | No_progress_loop { consecutive_idle_cycles; detector_kind } ->
    Hashtbl.hash
      ( 0
      , consecutive_idle_cycles
      , (match detector_kind with
         | `Consecutive_idle_turns -> 0
         | `Consecutive_no_progress -> 1
         | `Both -> 2) )
  | Completion_contract_violation d ->
    Hashtbl.hash
      ( 1
      , (match d.reason_code with
         | `No_tool_use_block -> 0
         | `No_keeper_tool_returned -> 1
         | `Repeated_text_only_response -> 2
         | `Unspecified -> 3)
      , d.raw_error_summary )
  | Idle_detected { consecutive_idle_turns } -> Hashtbl.hash (2, consecutive_idle_turns)
  | Runtime_exhausted r ->
    Hashtbl.hash
      ( 3
      , (match r with
         | All_providers_failed -> 0
         | No_providers_available -> 1
         | Structural_attempt_timeout { stage } -> Hashtbl.hash (2, stage)
         | Unspecified_runtime -> 3) )
  | Turn_budget_exhausted { detail; used; limit } ->
    Hashtbl.hash
      ( 4
      , (match detail.dimension with `Turns -> 0 | `Wall_clock_seconds -> 1 | `Idle_turns -> 2)
      , used
      , limit
      , (match detail.source with `Oas_sdk -> 0 | `Keeper_runtime -> 1 | `User_config -> 2) )
  | Stale_storm -> 5
  | Provider_timeout_loop { consecutive_timeouts } -> Hashtbl.hash (6, consecutive_timeouts)
  | Operator_paused { operator_actor } ->
    Hashtbl.hash
      ( 7
      , match operator_actor with
        | Grpc_directive -> 0
        | Keeper_down -> 1 )
  | Dead_tombstone -> 8
;;

(* -------------------------------------------------------------------- *)
(* pp                                                                    *)
(* -------------------------------------------------------------------- *)

let pp_dim = function
  | `Turns -> "turns"
  | `Wall_clock_seconds -> "wall_clock_seconds"
  | `Idle_turns -> "idle_turns"
;;

let pp_source = function
  | `Oas_sdk -> "oas_sdk"
  | `Keeper_runtime -> "keeper_runtime"
  | `User_config -> "user_config"
;;

let pp_reason_code = function
  | `No_tool_use_block -> "no_tool_use_block"
  | `No_keeper_tool_returned -> "no_keeper_tool_returned"
  | `Repeated_text_only_response -> "repeated_text_only_response"
  | `Unspecified -> "unspecified"
;;

let pp_detector = function
  | `Consecutive_idle_turns -> "consecutive_idle_turns"
  | `Consecutive_no_progress -> "consecutive_no_progress"
  | `Both -> "both"
;;

let pp_runtime_exhaustion ppf = function
  | All_providers_failed -> Format.fprintf ppf "all_providers_failed"
  | No_providers_available -> Format.fprintf ppf "no_providers_available"
  | Structural_attempt_timeout { stage } ->
    Format.fprintf ppf "structural_attempt_timeout{stage=%s}" stage
  | Unspecified_runtime -> Format.fprintf ppf "unspecified_runtime"
;;

(* -------------------------------------------------------------------- *)
(* Well-known operator actors                                           *)
(* -------------------------------------------------------------------- *)

let operator_actor_grpc_directive = Grpc_directive
let operator_actor_keeper_down = Keeper_down

let operator_actor_to_wire = function
  | Grpc_directive -> "grpc_directive"
  | Keeper_down -> "keeper_down"

let operator_actor_of_wire = function
  | "grpc_directive" -> Ok Grpc_directive
  | "keeper_down" -> Ok Keeper_down
  | other -> Error (Printf.sprintf "Keeper_latched_reason: unknown operator actor %S" other)

(* -------------------------------------------------------------------- *)
(* pp                                                                    *)
(* -------------------------------------------------------------------- *)

let pp ppf = function
  | No_progress_loop { consecutive_idle_cycles; detector_kind } ->
    Format.fprintf
      ppf
      "No_progress_loop{cycles=%d,detector=%s}"
      consecutive_idle_cycles
      (pp_detector detector_kind)
  | Completion_contract_violation { reason_code; raw_error_summary } ->
    Format.fprintf
      ppf
      "Completion_contract_violation{code=%s,summary=%S}"
      (pp_reason_code reason_code)
      raw_error_summary
  | Idle_detected { consecutive_idle_turns } ->
    Format.fprintf ppf "Idle_detected{idle_turns=%d}" consecutive_idle_turns
  | Runtime_exhausted r ->
    Format.fprintf ppf "Runtime_exhausted{";
    pp_runtime_exhaustion ppf r;
    Format.fprintf ppf "}"
  | Turn_budget_exhausted { detail; used; limit } ->
    Format.fprintf
      ppf
      "Turn_budget_exhausted{dim=%s,used=%d,limit=%d,source=%s}"
      (pp_dim detail.dimension)
      used
      limit
      (pp_source detail.source)
  | Stale_storm -> Format.fprintf ppf "Stale_storm"
  | Provider_timeout_loop { consecutive_timeouts } ->
    Format.fprintf ppf "Provider_timeout_loop{count=%d}" consecutive_timeouts
  | Operator_paused { operator_actor } ->
    Format.fprintf ppf "Operator_paused{actor=%s}" (operator_actor_to_wire operator_actor)
  | Dead_tombstone -> Format.fprintf ppf "Dead_tombstone"
;;

(* -------------------------------------------------------------------- *)
(* Wire format                                                           *)
(* -------------------------------------------------------------------- *)

(* Stdlib Result helpers (kept local so the module has no external
   dependency on a project-specific [R] module). *)
let ( let* ) = Result.bind
let ( let+ ) result f = Result.map f result

let errorf fmt = Printf.ksprintf (fun msg -> Error msg) fmt

let chop_prefix ~prefix value =
  let prefix_len = String.length prefix in
  let value_len = String.length value in
  if value_len >= prefix_len && String.sub value 0 prefix_len = prefix
  then Some (String.sub value prefix_len (value_len - prefix_len))
  else None
;;

let chop_suffix ~suffix value =
  let suffix_len = String.length suffix in
  let value_len = String.length value in
  if value_len >= suffix_len
     && String.sub value (value_len - suffix_len) suffix_len = suffix
  then Some (String.sub value 0 (value_len - suffix_len))
  else None
;;

let int_of_string_exn s =
  match int_of_string s with
  | n -> Ok n
  | exception Failure _ -> Error (Printf.sprintf "int_of_string: %S" s)
;;

let to_wire = function
  | No_progress_loop { consecutive_idle_cycles; detector_kind } ->
    Printf.sprintf "no_progress_loop:cycles=%d:detector=%s" consecutive_idle_cycles (pp_detector detector_kind)
  | Completion_contract_violation { reason_code; raw_error_summary } ->
    Printf.sprintf "completion_contract_violation:code=%s:summary=%S" (pp_reason_code reason_code) raw_error_summary
  | Idle_detected { consecutive_idle_turns } ->
    Printf.sprintf "idle_detected:idle_turns=%d" consecutive_idle_turns
  | Runtime_exhausted r ->
    Format.asprintf "runtime_exhausted:%a" pp_runtime_exhaustion r
  | Turn_budget_exhausted { detail; used; limit } ->
    Printf.sprintf
      "turn_budget_exhausted:dim=%s:used=%d:limit=%d:source=%s"
      (pp_dim detail.dimension)
      used
      limit
      (pp_source detail.source)
  | Stale_storm -> "stale_storm"
  | Provider_timeout_loop { consecutive_timeouts } ->
    Printf.sprintf "provider_timeout_loop:count=%d" consecutive_timeouts
  | Operator_paused { operator_actor } ->
    Printf.sprintf "operator_paused:actor=%s" (operator_actor_to_wire operator_actor)
  | Dead_tombstone -> "dead_tombstone"
;;

(* Fail-closed parser. The wire form is append-only information; any
   unknown shape yields [Error] rather than a permissive catch-all
   ([Keeper_terminal_reason.t] uses prefix matching for legacy wire
   compatibility — that layer is intentionally permissive; this layer
   is intentionally strict). *)
let of_wire wire =
  let parse_dim = function
    | "turns" -> Ok `Turns
    | "wall_clock_seconds" -> Ok `Wall_clock_seconds
    | "idle_turns" -> Ok `Idle_turns
    | other -> errorf "Keeper_latched_reason.of_wire: unknown dimension %S" other
  in
  let parse_source = function
    | "oas_sdk" -> Ok `Oas_sdk
    | "keeper_runtime" -> Ok `Keeper_runtime
    | "user_config" -> Ok `User_config
    | other -> errorf "Keeper_latched_reason.of_wire: unknown source %S" other
  in
  let parse_detector = function
    | "consecutive_idle_turns" -> Ok `Consecutive_idle_turns
    | "consecutive_no_progress" -> Ok `Consecutive_no_progress
    | "both" -> Ok `Both
    | other -> errorf "Keeper_latched_reason.of_wire: unknown detector %S" other
  in
  let parse_reason_code = function
    | "no_tool_use_block" -> Ok `No_tool_use_block
    | "no_keeper_tool_returned" -> Ok `No_keeper_tool_returned
    | "repeated_text_only_response" -> Ok `Repeated_text_only_response
    | "unspecified" -> Ok `Unspecified
    | other -> errorf "Keeper_latched_reason.of_wire: unknown reason_code %S" other
  in
  let parse_field name field =
    match chop_prefix ~prefix:(name ^ "=") field with
    | Some value -> Ok value
    | None -> errorf "Keeper_latched_reason.of_wire: expected %s= field, got %S" name field
  in
  let parse_string_literal s =
    let len = String.length s in
    if len >= 2 && Char.equal s.[0] '"' && Char.equal s.[len - 1] '"'
    then (
      let body = String.sub s 1 (len - 2) in
      match Scanf.unescaped body with
      | decoded -> Ok decoded
      | exception Scanf.Scan_failure msg ->
        errorf "Keeper_latched_reason.of_wire: malformed quoted summary %S: %s" s msg
      | exception Failure msg ->
        errorf "Keeper_latched_reason.of_wire: malformed quoted summary %S: %s" s msg
      | exception Invalid_argument msg ->
        errorf "Keeper_latched_reason.of_wire: malformed quoted summary %S: %s" s msg)
    else errorf "Keeper_latched_reason.of_wire: summary must be quoted, got %S" s
  in
  match String.split_on_char ':' wire with
  | [ "no_progress_loop"; cycles_field; detector_field ] ->
    let* cycles_str = parse_field "cycles" cycles_field in
    let* detector_str = parse_field "detector" detector_field in
    let* cycles = int_of_string_exn cycles_str in
    let+ detector = parse_detector detector_str in
    No_progress_loop { consecutive_idle_cycles = cycles; detector_kind = detector }
  | "completion_contract_violation" :: _ ->
    let prefix = "completion_contract_violation:code=" in
    let* rest =
      match chop_prefix ~prefix wire with
      | Some rest -> Ok rest
      | None ->
        errorf "Keeper_latched_reason.of_wire: malformed completion contract wire %S" wire
    in
    let* code, summary_wire =
      match String.index_opt rest ':' with
      | Some idx ->
        let code = String.sub rest 0 idx in
        let summary_wire =
          String.sub rest (idx + 1) (String.length rest - idx - 1)
        in
        Ok (code, summary_wire)
      | None ->
        errorf "Keeper_latched_reason.of_wire: missing completion summary in %S" wire
    in
    let* reason_code = parse_reason_code code in
    let* summary_encoded = parse_field "summary" summary_wire in
    let+ summary = parse_string_literal summary_encoded in
    Completion_contract_violation
      { reason_code; raw_error_summary = summary }
  | [ "idle_detected"; idle_field ] ->
    let* idle_str = parse_field "idle_turns" idle_field in
    let+ idle_turns = int_of_string_exn idle_str in
    Idle_detected { consecutive_idle_turns = idle_turns }
  | [ "runtime_exhausted"; "all_providers_failed" ] ->
    Ok (Runtime_exhausted All_providers_failed)
  | [ "runtime_exhausted"; "no_providers_available" ] ->
    Ok (Runtime_exhausted No_providers_available)
  | [ "runtime_exhausted"; "unspecified_runtime" ] ->
    Ok (Runtime_exhausted Unspecified_runtime)
  | [ "runtime_exhausted"; detail ] ->
    let prefix = "structural_attempt_timeout{stage=" in
    (match chop_prefix ~prefix detail with
     | Some tail ->
       (match chop_suffix ~suffix:"}" tail with
        | Some stage -> Ok (Runtime_exhausted (Structural_attempt_timeout { stage }))
        | None ->
          errorf "Keeper_latched_reason.of_wire: malformed runtime detail %S" detail)
     | None ->
       errorf "Keeper_latched_reason.of_wire: unknown runtime detail %S" detail)
  | [ "turn_budget_exhausted"; dim_field; used_field; limit_field; source_field ] ->
    let* dim_str = parse_field "dim" dim_field in
    let* used_str = parse_field "used" used_field in
    let* limit_str = parse_field "limit" limit_field in
    let* source_str = parse_field "source" source_field in
    let* dimension = parse_dim dim_str in
    let* used = int_of_string_exn used_str in
    let* limit = int_of_string_exn limit_str in
    let+ source = parse_source source_str in
    Turn_budget_exhausted { detail = { dimension; source }; used; limit }
  | [ "stale_storm" ] -> Ok Stale_storm
  | [ "dead_tombstone" ] -> Ok Dead_tombstone
  | [ "provider_timeout_loop"; count_field ] ->
    let* count_str = parse_field "count" count_field in
    let+ consecutive_timeouts = int_of_string_exn count_str in
    Provider_timeout_loop { consecutive_timeouts }
  | "operator_paused" :: _ ->
    let prefix = "operator_paused:actor=" in
    (match chop_prefix ~prefix wire with
     | Some actor_wire ->
       let+ operator_actor = operator_actor_of_wire actor_wire in
       Operator_paused { operator_actor }
     | None -> errorf "Keeper_latched_reason.of_wire: malformed operator pause wire %S" wire)
  | _ ->
    errorf "Keeper_latched_reason.of_wire: unknown wire form %S" wire
;;

(* -------------------------------------------------------------------- *)
(* Yojson round-trip                                                     *)
(* -------------------------------------------------------------------- *)

module Stable = struct
  let string_of_dim = function
    | `Turns -> "turns"
    | `Wall_clock_seconds -> "wall_clock_seconds"
    | `Idle_turns -> "idle_turns"
  ;;

  let dim_of_string s =
    match s with
    | "turns" -> Ok `Turns
    | "wall_clock_seconds" -> Ok `Wall_clock_seconds
    | "idle_turns" -> Ok `Idle_turns
    | _ -> Error (Printf.sprintf "Keeper_latched_reason: unknown dimension %S" s)
  ;;

  let string_of_source = function
    | `Oas_sdk -> "oas_sdk"
    | `Keeper_runtime -> "keeper_runtime"
    | `User_config -> "user_config"
  ;;

  let source_of_string s =
    match s with
    | "oas_sdk" -> Ok `Oas_sdk
    | "keeper_runtime" -> Ok `Keeper_runtime
    | "user_config" -> Ok `User_config
    | _ -> Error (Printf.sprintf "Keeper_latched_reason: unknown source %S" s)
  ;;

  let string_of_reason_code = function
    | `No_tool_use_block -> "no_tool_use_block"
    | `No_keeper_tool_returned -> "no_keeper_tool_returned"
    | `Repeated_text_only_response -> "repeated_text_only_response"
    | `Unspecified -> "unspecified"
  ;;

  let reason_code_of_string s =
    match s with
    | "no_tool_use_block" -> Ok `No_tool_use_block
    | "no_keeper_tool_returned" -> Ok `No_keeper_tool_returned
    | "repeated_text_only_response" -> Ok `Repeated_text_only_response
    | "unspecified" -> Ok `Unspecified
    | _ -> Error (Printf.sprintf "Keeper_latched_reason: unknown reason_code %S" s)
  ;;

  let string_of_detector = function
    | `Consecutive_idle_turns -> "consecutive_idle_turns"
    | `Consecutive_no_progress -> "consecutive_no_progress"
    | `Both -> "both"
  ;;

  let detector_of_string s =
    match s with
    | "consecutive_idle_turns" -> Ok `Consecutive_idle_turns
    | "consecutive_no_progress" -> Ok `Consecutive_no_progress
    | "both" -> Ok `Both
    | _ -> Error (Printf.sprintf "Keeper_latched_reason: unknown detector %S" s)
  ;;

  let runtime_to_yojson r : Yojson.Safe.t =
    match r with
    | All_providers_failed -> `Assoc [ "kind", `String "all_providers_failed" ]
    | No_providers_available -> `Assoc [ "kind", `String "no_providers_available" ]
    | Structural_attempt_timeout { stage } ->
      `Assoc [ "kind", `String "structural_attempt_timeout"; "stage", `String stage ]
    | Unspecified_runtime -> `Assoc [ "kind", `String "unspecified_runtime" ]
  ;;

  let runtime_of_yojson (j : Yojson.Safe.t) =
    match j with
    | `Assoc [ "kind", `String "all_providers_failed" ] -> Ok (All_providers_failed)
    | `Assoc [ "kind", `String "no_providers_available" ] -> Ok No_providers_available
    | `Assoc [ "kind", `String "structural_attempt_timeout"; "stage", `String stage ] ->
      Ok (Structural_attempt_timeout { stage })
    | `Assoc [ "kind", `String "unspecified_runtime" ] -> Ok Unspecified_runtime
    | _ ->
      Error (Printf.sprintf "Keeper_latched_reason: unknown runtime_exhaustion shape: %s"
               (Yojson.Safe.to_string j))
  ;;

  let to_yojson t : Yojson.Safe.t =
    match t with
    | No_progress_loop { consecutive_idle_cycles; detector_kind } ->
      `Assoc
        [ "kind", `String "no_progress_loop"
        ; "consecutive_idle_cycles", `Int consecutive_idle_cycles
        ; "detector_kind", `String (string_of_detector detector_kind)
        ]
    | Completion_contract_violation { reason_code; raw_error_summary } ->
      `Assoc
        [ "kind", `String "completion_contract_violation"
        ; "reason_code", `String (string_of_reason_code reason_code)
        ; "raw_error_summary", `String raw_error_summary
        ]
    | Idle_detected { consecutive_idle_turns } ->
      `Assoc
        [ "kind", `String "idle_detected"
        ; "consecutive_idle_turns", `Int consecutive_idle_turns
        ]
    | Runtime_exhausted r -> `Assoc [ "kind", `String "runtime_exhausted"; "detail", runtime_to_yojson r ]
    | Turn_budget_exhausted { detail; used; limit } ->
      `Assoc
        [ "kind", `String "turn_budget_exhausted"
        ; "dimension", `String (string_of_dim detail.dimension)
        ; "used", `Int used
        ; "limit", `Int limit
        ; "source", `String (string_of_source detail.source)
        ]
    | Stale_storm -> `Assoc [ "kind", `String "stale_storm" ]
    | Provider_timeout_loop { consecutive_timeouts } ->
      `Assoc
        [ "kind", `String "provider_timeout_loop"
        ; "consecutive_timeouts", `Int consecutive_timeouts
        ]
    | Operator_paused { operator_actor } ->
      `Assoc
        [ "kind", `String "operator_paused"
        ; "actor", `String (operator_actor_to_wire operator_actor)
        ]
    | Dead_tombstone -> `Assoc [ "kind", `String "dead_tombstone" ]
  ;;

  let of_yojson (j : Yojson.Safe.t) =
    match j with
    | `Assoc [ "kind", `String "no_progress_loop"
             ; "consecutive_idle_cycles", `Int n
             ; "detector_kind", `String d ] ->
      let+ detector = detector_of_string d in
      No_progress_loop { consecutive_idle_cycles = n; detector_kind = detector }
    | `Assoc [ "kind", `String "completion_contract_violation"
             ; "reason_code", `String c
             ; "raw_error_summary", `String summary ] ->
      let+ rc = reason_code_of_string c in
      Completion_contract_violation { reason_code = rc; raw_error_summary = summary }
    | `Assoc [ "kind", `String "idle_detected"; "consecutive_idle_turns", `Int n ] ->
      Ok (Idle_detected { consecutive_idle_turns = n })
    | `Assoc [ "kind", `String "runtime_exhausted"; "detail", detail ] ->
      let+ r = runtime_of_yojson detail in
      Runtime_exhausted r
    | `Assoc [ "kind", `String "turn_budget_exhausted"
             ; "dimension", `String d
             ; "used", `Int u
             ; "limit", `Int l
             ; "source", `String s ] ->
      let* dim = dim_of_string d in
      let* src = source_of_string s in
      Ok (Turn_budget_exhausted { detail = { dimension = dim; source = src }; used = u; limit = l })
    | `Assoc [ "kind", `String "stale_storm" ] -> Ok Stale_storm
    | `Assoc [ "kind", `String "provider_timeout_loop"; "consecutive_timeouts", `Int n ] ->
      Ok (Provider_timeout_loop { consecutive_timeouts = n })
    | `Assoc [ "kind", `String "operator_paused"; "actor", `String actor ] ->
      let+ operator_actor = operator_actor_of_wire actor in
      Operator_paused { operator_actor }
    | `Assoc [ "kind", `String "dead_tombstone" ] -> Ok Dead_tombstone
    | _ ->
      Error
        (Printf.sprintf
           "Keeper_latched_reason.of_yojson: unknown shape: %s"
           (Yojson.Safe.to_string j))
  ;;
end
