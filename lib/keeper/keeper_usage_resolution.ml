type cumulative_position = Fresh | Resumed

type basis =
  | Per_request
  | Conversation_counter of
      { runtime_id : string
      ; conversation_id : string
      ; position : cumulative_position
      }
  | Unavailable

type sample =
  { input_tokens : int
  ; output_tokens : int
  ; cache_creation_input_tokens : int
  ; cache_read_input_tokens : int
  ; cost_usd : float option
  }

type cursor =
  { runtime_id : string
  ; conversation_id : string
  ; cumulative : sample
  }

type status =
  | Exact
  | Usage_missing
  | Scope_unavailable
  | Invalid_observation
  | Exact_cost_unavailable
  | Baseline_missing
  | Counter_regressed

type t =
  { observation : sample option
  ; basis : basis
  ; delta : sample option
  ; status : status
  ; observed_at : float
  }

let sample_of_api_usage (usage : Agent_core.Types.api_usage) =
  { input_tokens = usage.input_tokens
  ; output_tokens = usage.output_tokens
  ; cache_creation_input_tokens = usage.cache_creation_input_tokens
  ; cache_read_input_tokens = usage.cache_read_input_tokens
  ; cost_usd = usage.cost_usd
  }
;;

let api_usage_of_sample sample : Agent_core.Types.api_usage =
  { input_tokens = sample.input_tokens
  ; output_tokens = sample.output_tokens
  ; cache_creation_input_tokens = sample.cache_creation_input_tokens
  ; cache_read_input_tokens = sample.cache_read_input_tokens
  ; cost_usd = sample.cost_usd
  }
;;

let status_to_string = function
  | Exact -> "exact"
  | Usage_missing -> "usage_missing"
  | Scope_unavailable -> "scope_unavailable"
  | Invalid_observation -> "invalid_observation"
  | Exact_cost_unavailable -> "exact_cost_unavailable"
  | Baseline_missing -> "baseline_missing"
  | Counter_regressed -> "counter_regressed"
;;

let scope_of_basis = function
  | Per_request -> Runtime_usage_scope.Per_request
  | Conversation_counter _ -> Runtime_usage_scope.Conversation_cumulative
  | Unavailable -> Runtime_usage_scope.Usage_scope_unavailable
;;

let position_to_string = function Fresh -> "fresh" | Resumed -> "resumed"

let position_of_string = function
  | "fresh" -> Ok Fresh
  | "resumed" -> Ok Resumed
  | value -> Error (Printf.sprintf "unknown cumulative position %S" value)
;;

let sample_to_json sample =
  `Assoc
    [ "input_tokens", `Int sample.input_tokens
    ; "output_tokens", `Int sample.output_tokens
    ; "cache_creation_input_tokens", `Int sample.cache_creation_input_tokens
    ; "cache_read_input_tokens", `Int sample.cache_read_input_tokens
    ; "cost_usd", Json_util.float_opt_to_json sample.cost_usd
    ]
;;

let ( let* ) = Result.bind

let exact_fields expected fields =
  let names = List.map fst fields in
  List.length names = List.length expected
  && List.for_all (fun name -> List.mem name expected) names
  && List.length names = List.length (List.sort_uniq String.compare names)
;;

let int_field name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Ok value
  | _ -> Error (Printf.sprintf "%s must be an integer" name)
;;

let string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | _ -> Error (Printf.sprintf "%s must be a non-empty string" name)
;;

let float_field name fields =
  match List.assoc_opt name fields with
  | Some (`Float value) when Float.is_finite value -> Ok value
  | Some (`Int value) -> Ok (Float.of_int value)
  | _ -> Error (name ^ " must be finite")
;;

let sample_of_json = function
  | `Assoc fields
    when exact_fields
           [ "input_tokens"
           ; "output_tokens"
           ; "cache_creation_input_tokens"
           ; "cache_read_input_tokens"
           ; "cost_usd"
           ]
           fields ->
    let* input_tokens = int_field "input_tokens" fields in
    let* output_tokens = int_field "output_tokens" fields in
    let* cache_creation_input_tokens = int_field "cache_creation_input_tokens" fields in
    let* cache_read_input_tokens = int_field "cache_read_input_tokens" fields in
    let* cost_usd =
      match List.assoc_opt "cost_usd" fields with
      | Some `Null -> Ok None
      | Some (`Float value) when Float.is_finite value -> Ok (Some value)
      | Some (`Int value) -> Ok (Some (Float.of_int value))
      | _ -> Error "cost_usd must be null or a finite number"
    in
    Ok
      { input_tokens
      ; output_tokens
      ; cache_creation_input_tokens
      ; cache_read_input_tokens
      ; cost_usd
      }
  | _ -> Error "usage sample fields are not exact"
;;

let sample_is_valid sample =
  sample.input_tokens >= 0
  && sample.output_tokens >= 0
  && sample.cache_creation_input_tokens >= 0
  && sample.cache_read_input_tokens >= 0
  && Option.fold
       ~none:true
       ~some:(fun cost -> cost >= 0.0 && Float.is_finite cost)
       sample.cost_usd
;;

let basis_to_json = function
  | Per_request -> `Assoc [ "kind", `String "per_request" ]
  | Unavailable -> `Assoc [ "kind", `String "unavailable" ]
  | Conversation_counter { runtime_id; conversation_id; position } ->
    `Assoc
      [ "kind", `String "conversation_counter"
      ; "runtime_id", `String runtime_id
      ; "conversation_id", `String conversation_id
      ; "position", `String (position_to_string position)
      ]
;;

let basis_of_json = function
  | `Assoc [ "kind", `String "per_request" ] -> Ok Per_request
  | `Assoc [ "kind", `String "unavailable" ] -> Ok Unavailable
  | `Assoc fields
    when exact_fields [ "kind"; "runtime_id"; "conversation_id"; "position" ] fields ->
    let* kind = string_field "kind" fields in
    if not (String.equal kind "conversation_counter")
    then Error (Printf.sprintf "unknown usage basis %S" kind)
    else
      let* runtime_id = string_field "runtime_id" fields in
      let* conversation_id = string_field "conversation_id" fields in
      let* position_raw = string_field "position" fields in
      let* position = position_of_string position_raw in
      Ok (Conversation_counter { runtime_id; conversation_id; position })
  | _ -> Error "usage basis fields are not exact"
;;

let cursor_to_json cursor =
  `Assoc
    [ "runtime_id", `String cursor.runtime_id
    ; "conversation_id", `String cursor.conversation_id
    ; "cumulative", sample_to_json cursor.cumulative
    ]
;;

let cursor_of_json = function
  | `Assoc fields when exact_fields [ "runtime_id"; "conversation_id"; "cumulative" ] fields ->
    let* runtime_id = string_field "runtime_id" fields in
    let* conversation_id = string_field "conversation_id" fields in
    let* cumulative_json =
      match List.assoc_opt "cumulative" fields with
      | Some value -> Ok value
      | None -> Error "cumulative is required"
    in
    let* cumulative = sample_of_json cumulative_json in
    if
      cumulative.input_tokens < 0
      || cumulative.output_tokens < 0
      || cumulative.cache_creation_input_tokens < 0
      || cumulative.cache_read_input_tokens < 0
      || Option.fold
           ~none:false
           ~some:(fun cost -> cost < 0.0 || not (Float.is_finite cost))
           cumulative.cost_usd
    then Error "usage cursor cumulative sample must be non-negative and finite"
    else Ok { runtime_id; conversation_id; cumulative }
  | _ -> Error "usage cursor fields are not exact"
;;

let status_of_string = function
  | "exact" -> Ok Exact
  | "usage_missing" -> Ok Usage_missing
  | "scope_unavailable" -> Ok Scope_unavailable
  | "invalid_observation" -> Ok Invalid_observation
  | "exact_cost_unavailable" -> Ok Exact_cost_unavailable
  | "baseline_missing" -> Ok Baseline_missing
  | "counter_regressed" -> Ok Counter_regressed
  | value -> Error (Printf.sprintf "unknown usage resolution status %S" value)
;;

let validate_resolution resolution =
  let exact_shape observation delta =
    match observation, delta with
    | Some observation, Some delta
      when sample_is_valid observation && sample_is_valid delta ->
      (match resolution.basis with
       | Unavailable -> Error "exact resolution cannot have unavailable basis"
       | Per_request
       | Conversation_counter { position = Fresh; _ }
         when observation <> delta ->
         Error "fresh or per-request exact delta must equal its observation"
       | Per_request
       | Conversation_counter { position = Fresh; _ }
       | Conversation_counter { position = Resumed; _ } -> Ok ())
    | Some _, Some _ -> Error "exact resolution samples must be valid"
    | None, _ | _, None -> Error "exact resolution needs observation and delta"
  in
  match resolution.status with
  | Exact ->
    let* () = exact_shape resolution.observation resolution.delta in
    (match resolution.delta with
     | Some { cost_usd = Some _; _ } -> Ok ()
     | Some { cost_usd = None; _ } | None ->
       Error "exact resolution needs an exact cost delta")
  | Exact_cost_unavailable ->
    let* () = exact_shape resolution.observation resolution.delta in
    (match resolution.delta with
     | Some { cost_usd = None; _ } -> Ok ()
     | Some { cost_usd = Some _; _ } | None ->
       Error "exact_cost_unavailable resolution must omit cost delta")
  | Usage_missing ->
    if resolution.observation = None && resolution.delta = None
    then Ok ()
    else Error "usage_missing resolution cannot carry observation or delta"
  | Scope_unavailable ->
    (match resolution.basis, resolution.observation, resolution.delta with
     | Unavailable, Some observation, None when sample_is_valid observation -> Ok ()
     | _ -> Error "scope_unavailable resolution has contradictory fields")
  | Invalid_observation ->
    (match resolution.observation, resolution.delta with
     | Some observation, None when not (sample_is_valid observation) -> Ok ()
     | _ -> Error "invalid_observation resolution has contradictory fields")
  | Baseline_missing | Counter_regressed ->
    (match resolution.basis, resolution.observation, resolution.delta with
     | ( Conversation_counter { position = Resumed; _ }
       , Some observation
       , None )
       when sample_is_valid observation -> Ok ()
     | _ -> Error "cumulative resolution has contradictory fields")
;;

let to_json resolution =
  `Assoc
    [ ( "observation"
      , Option.fold ~none:`Null ~some:sample_to_json resolution.observation )
    ; ( "usage_scope"
      , `String
          (Runtime_usage_scope.to_string (scope_of_basis resolution.basis)) )
    ; "basis", basis_to_json resolution.basis
    ; "delta", Option.fold ~none:`Null ~some:sample_to_json resolution.delta
    ; "status", `String (status_to_string resolution.status)
    ; "observed_at", `Float resolution.observed_at
    ]
;;

let of_json = function
  | `Assoc fields
    when exact_fields
           [ "observation"; "usage_scope"; "basis"; "delta"; "status"; "observed_at" ]
           fields ->
    let optional_sample name =
      match List.assoc_opt name fields with
      | Some `Null -> Ok None
      | Some value -> Result.map Option.some (sample_of_json value)
      | None -> Error (name ^ " is required")
    in
    let* observation = optional_sample "observation" in
    let* basis_json =
      match List.assoc_opt "basis" fields with Some value -> Ok value | None -> Error "basis is required"
    in
    let* basis = basis_of_json basis_json in
    let* usage_scope_raw = string_field "usage_scope" fields in
    let* () =
      if
        String.equal
          usage_scope_raw
          (Runtime_usage_scope.to_string (scope_of_basis basis))
      then Ok ()
      else Error "usage_scope does not match usage basis"
    in
    let* delta = optional_sample "delta" in
    let* status_raw = string_field "status" fields in
    let* status = status_of_string status_raw in
    let* observed_at = float_field "observed_at" fields in
    let resolution = { observation; basis; delta; status; observed_at } in
    let* () = validate_resolution resolution in
    Ok resolution
  | _ -> Error "usage resolution fields are not exact"
;;

let subtract current previous =
  let nonnegative a b = a >= b in
  if
    not
      (nonnegative current.input_tokens previous.input_tokens
       && nonnegative current.output_tokens previous.output_tokens
       && nonnegative
            current.cache_creation_input_tokens
            previous.cache_creation_input_tokens
       && nonnegative current.cache_read_input_tokens previous.cache_read_input_tokens)
  then None
  else
    let cost_delta =
      match current.cost_usd, previous.cost_usd with
      | Some current, Some previous when current >= previous ->
        Some (Some (current -. previous), Exact)
      | None, _ | Some _, None -> Some (None, Exact_cost_unavailable)
      | Some _, Some _ -> None
    in
    Option.map
      (fun (cost_usd, status) ->
         ( { input_tokens = current.input_tokens - previous.input_tokens
           ; output_tokens = current.output_tokens - previous.output_tokens
           ; cache_creation_input_tokens =
               current.cache_creation_input_tokens
               - previous.cache_creation_input_tokens
           ; cache_read_input_tokens =
               current.cache_read_input_tokens - previous.cache_read_input_tokens
           ; cost_usd
           }
         , status ))
      cost_delta
;;

let exact_status sample =
  match sample.cost_usd with Some _ -> Exact | None -> Exact_cost_unavailable
;;

let resolve ~cursor ~basis ~observation ~observed_at =
  match observation, basis with
  | None, _ ->
    { observation; basis; delta = None; status = Usage_missing; observed_at }, cursor
  | Some sample, _ when not (sample_is_valid sample) ->
    ( { observation; basis; delta = None; status = Invalid_observation; observed_at }
    , cursor )
  | Some sample, Per_request ->
    ( { observation
      ; basis
      ; delta = Some sample
      ; status = exact_status sample
      ; observed_at
      }
    , cursor )
  | Some _, Unavailable ->
    { observation; basis; delta = None; status = Scope_unavailable; observed_at }, cursor
  | Some sample,
    Conversation_counter { runtime_id; conversation_id; position = Fresh } ->
    let cursor = Some { runtime_id; conversation_id; cumulative = sample } in
    ( { observation
      ; basis
      ; delta = Some sample
      ; status = exact_status sample
      ; observed_at
      }
    , cursor )
  | Some sample,
    Conversation_counter { runtime_id; conversation_id; position = Resumed } ->
    let next_cursor = Some { runtime_id; conversation_id; cumulative = sample } in
    (match cursor with
     | Some previous
       when String.equal previous.runtime_id runtime_id
            && String.equal previous.conversation_id conversation_id ->
       (match subtract sample previous.cumulative with
        | Some (delta, status) ->
          { observation; basis; delta = Some delta; status; observed_at }, next_cursor
        | None ->
          ( { observation; basis; delta = None; status = Counter_regressed; observed_at }
          , cursor ))
     | Some _ | None ->
       ( { observation; basis; delta = None; status = Baseline_missing; observed_at }
       , next_cursor ))
;;
