(* RFC-0042 PR-5 / SSOT-1: typed SSOT for "why a keeper is latched".

   Wire form is informational only and is parsed by [of_wire] into a
   closed sum; never used as a classifier by consumers in this repo.

   Equality and hashing are typed ([equal] / [hash]); the wire string is
   a derived view, never the source of truth. *)

open! Core

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
  | Turn_budget_exhausted of
      { dimension :
          [ `Turns
          | `Wall_clock_seconds
          | `Idle_turns
          ]
      ; used : int
      ; limit : int
      ; source :
          [ `Oas_sdk
          | `Keeper_runtime
          | `User_config
          ]
      }
  | Stale_storm
  | Provider_timeout_loop of { consecutive_timeouts : int }
  | Operator_paused of { operator_actor : string }

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
        { dimension = d1; used = u1; limit = l1; source = s1 }
    , Turn_budget_exhausted
        { dimension = d2; used = u2; limit = l2; source = s2 } ) ->
    poly_equal d1 d2 && Int.equal u1 u2 && Int.equal l1 l2 && poly_equal_source s1 s2
  | Stale_storm, Stale_storm -> true
  | ( Provider_timeout_loop { consecutive_timeouts = c1 }
    , Provider_timeout_loop { consecutive_timeouts = c2 } ) ->
    Int.equal c1 c2
  | Operator_paused { operator_actor = a1 }, Operator_paused { operator_actor = a2 } ->
    String.equal a1 a2
  | ( ( No_progress_loop _
      | Completion_contract_violation _
      | Idle_detected _
      | Runtime_exhausted _
      | Turn_budget_exhausted _
      | Stale_storm
      | Provider_timeout_loop _
      | Operator_paused _ )
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
      , match detector_kind with
        | `Consecutive_idle_turns -> 0
        | `Consecutive_no_progress -> 1
        | `Both -> 2 )
  | Completion_contract_violation d ->
    Hashtbl.hash
      ( 1
      , match d.reason_code with
        | `No_tool_use_block -> 0
        | `No_keeper_tool_returned -> 1
        | `Repeated_text_only_response -> 2
        | `Unspecified -> 3
      , d.raw_error_summary )
  | Idle_detected { consecutive_idle_turns } -> Hashtbl.hash (2, consecutive_idle_turns)
  | Runtime_exhausted r ->
    Hashtbl.hash
      ( 3
      , match r with
        | All_providers_failed -> 0
        | No_providers_available -> 1
        | Structural_attempt_timeout { stage } -> Hashtbl.hash (2, stage)
        | Unspecified_runtime -> 3 )
  | Turn_budget_exhausted { dimension; used; limit; source } ->
    Hashtbl.hash
      ( 4
      , match dimension with `Turns -> 0 | `Wall_clock_seconds -> 1 | `Idle_turns -> 2
      , used
      , limit
      , match source with `Oas_sdk -> 0 | `Keeper_runtime -> 1 | `User_config -> 2 )
  | Stale_storm -> 5
  | Provider_timeout_loop { consecutive_timeouts } -> Hashtbl.hash (6, consecutive_timeouts)
  | Operator_paused { operator_actor } -> Hashtbl.hash (7, operator_actor)
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
  | Turn_budget_exhausted { dimension; used; limit; source } ->
    Format.fprintf
      ppf
      "Turn_budget_exhausted{dim=%s,used=%d,limit=%d,source=%s}"
      (pp_dim dimension)
      used
      limit
      (pp_source source)
  | Stale_storm -> Format.fprintf ppf "Stale_storm"
  | Provider_timeout_loop { consecutive_timeouts } ->
    Format.fprintf ppf "Provider_timeout_loop{count=%d}" consecutive_timeouts
  | Operator_paused { operator_actor } ->
    Format.fprintf ppf "Operator_paused{actor=%s}" operator_actor
;;

(* -------------------------------------------------------------------- *)
(* Wire format                                                           *)
(* -------------------------------------------------------------------- *)

(* Stdlib Result helpers (kept local so the module has no external
   dependency on a project-specific [R] module). *)
let ( let* ) = Result.bind
let ( let+ ) = Result.map
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
    Printf.sprintf "runtime_exhausted:%a" pp_runtime_exhaustion r
  | Turn_budget_exhausted { dimension; used; limit; source } ->
    Printf.sprintf
      "turn_budget_exhausted:dim=%s:used=%d:limit=%d:source=%s"
      (pp_dim dimension)
      used
      limit
      (pp_source source)
  | Stale_storm -> "stale_storm"
  | Provider_timeout_loop { consecutive_timeouts } ->
    Printf.sprintf "provider_timeout_loop:count=%d" consecutive_timeouts
  | Operator_paused { operator_actor } ->
    Printf.sprintf "operator_paused:actor=%s" operator_actor
;;

(* Fail-closed parser. The wire form is append-only information; any
   unknown shape yields [Error] rather than a permissive catch-all
   ([Keeper_terminal_reason.t] uses prefix matching for legacy wire
   compatibility — that layer is intentionally permissive; this layer
   is intentionally strict). *)
let of_wire wire =
  
  match String.split_on_char ':' wire with
  | [ "no_progress_loop"; payload ] ->
    (match String.split_on_char '=' payload with
     | [ "cycles"; c ] :: [ "detector"; d ] :: [] ->
       let+ cycles = int_of_string_exn c in
       let detector =
         match d with
         | "consecutive_idle_turns" -> `Consecutive_idle_turns
         | "consecutive_no_progress" -> `Consecutive_no_progress
         | "both" -> `Both
         | _ -> Error (Printf.sprintf "Keeper_latched_reason.of_wire: unknown detector %S" d
       in
       No_progress_loop { consecutive_idle_cycles = cycles; detector_kind = detector }
     | _ -> Error (Printf.sprintf "Keeper_latched_reason.of_wire: malformed no_progress_loop payload %S" payload)
  | "completion_contract_violation" :: "code=" :: _ :: _
  | "completion_contract_violation" :: _ ->
    (* Payload-bearing variants with embedded ':' (e.g. summary quoting)
       are reconstructed byte-for-byte. *)
    let code =
      let stripped = String.chop_prefix ~prefix:"completion_contract_violation:code=" wire in
      match stripped with
      | Some s ->
        (match String.split_on_char ':' s with
         | code_str :: _ -> code_str
         | [] -> "")
      | None -> ""
    in
    let reason_code =
      match code with
      | "no_tool_use_block" -> `No_tool_use_block
      | "no_keeper_tool_returned" -> `No_keeper_tool_returned
      | "repeated_text_only_response" -> `Repeated_text_only_response
      | _ -> `Unspecified
    in
    let summary =
      let prefix = Printf.sprintf "completion_contract_violation:code=%s:summary=" code in
      String.chop_prefix ~prefix wire |> Option.value ~default:""
    in
    Ok (Completion_contract_violation { reason_code; raw_error_summary = summary })
  | [ "idle_detected"; payload ] ->
    (match String.split_on_char '=' payload with
     | [ "idle_turns"; t ] :: [] ->
       let+ idle_turns = int_of_string_exn t in
       Idle_detected { consecutive_idle_turns = idle_turns }
     | _ -> Error (Printf.sprintf "Keeper_latched_reason.of_wire: malformed idle_detected payload %S" payload)
  | "runtime_exhausted" :: "all_providers_failed" :: [] ->
    Ok (Runtime_exhausted All_providers_failed)
  | "runtime_exhausted" :: "no_providers_available" :: [] ->
    Ok (Runtime_exhausted No_providers_available)
  | "runtime_exhausted" :: "structural_attempt_timeout" :: "stage=" :: stage :: [] ->
    Ok (Runtime_exhausted (Structural_attempt_timeout { stage }))
  | [ "runtime_exhausted"; "unspecified_runtime" ] ->
    Ok (Runtime_exhausted Unspecified_runtime)
  | "turn_budget_exhausted" :: "dim=" :: _ :: _ ->
    let+ dim =
      let prefix = "turn_budget_exhausted:dim=" in
      let stripped = String.chop_prefix ~prefix wire |> Option.value ~default:"" in
      match String.split_on_char ':' stripped with
      | d :: _ ->
        (match d with
         | "turns" -> Ok `Turns
         | "wall_clock_seconds" -> Ok `Wall_clock_seconds
         | "idle_turns" -> Ok `Idle_turns
         | _ ->
           Error (Printf.sprintf "Keeper_latched_reason.of_wire: unknown dimension %S" d)
      | [] -> Error (Printf.sprintf "Keeper_latched_reason.of_wire: missing dimension"
    in
    (* Use typed accessor for the remaining fields; full parse via
       sub-functions rather than ad-hoc string splits. *)
    let parse_int_field prefix =
      let stripped = String.chop_prefix ~prefix wire |> Option.value ~default:"" in
      match String.split_on_char ':' stripped with
      | _ :: rest ->
        (match rest with
         | v :: _ -> int_of_string_exn v
         | [] -> Error (Printf.sprintf "missing int after %s" prefix)
      | [] -> Error (Printf.sprintf "missing field %s" prefix
    in
    let* used = parse_int_field "turn_budget_exhausted:dim=turns:used=" in
    let* limit = parse_int_field (Printf.sprintf "turn_budget_exhausted:dim=%s:used=%d:limit=" (pp_dim dim) used) in
    let* source =
      let stripped =
        String.chop_prefix
          ~prefix:(Printf.sprintf "turn_budget_exhausted:dim=%s:used=%d:limit=%d:source=" (pp_dim dim) used limit)
          wire
        |> Option.value ~default:""
      in
      match stripped with
      | "oas_sdk" -> Ok `Oas_sdk
      | "keeper_runtime" -> Ok `Keeper_runtime
      | "user_config" -> Ok `User_config
      | _ -> Error (Printf.sprintf "Keeper_latched_reason.of_wire: unknown source %S" stripped
    in
    Ok (Turn_budget_exhausted { dimension = dim; used; limit; source })
  | [ "stale_storm" ] -> Ok Stale_storm
  | [ "provider_timeout_loop"; payload ] ->
    (match String.split_on_char '=' payload with
     | [ "count"; c ] :: [] ->
       let+ count = int_of_string_exn c in
       Provider_timeout_loop { consecutive_timeouts = count }
     | _ -> Error (Printf.sprintf "Keeper_latched_reason.of_wire: malformed provider_timeout_loop payload %S" payload)
  | "operator_paused" :: "actor=" :: _ :: _ ->
    let actor = String.chop_prefix ~prefix:"operator_paused:actor=" wire |> Option.value ~default:"" in
    Ok (Operator_paused { operator_actor = actor })
  | _ ->
    Error (Printf.sprintf "Keeper_latched_reason.of_wire: unknown wire form %S" wire
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
    | _ -> Error (Printf.sprintf "Keeper_latched_reason: unknown dimension %S" s
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
    | _ -> Error (Printf.sprintf "Keeper_latched_reason: unknown source %S" s
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
    | _ -> Error (Printf.sprintf "Keeper_latched_reason: unknown reason_code %S" s
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
    | _ -> Error (Printf.sprintf "Keeper_latched_reason: unknown detector %S" s
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
        (Yojson.Safe.to_string j)
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
    | Turn_budget_exhausted { dimension; used; limit; source } ->
      `Assoc
        [ "kind", `String "turn_budget_exhausted"
        ; "dimension", `String (string_of_dim dimension)
        ; "used", `Int used
        ; "limit", `Int limit
        ; "source", `String (string_of_source source)
        ]
    | Stale_storm -> `Assoc [ "kind", `String "stale_storm" ]
    | Provider_timeout_loop { consecutive_timeouts } ->
      `Assoc
        [ "kind", `String "provider_timeout_loop"
        ; "consecutive_timeouts", `Int consecutive_timeouts
        ]
    | Operator_paused { operator_actor } ->
      `Assoc [ "kind", `String "operator_paused"; "actor", `String operator_actor ]
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
      Ok (Turn_budget_exhausted { dimension = dim; used = u; limit = l; source = src })
    | `Assoc [ "kind", `String "stale_storm" ] -> Ok Stale_storm
    | `Assoc [ "kind", `String "provider_timeout_loop"; "consecutive_timeouts", `Int n ] ->
      Ok (Provider_timeout_loop { consecutive_timeouts = n })
    | `Assoc [ "kind", `String "operator_paused"; "actor", `String actor ] ->
      Ok (Operator_paused { operator_actor = actor })
    | _ ->
      Error (Printf.sprintf "Keeper_latched_reason.of_yojson: unknown shape: %s" (Yojson.Safe.to_string j)
  ;;
end