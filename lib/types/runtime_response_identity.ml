type t =
  { execution_id : string
  ; actor : string
  ; runtime_id : string
  ; response_id : string
  ; provider_id : string
  ; model_id : string
  ; tool_use_id : string
  ; provider_turn : int
  ; source_tool_use_ordinal : int
  }

let make ~execution_id ~actor ~runtime_id ~response_id ~provider_id ~model_id ~tool_use_id ~provider_turn ~source_tool_use_ordinal =
  let fields = [ "execution_id", execution_id; "actor", actor; "runtime_id", runtime_id
    ; "response_id", response_id; "provider_id", provider_id; "model_id", model_id; "tool_use_id", tool_use_id ] in
  match List.find_opt (fun (_, value) -> String.trim value = "") fields with
  | Some (name, _) -> Error ("runtime response identity has no " ^ name)
  | None when provider_turn < 0 -> Error "runtime response identity has a negative provider turn"
  | None when source_tool_use_ordinal < 0 -> Error "runtime response identity has a negative source ToolUse ordinal"
  | None -> Ok { execution_id; actor; runtime_id; response_id; provider_id; model_id; tool_use_id; provider_turn; source_tool_use_ordinal }

let to_yojson value =
  `Assoc [ "execution_id", `String value.execution_id; "actor", `String value.actor
    ; "runtime_id", `String value.runtime_id; "response_id", `String value.response_id
    ; "provider_id", `String value.provider_id; "model_id", `String value.model_id
    ; "tool_use_id", `String value.tool_use_id; "provider_turn", `Int value.provider_turn
    ; "source_tool_use_ordinal", `Int value.source_tool_use_ordinal ]

let of_yojson = function
  | `Assoc fields ->
    let open Result.Syntax in
    let allowed = [ "execution_id"; "actor"; "runtime_id"; "response_id"; "provider_id"; "model_id"; "tool_use_id"; "provider_turn"; "source_tool_use_ordinal" ] in
    let* () =
      if List.length fields = List.length allowed
         && List.for_all (fun name -> List.length (List.filter (fun (key, _) -> key = name) fields) = 1) allowed
      then Ok () else Error "runtime response identity has unexpected or missing fields" in
    let field name = match List.assoc_opt name fields with
      | Some (`String value) -> Ok value
      | Some _ | None -> Error ("runtime response identity has no string " ^ name) in
    let* execution_id = field "execution_id" in
    let* actor = field "actor" in
    let* runtime_id = field "runtime_id" in
    let* response_id = field "response_id" in
    let* provider_id = field "provider_id" in
    let* model_id = field "model_id" in
    let* tool_use_id = field "tool_use_id" in
    let integer_field name = match List.assoc_opt name fields with
      | Some (`Int value) -> Ok value
      | Some _ | None -> Error ("runtime response identity has no integer " ^ name) in
    let* provider_turn = integer_field "provider_turn" in
    let* source_tool_use_ordinal = integer_field "source_tool_use_ordinal" in
    make ~execution_id ~actor ~runtime_id ~response_id ~provider_id ~model_id ~tool_use_id ~provider_turn ~source_tool_use_ordinal
  | _ -> Error "runtime response identity must be an object"

let same_model_identity left right =
  String.equal left.provider_id right.provider_id && String.equal left.model_id right.model_id

type pair_observation =
  | Same_model_identity
  | Distinct_model_identity
  | Producer_unobserved
  | Evaluator_unobserved
  | Both_unobserved

let observe_pair ~producer ~evaluator = match producer, evaluator with
  | Some producer, Some evaluator ->
    if same_model_identity producer evaluator then Same_model_identity else Distinct_model_identity
  | None, Some _ -> Producer_unobserved
  | Some _, None -> Evaluator_unobserved
  | None, None -> Both_unobserved

type pair_summary =
  { same_model_identity_count : int
  ; distinct_model_identity_count : int
  ; producer_unobserved_count : int
  ; evaluator_unobserved_count : int
  ; both_unobserved_count : int
  }

let summarize_pairs pairs =
  List.fold_left (fun summary (producer, evaluator) ->
    match observe_pair ~producer ~evaluator with
    | Same_model_identity -> { summary with same_model_identity_count = summary.same_model_identity_count + 1 }
    | Distinct_model_identity -> { summary with distinct_model_identity_count = summary.distinct_model_identity_count + 1 }
    | Producer_unobserved -> { summary with producer_unobserved_count = summary.producer_unobserved_count + 1 }
    | Evaluator_unobserved -> { summary with evaluator_unobserved_count = summary.evaluator_unobserved_count + 1 }
    | Both_unobserved -> { summary with both_unobserved_count = summary.both_unobserved_count + 1 })
    { same_model_identity_count = 0; distinct_model_identity_count = 0
    ; producer_unobserved_count = 0; evaluator_unobserved_count = 0; both_unobserved_count = 0 } pairs

let pair_summary_to_yojson summary =
  let observed = summary.same_model_identity_count + summary.distinct_model_identity_count in
  let unobserved = summary.producer_unobserved_count + summary.evaluator_unobserved_count + summary.both_unobserved_count in
  `Assoc
    [ "observed_verdict_count", `Int observed
    ; "unobserved_verdict_count", `Int unobserved
    ; "same_model_identity_count", `Int summary.same_model_identity_count
    ; "distinct_model_identity_count", `Int summary.distinct_model_identity_count
    ; "distinct_model_identity_rate", (if observed = 0 then `Null
        else `Float (float_of_int summary.distinct_model_identity_count /. float_of_int observed))
    ; "unobserved_causes", `Assoc
        [ "producer", `Int summary.producer_unobserved_count
        ; "evaluator", `Int summary.evaluator_unobserved_count
        ; "both", `Int summary.both_unobserved_count ]
    ]
