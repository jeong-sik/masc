module Route = Keeper_runtime_failure_route

type retry_requirement =
  | Provider_retry_after of
      { retry_class : Route.retry_class
      ; delay_seconds : float
      }
  | Provider_recovery of Route.retry_class
  | Runtime_catalog_change of Route.rotate_class
  | Runtime_configuration_change

type retryable =
  { requirement : retry_requirement
  ; detail : string
  ; failed_at : float
  }

type blocked_kind =
  | Prompt_contract_unavailable
  | Response_contract_unavailable
  | Provider_judgment_required of
      { judgment : Route.judgment_class
      ; provenance : Route.judgment_provenance
      }
  | Invalid_provider_retry_authority
  | Unexpected_judgment_exception

type blocked =
  { kind : blocked_kind
  ; detail : string
  ; blocked_at : float
  }

type attempt_failure =
  | Retryable of retryable
  | Blocked of blocked

let ( let* ) = Result.bind

let nonempty label value =
  if String.equal (String.trim value) ""
  then Error (label ^ " must not be empty")
  else Ok ()
;;

let finite_nonnegative label value =
  if not (Float.is_finite value)
  then Error (label ^ " must be finite")
  else if Float.compare value 0.0 < 0
  then Error (label ^ " must not be negative")
  else Ok ()
;;

let finite_time label value =
  if Float.is_finite value then Ok () else Error (label ^ " must be finite")
;;

let retry_deadline (failure : retryable) =
  match failure.requirement with
  | Provider_retry_after { delay_seconds; _ } ->
    Some (failure.failed_at +. delay_seconds)
  | Provider_recovery _
  | Runtime_catalog_change _
  | Runtime_configuration_change -> None
;;

let retry_requirement_label = function
  | Provider_retry_after _ -> "provider_retry_after"
  | Provider_recovery _ -> "provider_recovery"
  | Runtime_catalog_change _ -> "runtime_catalog_change"
  | Runtime_configuration_change -> "runtime_configuration_change"
;;

let blocked_kind_label = function
  | Prompt_contract_unavailable -> "prompt_contract_unavailable"
  | Response_contract_unavailable -> "response_contract_unavailable"
  | Provider_judgment_required _ -> "provider_judgment_required"
  | Invalid_provider_retry_authority -> "invalid_provider_retry_authority"
  | Unexpected_judgment_exception -> "unexpected_judgment_exception"
;;

let validate_retryable (failure : retryable) =
  let* () = nonempty "attention retry detail" failure.detail in
  let* () = finite_time "attention retry failed_at" failure.failed_at in
  match failure.requirement with
  | Provider_retry_after { delay_seconds; _ } ->
    let* () = finite_nonnegative "Provider retry-after" delay_seconds in
    (match retry_deadline failure with
     | Some deadline -> finite_time "Provider retry deadline" deadline
     | None -> Error "Provider retry-after did not produce a deadline")
  | Provider_recovery _
  | Runtime_catalog_change _
  | Runtime_configuration_change -> Ok ()
;;

let validate_blocked (failure : blocked) =
  let* () = nonempty "attention blocked detail" failure.detail in
  finite_time "attention blocked_at" failure.blocked_at
;;

let display_detail error =
  Keeper_internal_error.cap_blocker_detail (Agent_sdk.Error.to_string error)
;;

let blocked ~blocked_at ~kind ~detail =
  Blocked { kind; detail; blocked_at }
;;

let runtime_configuration_change ~failed_at ~detail =
  Retryable { requirement = Runtime_configuration_change; detail; failed_at }
;;

let of_sdk_error ~observed_at error =
  let detail = display_detail error in
  match Route.route_of_error ~boundary:Route.Oas_execution error with
  | Route.Retry_after_observed { retry_class; retry_after = None } ->
    Retryable
      { requirement = Provider_recovery retry_class
      ; detail
      ; failed_at = observed_at
      }
  | Route.Retry_after_observed
      { retry_class; retry_after = Some delay_seconds } ->
    let retryable =
      { requirement = Provider_retry_after { retry_class; delay_seconds }
      ; detail
      ; failed_at = observed_at
      }
    in
    (match validate_retryable retryable with
     | Ok () -> Retryable retryable
     | Error authority_error ->
       blocked
         ~blocked_at:observed_at
         ~kind:Invalid_provider_retry_authority
         ~detail:(detail ^ "; " ^ authority_error))
  | Route.Rotate_now { rotate } ->
    Retryable
      { requirement = Runtime_catalog_change rotate
      ; detail
      ; failed_at = observed_at
      }
  | Route.Escalate_judgment { judgment; provenance; detail } ->
    blocked
      ~blocked_at:observed_at
      ~kind:(Provider_judgment_required { judgment; provenance })
      ~detail
;;

let retry_requirement_to_yojson = function
  | Provider_retry_after { retry_class; delay_seconds } ->
    `Assoc
      [ "kind", `String "provider_retry_after"
      ; "retry_class", `String (Route.retry_class_label retry_class)
      ; "delay_seconds", `Float delay_seconds
      ]
  | Provider_recovery retry_class ->
    `Assoc
      [ "kind", `String "provider_recovery"
      ; "retry_class", `String (Route.retry_class_label retry_class)
      ]
  | Runtime_catalog_change rotate_class ->
    `Assoc
      [ "kind", `String "runtime_catalog_change"
      ; "rotate_class", `String (Route.rotate_class_label rotate_class)
      ]
  | Runtime_configuration_change ->
    `Assoc [ "kind", `String "runtime_configuration_change" ]
;;

let blocked_kind_to_yojson = function
  | Prompt_contract_unavailable ->
    `Assoc [ "kind", `String "prompt_contract_unavailable" ]
  | Response_contract_unavailable ->
    `Assoc [ "kind", `String "response_contract_unavailable" ]
  | Invalid_provider_retry_authority ->
    `Assoc [ "kind", `String "invalid_provider_retry_authority" ]
  | Unexpected_judgment_exception ->
    `Assoc [ "kind", `String "unexpected_judgment_exception" ]
  | Provider_judgment_required { judgment; provenance } ->
    `Assoc
      [ "kind", `String "provider_judgment_required"
      ; "judgment", `String (Route.judgment_class_label judgment)
      ; "provenance", Route.judgment_provenance_to_yojson provenance
      ]
;;

let retryable_to_yojson (failure : retryable) =
  `Assoc
    [ "requirement", retry_requirement_to_yojson failure.requirement
    ; "detail", `String failure.detail
    ; "failed_at", `Float failure.failed_at
    ]
;;

let blocked_to_yojson (failure : blocked) =
  `Assoc
    [ "kind", blocked_kind_to_yojson failure.kind
    ; "detail", `String failure.detail
    ; "blocked_at", `Float failure.blocked_at
    ]
;;

let assoc ~context = function
  | `Assoc fields -> Ok fields
  | _ -> Error (context ^ " must be an object")
;;

let exact_fields ~context expected fields =
  let actual = List.map fst fields in
  if List.length actual = List.length expected
     && List.for_all (fun key -> List.mem key actual) expected
  then Ok ()
  else
    Error
      (Printf.sprintf
         "%s fields must be exactly [%s], got [%s]"
         context
         (String.concat "," expected)
         (String.concat "," actual))
;;

let field ~context key fields =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s missing field %s" context key)
;;

let string_json ~context = function
  | `String value -> Ok value
  | _ -> Error (context ^ " must be a string")
;;

let float_json ~context = function
  | `Float value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> Error (context ^ " must be a number")
;;

let retry_class_json ~context json =
  let* label = string_json ~context json in
  match Route.retry_class_of_label label with
  | Some retry_class -> Ok retry_class
  | None -> Error (Printf.sprintf "unknown retry class %S" label)
;;

let rotate_class_json ~context json =
  let* label = string_json ~context json in
  match Route.rotate_class_of_label label with
  | Some rotate_class -> Ok rotate_class
  | None -> Error (Printf.sprintf "unknown rotate class %S" label)
;;

let retry_requirement_of_yojson json =
  let context = "attention retry requirement" in
  let* fields = assoc ~context json in
  let* kind_json = field ~context "kind" fields in
  let* kind = string_json ~context:(context ^ ".kind") kind_json in
  match kind with
  | "provider_retry_after" ->
    let* () = exact_fields ~context [ "kind"; "retry_class"; "delay_seconds" ] fields in
    let* retry_json = field ~context "retry_class" fields in
    let* retry_class = retry_class_json ~context:(context ^ ".retry_class") retry_json in
    let* delay_json = field ~context "delay_seconds" fields in
    let* delay_seconds = float_json ~context:(context ^ ".delay_seconds") delay_json in
    Ok (Provider_retry_after { retry_class; delay_seconds })
  | "provider_recovery" ->
    let* () = exact_fields ~context [ "kind"; "retry_class" ] fields in
    let* retry_json = field ~context "retry_class" fields in
    let* retry_class = retry_class_json ~context:(context ^ ".retry_class") retry_json in
    Ok (Provider_recovery retry_class)
  | "runtime_catalog_change" ->
    let* () = exact_fields ~context [ "kind"; "rotate_class" ] fields in
    let* rotate_json = field ~context "rotate_class" fields in
    let* rotate_class = rotate_class_json ~context:(context ^ ".rotate_class") rotate_json in
    Ok (Runtime_catalog_change rotate_class)
  | "runtime_configuration_change" ->
    let* () = exact_fields ~context [ "kind" ] fields in
    Ok Runtime_configuration_change
  | value -> Error (Printf.sprintf "unknown attention retry requirement %S" value)
;;

let blocked_kind_of_yojson json =
  let context = "attention blocked kind" in
  let* fields = assoc ~context json in
  let* kind_json = field ~context "kind" fields in
  let* kind = string_json ~context:(context ^ ".kind") kind_json in
  match kind with
  | "prompt_contract_unavailable" ->
    let* () = exact_fields ~context [ "kind" ] fields in
    Ok Prompt_contract_unavailable
  | "response_contract_unavailable" ->
    let* () = exact_fields ~context [ "kind" ] fields in
    Ok Response_contract_unavailable
  | "invalid_provider_retry_authority" ->
    let* () = exact_fields ~context [ "kind" ] fields in
    Ok Invalid_provider_retry_authority
  | "unexpected_judgment_exception" ->
    let* () = exact_fields ~context [ "kind" ] fields in
    Ok Unexpected_judgment_exception
  | "provider_judgment_required" ->
    let* () = exact_fields ~context [ "kind"; "judgment"; "provenance" ] fields in
    let* judgment_json = field ~context "judgment" fields in
    let* judgment_label = string_json ~context:(context ^ ".judgment") judgment_json in
    let* judgment =
      match Route.judgment_class_of_label judgment_label with
      | Some judgment -> Ok judgment
      | None -> Error (Printf.sprintf "unknown judgment class %S" judgment_label)
    in
    let* provenance_json = field ~context "provenance" fields in
    let* provenance = Route.judgment_provenance_of_yojson provenance_json in
    Ok (Provider_judgment_required { judgment; provenance })
  | value -> Error (Printf.sprintf "unknown attention blocked kind %S" value)
;;

let retryable_of_yojson json =
  let context = "attention retryable failure" in
  let* fields = assoc ~context json in
  let* () = exact_fields ~context [ "requirement"; "detail"; "failed_at" ] fields in
  let* requirement_json = field ~context "requirement" fields in
  let* requirement = retry_requirement_of_yojson requirement_json in
  let* detail_json = field ~context "detail" fields in
  let* detail = string_json ~context:(context ^ ".detail") detail_json in
  let* failed_json = field ~context "failed_at" fields in
  let* failed_at = float_json ~context:(context ^ ".failed_at") failed_json in
  let failure = { requirement; detail; failed_at } in
  let* () = validate_retryable failure in
  Ok failure
;;

let blocked_of_yojson json =
  let context = "attention blocked failure" in
  let* fields = assoc ~context json in
  let* () = exact_fields ~context [ "kind"; "detail"; "blocked_at" ] fields in
  let* kind_json = field ~context "kind" fields in
  let* kind = blocked_kind_of_yojson kind_json in
  let* detail_json = field ~context "detail" fields in
  let* detail = string_json ~context:(context ^ ".detail") detail_json in
  let* blocked_json = field ~context "blocked_at" fields in
  let* blocked_at = float_json ~context:(context ^ ".blocked_at") blocked_json in
  let failure = { kind; detail; blocked_at } in
  let* () = validate_blocked failure in
  Ok failure
;;
