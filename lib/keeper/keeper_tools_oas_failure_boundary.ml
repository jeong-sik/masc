type t =
  { failure_class : Tool_result.tool_failure_class
  ; failure_class_declared : bool
  ; is_workflow_rejection : bool
  ; deterministic_classification :
      Keeper_tool_deterministic_error.classification option
  }


let failure_class_of_json json =
  if Json_util.get_bool json "ok" |> Option.value ~default:false
  then None
  else
    Option.bind
      (Json_util.get_string json "failure_class")
      Tool_result.tool_failure_class_of_string
;;

let structured_error_json = function
  | `Assoc fields ->
    (match List.assoc_opt "error" fields with
     | Some (`String raw) ->
       (try
          match Yojson.Safe.from_string raw with
          | `Assoc _ as json -> Some json
          | _ -> None
        with
        | Yojson.Json_error _ -> None)
     | _ -> None)
  | _ -> None
;;

let classify_raw_failure raw =
  let json =
    try Some (Yojson.Safe.from_string raw) with
    | Yojson.Json_error _ -> None
  in
  let classification_json =
    match json with
    | Some json ->
      (match failure_class_of_json json with
       | Some _ -> Some json
       | None ->
         (match structured_error_json json with
          | Some nested -> Some nested
          | None -> Some json))
    | None -> None
  in
  let declared_failure_class = Option.bind classification_json failure_class_of_json in
  let failure_class =
    (* Undeclared payloads resolve to Runtime_failure: the conservative
       non-retryable projection of "the producer stated no class". The
       resolution is surfaced through [failure_class_declared] so producers
       that must declare (Execute outcome/blocked/validation JSON since the
       sangsu incident fix) are testable and regressions are visible instead
       of silently reclassified. *)
    (* DET-OK: not a guessed parse default — the undeclared case is carried
       as [failure_class_declared = false] alongside this conservative
       resolution. *)
    Option.value declared_failure_class ~default:Tool_result.Runtime_failure
  in
  let deterministic_classification =
    if Tool_result.is_retryable failure_class
    then None
    else
      Option.bind
        classification_json
        Keeper_tool_deterministic_error.classify_with_source
  in
  { failure_class
  ; failure_class_declared = Option.is_some declared_failure_class
  ; is_workflow_rejection = (failure_class = Tool_result.Workflow_rejection)
  ; deterministic_classification
  }
;;
