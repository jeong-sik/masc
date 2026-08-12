module Intent_id = struct
  type t = string

  let prefix = "kdelivery-"
  let digest_length = 64

  let is_lower_hex = function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false
  ;;

  let of_string value =
    let prefix_length = String.length prefix in
    let expected_length = prefix_length + digest_length in
    if String.length value <> expected_length
    then Error (Printf.sprintf "delivery intent id must be %d bytes" expected_length)
    else if not (String.starts_with ~prefix value)
    then Error "delivery intent id has an unsupported prefix"
    else
      let rec validate index =
        if index = expected_length
        then Ok value
        else if is_lower_hex value.[index]
        then validate (index + 1)
        else Error "delivery intent id digest must be lowercase hexadecimal"
      in
      validate prefix_length
  ;;

  let to_string value = value
  let equal = String.equal
end

type source_identity =
  | Fusion_completion of { run_id : string }
  | Hitl_resolution of { approval_id : string }
  | Connector_attention of { event_id : string }
  | Schedule_occurrence of { occurrence_id : string }

type origin =
  { source : source_identity
  ; channel : Keeper_continuation_channel.t
  }

type failure_kind =
  | Adapter_rejected
  | Retry_exhausted
  | Persistence_failed

type state =
  | Pending
  | Attempting of
      { started_at : float
      ; idempotency_key : string
      }
  | Delivered of
      { completed_at : float
      ; connector_message_id : string option
      }
  | Failed of
      { completed_at : float
      ; kind : failure_kind
      ; detail : string
      }
  | Ambiguous of
      { detected_at : float
      ; detail : string
      }

type response =
  { text : string
  ; sha256 : string
  }

type t =
  { schema_version : int
  ; intent_id : Intent_id.t
  ; keeper_name : string
  ; keeper_turn_id : int
  ; origin : origin
  ; response : response
  ; state : state
  }

type error =
  | Invalid_source of string
  | Unroutable_channel of string
  | Invalid_keeper_name of string
  | Invalid_keeper_turn_id of int
  | Invalid_response of string
  | Invalid_timestamp of string
  | Invalid_transition of string
  | Decode_failed of string
  | Identity_mismatch of
      { encoded : string
      ; derived : string
      }
  | Response_digest_mismatch of
      { encoded : string
      ; derived : string
      }

type replay_classification =
  | Distinct_identity
  | Exact_replay
  | Identity_conflict

let schema_version = 1
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_source detail -> "invalid continuation delivery source: " ^ detail
  | Unroutable_channel detail ->
    "unroutable continuation delivery channel: " ^ detail
  | Invalid_keeper_name detail ->
    "invalid continuation delivery keeper name: " ^ detail
  | Invalid_keeper_turn_id turn_id ->
    Printf.sprintf "invalid continuation delivery keeper turn id: %d" turn_id
  | Invalid_response detail ->
    "invalid continuation delivery response: " ^ detail
  | Invalid_timestamp detail ->
    "invalid continuation delivery timestamp: " ^ detail
  | Invalid_transition detail ->
    "invalid continuation delivery transition: " ^ detail
  | Decode_failed detail -> "continuation delivery decode failed: " ^ detail
  | Identity_mismatch { encoded; derived } ->
    Printf.sprintf
      "continuation delivery identity mismatch: encoded=%s derived=%s"
      encoded
      derived
  | Response_digest_mismatch { encoded; derived } ->
    Printf.sprintf
      "continuation delivery response digest mismatch: encoded=%s derived=%s"
      encoded
      derived
;;

let validate_utf8 ~error field value =
  if String.is_valid_utf_8 value
  then Ok value
  else Error (error (field ^ " contains malformed UTF-8"))
;;

let validate_nonblank ~error field value =
  let* value = validate_utf8 ~error field value in
  if String.equal (String.trim value) ""
  then Error (error (field ^ " must not be blank"))
  else Ok value
;;

let validate_source = function
  | Fusion_completion { run_id } ->
    validate_nonblank ~error:(fun detail -> Invalid_source detail) "run_id" run_id
    |> Result.map (fun _ -> ())
  | Hitl_resolution { approval_id } ->
    validate_nonblank
      ~error:(fun detail -> Invalid_source detail)
      "approval_id"
      approval_id
    |> Result.map (fun _ -> ())
  | Connector_attention { event_id } ->
    validate_nonblank
      ~error:(fun detail -> Invalid_source detail)
      "event_id"
      event_id
    |> Result.map (fun _ -> ())
  | Schedule_occurrence { occurrence_id } ->
    validate_nonblank
      ~error:(fun detail -> Invalid_source detail)
      "occurrence_id"
      occurrence_id
    |> Result.map (fun _ -> ())
;;

let make_origin source channel =
  let* () = validate_source source in
  if Keeper_continuation_channel.is_routable channel
  then Ok { source; channel }
  else
    Error
      (Unroutable_channel (Keeper_continuation_channel.describe channel))
;;

let fusion_origin ~run_id channel =
  make_origin (Fusion_completion { run_id }) channel
;;

let hitl_origin ~approval_id channel =
  make_origin (Hitl_resolution { approval_id }) channel
;;

let connector_attention_origin ~event_id channel =
  make_origin (Connector_attention { event_id }) channel
;;

let schedule_origin ~occurrence_id channel =
  make_origin (Schedule_occurrence { occurrence_id }) channel
;;

let origin_of_payload = function
  | Keeper_event_queue.Fusion_completed completion ->
    fusion_origin ~run_id:completion.run_id completion.channel
    |> Result.map Option.some
  | Keeper_event_queue.Hitl_resolved resolution ->
    hitl_origin ~approval_id:resolution.approval_id resolution.channel
    |> Result.map Option.some
  | Keeper_event_queue.Connector_attention attention ->
    connector_attention_origin ~event_id:attention.event_id attention.channel
    |> Result.map Option.some
  | Keeper_event_queue.Schedule_due wake ->
    (match wake.result_delivery with
     | None -> Ok None
     | Some channel ->
       schedule_origin ~occurrence_id:wake.occurrence_id channel
       |> Result.map Option.some)
  | Keeper_event_queue.Board_signal _
  | Keeper_event_queue.Board_attention _
  | Keeper_event_queue.Bootstrap
  | Keeper_event_queue.Manual_compaction_requested
  | Keeper_event_queue.Goal_assigned _
  | Keeper_event_queue.Goal_reconciliation_ready _
  | Keeper_event_queue.Completion_authority_rejected _
  | Keeper_event_queue.Task_cancelled _ ->
    Ok None
;;

let source_to_yojson = function
  | Fusion_completion { run_id } ->
    `Assoc [ "kind", `String "fusion_completion"; "run_id", `String run_id ]
  | Hitl_resolution { approval_id } ->
    `Assoc
      [ "kind", `String "hitl_resolution"
      ; "approval_id", `String approval_id
      ]
  | Connector_attention { event_id } ->
    `Assoc
      [ "kind", `String "connector_attention"; "event_id", `String event_id ]
  | Schedule_occurrence { occurrence_id } ->
    `Assoc
      [ "kind", `String "schedule_occurrence"
      ; "occurrence_id", `String occurrence_id
      ]
;;

let sha256 value = Digestif.SHA256.(to_hex (digest_string value))

let derive_intent_id ~keeper_name source =
  let canonical_source = Yojson.Safe.to_string (source_to_yojson source) in
  Intent_id.of_string
    ("kdelivery-" ^ sha256 (keeper_name ^ "\x1f" ^ canonical_source))
  |> Result.map_error (fun detail ->
    Invalid_source ("derived continuation delivery identity is invalid: " ^ detail))
;;

let validate_keeper_name keeper_name =
  Keeper_id.Keeper_name.of_string keeper_name
  |> Result.map (fun _ -> ())
  |> Result.map_error (fun detail -> Invalid_keeper_name detail)
;;

let validate_response_text text =
  let* text =
    validate_nonblank
      ~error:(fun detail -> Invalid_response detail)
      "response_text"
      text
  in
  if String.equal text (String.trim text)
  then Ok text
  else Error (Invalid_response "response_text must not have surrounding whitespace")
;;

let intent_id_for_origin ~keeper_name origin =
  let* () = validate_keeper_name keeper_name in
  let* () = validate_source origin.source in
  if Keeper_continuation_channel.is_routable origin.channel
  then derive_intent_id ~keeper_name origin.source
  else
    Error
      (Unroutable_channel
         (Keeper_continuation_channel.describe origin.channel))
;;

let create ~keeper_name ~keeper_turn_id ~origin ~response_text =
  let* intent_id = intent_id_for_origin ~keeper_name origin in
  if keeper_turn_id <= 0
  then Error (Invalid_keeper_turn_id keeper_turn_id)
  else
    let* text = validate_response_text response_text in
    let response = { text; sha256 = sha256 text } in
    Ok
      { schema_version
      ; intent_id
      ; keeper_name
      ; keeper_turn_id
      ; origin
      ; response
      ; state = Pending
      }
;;

let validate_timestamp field value =
  if Float.is_finite value && value >= 0.0
  then Ok ()
  else Error (Invalid_timestamp (field ^ " must be finite and non-negative"))
;;

let validate_detail field detail =
  validate_nonblank
    ~error:(fun message -> Invalid_transition message)
    field
    detail
  |> Result.map (fun _ -> ())
;;

let start_attempt ~started_at intent =
  let* () = validate_timestamp "started_at" started_at in
  match intent.state with
  | Pending ->
    Ok
      { intent with
        state =
          Attempting
            { started_at
            ; idempotency_key = Intent_id.to_string intent.intent_id
            }
      }
  | Attempting _ | Delivered _ | Failed _ | Ambiguous _ ->
    Error
      (Invalid_transition
         (Printf.sprintf
            "start_attempt requires pending, found %s"
            (match intent.state with
             | Pending -> "pending"
             | Attempting _ -> "attempting"
             | Delivered _ -> "delivered"
             | Failed _ -> "failed"
             | Ambiguous _ -> "ambiguous")))
;;

let validate_optional_connector_message_id = function
  | None -> Ok ()
  | Some value ->
    validate_nonblank
      ~error:(fun detail -> Invalid_transition detail)
      "connector_message_id"
      value
    |> Result.map (fun _ -> ())
;;

let mark_delivered ~completed_at ?connector_message_id intent =
  let* () = validate_timestamp "completed_at" completed_at in
  let* () = validate_optional_connector_message_id connector_message_id in
  match intent.state with
  | Attempting _ ->
    Ok { intent with state = Delivered { completed_at; connector_message_id } }
  | Pending | Delivered _ | Failed _ | Ambiguous _ ->
    Error
      (Invalid_transition
         (Printf.sprintf
            "mark_delivered requires attempting, found %s"
            (match intent.state with
             | Pending -> "pending"
             | Attempting _ -> "attempting"
             | Delivered _ -> "delivered"
             | Failed _ -> "failed"
             | Ambiguous _ -> "ambiguous")))
;;

let mark_failed ~completed_at ~kind ~detail intent =
  let* () = validate_timestamp "completed_at" completed_at in
  let* () = validate_detail "failure detail" detail in
  match intent.state with
  | Pending | Attempting _ ->
    Ok { intent with state = Failed { completed_at; kind; detail } }
  | Delivered _ | Failed _ | Ambiguous _ ->
    Error
      (Invalid_transition
         (Printf.sprintf
            "mark_failed requires pending or attempting, found %s"
            (match intent.state with
             | Pending -> "pending"
             | Attempting _ -> "attempting"
             | Delivered _ -> "delivered"
             | Failed _ -> "failed"
             | Ambiguous _ -> "ambiguous")))
;;

let mark_ambiguous ~detected_at ~detail intent =
  let* () = validate_timestamp "detected_at" detected_at in
  let* () = validate_detail "ambiguity detail" detail in
  match intent.state with
  | Attempting _ -> Ok { intent with state = Ambiguous { detected_at; detail } }
  | Pending | Delivered _ | Failed _ | Ambiguous _ ->
    Error
      (Invalid_transition
         (Printf.sprintf
            "mark_ambiguous requires attempting, found %s"
            (match intent.state with
             | Pending -> "pending"
             | Attempting _ -> "attempting"
             | Delivered _ -> "delivered"
             | Failed _ -> "failed"
             | Ambiguous _ -> "ambiguous")))
;;

let source_equal left right =
  match left, right with
  | Fusion_completion left, Fusion_completion right ->
    String.equal left.run_id right.run_id
  | Hitl_resolution left, Hitl_resolution right ->
    String.equal left.approval_id right.approval_id
  | Connector_attention left, Connector_attention right ->
    String.equal left.event_id right.event_id
  | Schedule_occurrence left, Schedule_occurrence right ->
    String.equal left.occurrence_id right.occurrence_id
  | (Fusion_completion _ | Hitl_resolution _ | Connector_attention _ | Schedule_occurrence _),
    (Fusion_completion _ | Hitl_resolution _ | Connector_attention _ | Schedule_occurrence _) ->
    false
;;

let same_source left right = source_equal left.source right.source

let same_origin left right =
  same_source left right
  && Keeper_continuation_channel.same_route left.channel right.channel
;;

let immutable_equal left right =
  String.equal left.keeper_name right.keeper_name
  && Int.equal left.keeper_turn_id right.keeper_turn_id
  && source_equal left.origin.source right.origin.source
  && Keeper_continuation_channel.same_route
       left.origin.channel
       right.origin.channel
  && String.equal left.response.text right.response.text
  && String.equal left.response.sha256 right.response.sha256
;;

let classify_replay ~existing ~incoming =
  if not (Intent_id.equal existing.intent_id incoming.intent_id)
  then Distinct_identity
  else if immutable_equal existing incoming
  then Exact_replay
  else Identity_conflict
;;

let state_label = function
  | Pending -> "pending"
  | Attempting _ -> "attempting"
  | Delivered _ -> "delivered"
  | Failed _ -> "failed"
  | Ambiguous _ -> "ambiguous"
;;

let failure_kind_to_string = function
  | Adapter_rejected -> "adapter_rejected"
  | Retry_exhausted -> "retry_exhausted"
  | Persistence_failed -> "persistence_failed"
;;

let failure_kind_of_string = function
  | "adapter_rejected" -> Ok Adapter_rejected
  | "retry_exhausted" -> Ok Retry_exhausted
  | "persistence_failed" -> Ok Persistence_failed
  | value -> Error (Decode_failed (Printf.sprintf "unknown failure kind %S" value))
;;

let state_to_yojson = function
  | Pending -> `Assoc [ "kind", `String "pending" ]
  | Attempting { started_at; idempotency_key } ->
    `Assoc
      [ "kind", `String "attempting"
      ; "started_at", `Float started_at
      ; "idempotency_key", `String idempotency_key
      ]
  | Delivered { completed_at; connector_message_id } ->
    `Assoc
      [ "kind", `String "delivered"
      ; "completed_at", `Float completed_at
      ; ( "connector_message_id"
        , match connector_message_id with
          | None -> `Null
          | Some value -> `String value )
      ]
  | Failed { completed_at; kind; detail } ->
    `Assoc
      [ "kind", `String "failed"
      ; "completed_at", `Float completed_at
      ; "failure_kind", `String (failure_kind_to_string kind)
      ; "detail", `String detail
      ]
  | Ambiguous { detected_at; detail } ->
    `Assoc
      [ "kind", `String "ambiguous"
      ; "detected_at", `Float detected_at
      ; "detail", `String detail
      ]
;;

let to_yojson intent =
  `Assoc
    [ "schema_version", `Int intent.schema_version
    ; "intent_id", `String (Intent_id.to_string intent.intent_id)
    ; "keeper_name", `String intent.keeper_name
    ; "keeper_turn_id", `Int intent.keeper_turn_id
    ; "source", source_to_yojson intent.origin.source
    ; "channel", Keeper_continuation_channel.to_yojson intent.origin.channel
    ; ( "response"
      , `Assoc
          [ "text", `String intent.response.text
          ; "sha256", `String intent.response.sha256
          ] )
    ; "state", state_to_yojson intent.state
    ]
;;

let validate_fields ~context ~expected fields =
  let rec loop seen = function
    | [] ->
      (match List.find_opt (fun name -> not (List.mem name seen)) expected with
       | None -> Ok ()
       | Some name ->
         Error (Decode_failed (Printf.sprintf "%s missing field %S" context name)))
    | (name, _) :: rest ->
      if List.mem name seen
      then
        Error (Decode_failed (Printf.sprintf "%s duplicate field %S" context name))
      else if not (List.mem name expected)
      then Error (Decode_failed (Printf.sprintf "%s unknown field %S" context name))
      else loop (name :: seen) rest
  in
  loop [] fields
;;

let field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Decode_failed (Printf.sprintf "missing field %S" name))
;;

let string_field name fields =
  let* value = field name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error (Decode_failed (Printf.sprintf "field %S must be a string" name))
;;

let int_field name fields =
  let* value = field name fields in
  match value with
  | `Int value -> Ok value
  | _ -> Error (Decode_failed (Printf.sprintf "field %S must be an integer" name))
;;

let float_field name fields =
  let* value = field name fields in
  match value with
  | `Float value -> Ok value
  | `Int value -> Ok (Float.of_int value)
  | _ -> Error (Decode_failed (Printf.sprintf "field %S must be numeric" name))
;;

let source_of_yojson = function
  | `Assoc fields ->
    let* kind = string_field "kind" fields in
    let* source =
      match kind with
      | "fusion_completion" ->
        let* () =
          validate_fields
            ~context:"Fusion continuation source"
            ~expected:[ "kind"; "run_id" ]
            fields
        in
        let* run_id = string_field "run_id" fields in
        Ok (Fusion_completion { run_id })
      | "hitl_resolution" ->
        let* () =
          validate_fields
            ~context:"HITL continuation source"
            ~expected:[ "kind"; "approval_id" ]
            fields
        in
        let* approval_id = string_field "approval_id" fields in
        Ok (Hitl_resolution { approval_id })
      | "connector_attention" ->
        let* () =
          validate_fields
            ~context:"connector-attention continuation source"
            ~expected:[ "kind"; "event_id" ]
            fields
        in
        let* event_id = string_field "event_id" fields in
        Ok (Connector_attention { event_id })
      | "schedule_occurrence" ->
        let* () =
          validate_fields
            ~context:"schedule-occurrence continuation source"
            ~expected:[ "kind"; "occurrence_id" ]
            fields
        in
        let* occurrence_id = string_field "occurrence_id" fields in
        Ok (Schedule_occurrence { occurrence_id })
      | value ->
        Error
          (Decode_failed
             (Printf.sprintf "unknown continuation source kind %S" value))
    in
    let* () = validate_source source in
    Ok source
  | _ -> Error (Decode_failed "continuation source must be an object")
;;

let response_of_yojson = function
  | `Assoc fields ->
    let* () =
      validate_fields
        ~context:"continuation response"
        ~expected:[ "text"; "sha256" ]
        fields
    in
    let* text = string_field "text" fields in
    let* encoded_sha256 = string_field "sha256" fields in
    let* text = validate_response_text text in
    let derived_sha256 = sha256 text in
    if String.equal encoded_sha256 derived_sha256
    then Ok { text; sha256 = encoded_sha256 }
    else
      Error
        (Response_digest_mismatch
           { encoded = encoded_sha256; derived = derived_sha256 })
  | _ -> Error (Decode_failed "continuation response must be an object")
;;

let optional_string_field name fields =
  let* value = field name fields in
  match value with
  | `Null -> Ok None
  | `String value -> Ok (Some value)
  | _ ->
    Error
      (Decode_failed (Printf.sprintf "field %S must be a string or null" name))
;;

let state_of_yojson ~intent_id = function
  | `Assoc fields ->
    let* kind = string_field "kind" fields in
    (match kind with
     | "pending" ->
       let* () =
         validate_fields ~context:"pending delivery state" ~expected:[ "kind" ] fields
       in
       Ok Pending
     | "attempting" ->
       let* () =
         validate_fields
           ~context:"attempting delivery state"
           ~expected:[ "kind"; "started_at"; "idempotency_key" ]
           fields
       in
       let* started_at = float_field "started_at" fields in
       let* () = validate_timestamp "started_at" started_at in
       let* idempotency_key = string_field "idempotency_key" fields in
       if not (String.equal idempotency_key (Intent_id.to_string intent_id))
       then Error (Decode_failed "attempting idempotency_key must equal intent_id")
       else Ok (Attempting { started_at; idempotency_key })
     | "delivered" ->
       let* () =
         validate_fields
           ~context:"delivered delivery state"
           ~expected:[ "kind"; "completed_at"; "connector_message_id" ]
           fields
       in
       let* completed_at = float_field "completed_at" fields in
       let* () = validate_timestamp "completed_at" completed_at in
       let* connector_message_id = optional_string_field "connector_message_id" fields in
       let* () = validate_optional_connector_message_id connector_message_id in
       Ok (Delivered { completed_at; connector_message_id })
     | "failed" ->
       let* () =
         validate_fields
           ~context:"failed delivery state"
           ~expected:[ "kind"; "completed_at"; "failure_kind"; "detail" ]
           fields
       in
       let* completed_at = float_field "completed_at" fields in
       let* () = validate_timestamp "completed_at" completed_at in
       let* failure_kind = string_field "failure_kind" fields in
       let* kind = failure_kind_of_string failure_kind in
       let* detail = string_field "detail" fields in
       let* () = validate_detail "failure detail" detail in
       Ok (Failed { completed_at; kind; detail })
     | "ambiguous" ->
       let* () =
         validate_fields
           ~context:"ambiguous delivery state"
           ~expected:[ "kind"; "detected_at"; "detail" ]
           fields
       in
       let* detected_at = float_field "detected_at" fields in
       let* () = validate_timestamp "detected_at" detected_at in
       let* detail = string_field "detail" fields in
       let* () = validate_detail "ambiguity detail" detail in
       Ok (Ambiguous { detected_at; detail })
     | value ->
       Error (Decode_failed (Printf.sprintf "unknown delivery state %S" value)))
  | _ -> Error (Decode_failed "continuation delivery state must be an object")
;;

let of_yojson = function
  | `Assoc fields ->
    let* () =
      validate_fields
        ~context:"continuation delivery intent"
        ~expected:
          [ "schema_version"
          ; "intent_id"
          ; "keeper_name"
          ; "keeper_turn_id"
          ; "source"
          ; "channel"
          ; "response"
          ; "state"
          ]
        fields
    in
    let* encoded_schema_version = int_field "schema_version" fields in
    if encoded_schema_version <> schema_version
    then
      Error
        (Decode_failed
           (Printf.sprintf
              "unsupported continuation delivery schema version %d"
              encoded_schema_version))
    else
      let* encoded_intent_id = string_field "intent_id" fields in
      let* intent_id =
        Intent_id.of_string encoded_intent_id
        |> Result.map_error (fun detail -> Decode_failed detail)
      in
      let* keeper_name = string_field "keeper_name" fields in
      let* () = validate_keeper_name keeper_name in
      let* keeper_turn_id = int_field "keeper_turn_id" fields in
      if keeper_turn_id <= 0
      then Error (Invalid_keeper_turn_id keeper_turn_id)
      else
        let* source_json = field "source" fields in
        let* source = source_of_yojson source_json in
        let* channel_json = field "channel" fields in
        let* channel =
          Keeper_continuation_channel.of_yojson channel_json
          |> Result.map_error (fun detail -> Decode_failed detail)
        in
        let* origin = make_origin source channel in
        let* derived_intent_id =
          derive_intent_id ~keeper_name source
          |> Result.map_error (fun error -> Decode_failed (error_to_string error))
        in
        if not (Intent_id.equal intent_id derived_intent_id)
        then
          Error
            (Identity_mismatch
               { encoded = Intent_id.to_string intent_id
               ; derived = Intent_id.to_string derived_intent_id
               })
        else
          let* response_json = field "response" fields in
          let* response = response_of_yojson response_json in
          let* state_json = field "state" fields in
          let* state = state_of_yojson ~intent_id state_json in
          Ok
            { schema_version
            ; intent_id
            ; keeper_name
            ; keeper_turn_id
            ; origin
            ; response
            ; state
            }
  | _ -> Error (Decode_failed "continuation delivery intent must be an object")
;;
