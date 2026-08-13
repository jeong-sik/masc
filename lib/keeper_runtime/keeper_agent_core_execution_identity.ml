type candidate_attempt =
  | Lane_head
  | Lane_fallback of { ordinal : int }

type context_attempt =
  | Initial_context of { capacity_bytes : int }
  | Context_shrink of
      { ordinal : int
      ; capacity_bytes : int
      }

type thinking_attempt =
  | Runtime_thinking_policy
  | Force_thinking
  | Force_no_thinking

type error =
  | Invalid_keeper_name of string
  | Invalid_trace_id of string
  | Invalid_runtime_id of string
  | Non_positive_keeper_turn_id of int
  | Negative_candidate_attempt of int
  | Negative_context_shrink_attempt of int
  | Non_positive_context_capacity of int

type operation_id_error =
  | Invalid_operation_id_prefix
  | Invalid_operation_id_digest_length
  | Invalid_operation_id_digest_character

type decoding_error =
  | Identity_not_object
  | Identity_fields_invalid
  | Unsupported_schema_version of int
  | Candidate_attempt_invalid
  | Context_attempt_invalid
  | Thinking_attempt_invalid
  | Identity_value_invalid of error

type operation_id = string

type t =
  { keeper_name : string
  ; trace_id : string
  ; keeper_turn_id : int
  ; runtime_id : string
  ; candidate_attempt : candidate_attempt
  ; context_attempt : context_attempt
  ; thinking_attempt : thinking_attempt
  ; operation_id : operation_id
  }

let operation_id_prefix = "keeper-agent-core-v1-"

let exact_fields expected fields =
  List.length fields = List.length expected
  && List.for_all
       (fun expected_name ->
          List.length
            (List.filter
               (fun (actual_name, _) -> String.equal expected_name actual_name)
               fields)
          = 1)
       expected
;;

let bounded_preview value =
  if String.length value <= 32
  then value
  else Printf.sprintf "%s...(%d bytes)" (String.sub value 0 32) (String.length value)
;;

let is_portable_name value =
  let length = String.length value in
  length > 0
  && not (String.equal value "." || String.equal value "..")
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true
         | _ -> false)
       value
;;

let is_trace_id value =
  let length = String.length value in
  length > 0
  && length <= 64
  && not (String.equal value "." || String.equal value "..")
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
         | _ -> false)
       value
;;

let candidate_attempt_to_yojson = function
  | Lane_head -> `Assoc [ "kind", `String "lane_head" ]
  | Lane_fallback { ordinal } ->
    `Assoc [ "kind", `String "lane_fallback"; "ordinal", `Int ordinal ]
;;

let context_attempt_to_yojson = function
  | Initial_context { capacity_bytes } ->
    `Assoc
      [ "kind", `String "initial_context"; "capacity_bytes", `Int capacity_bytes ]
  | Context_shrink { ordinal; capacity_bytes } ->
    `Assoc
      [ "kind", `String "context_shrink"
      ; "ordinal", `Int ordinal
      ; "capacity_bytes", `Int capacity_bytes
      ]
;;

let thinking_attempt_to_yojson = function
  | Runtime_thinking_policy -> `String "runtime_policy"
  | Force_thinking -> `String "force_thinking"
  | Force_no_thinking -> `String "force_no_thinking"
;;

let identity_json
      ~keeper_name
      ~trace_id
      ~keeper_turn_id
      ~runtime_id
      ~candidate_attempt
      ~context_attempt
      ~thinking_attempt
  =
  `Assoc
    [ "schema_version", `Int 1
    ; "keeper_name", `String keeper_name
    ; "trace_id", `String trace_id
    ; "keeper_turn_id", `Int keeper_turn_id
    ; "runtime_id", `String runtime_id
    ; "candidate_attempt", candidate_attempt_to_yojson candidate_attempt
    ; "context_attempt", context_attempt_to_yojson context_attempt
    ; "thinking_attempt", thinking_attempt_to_yojson thinking_attempt
    ]
;;

let create
      ~keeper_name
      ~trace_id
      ~keeper_turn_id
      ~runtime_id
      ~candidate_index
      ~context_shrink_attempt
      ~context_capacity_bytes
      ~thinking_override
  =
  if not (is_portable_name keeper_name)
  then Error (Invalid_keeper_name (bounded_preview keeper_name))
  else if not (is_trace_id trace_id)
  then Error (Invalid_trace_id (bounded_preview trace_id))
  else if not (is_portable_name runtime_id)
  then Error (Invalid_runtime_id (bounded_preview runtime_id))
  else if keeper_turn_id <= 0
  then Error (Non_positive_keeper_turn_id keeper_turn_id)
  else if candidate_index < 0
  then Error (Negative_candidate_attempt candidate_index)
  else if context_shrink_attempt < 0
  then Error (Negative_context_shrink_attempt context_shrink_attempt)
  else if context_capacity_bytes <= 0
  then Error (Non_positive_context_capacity context_capacity_bytes)
  else
    let candidate_attempt =
      if candidate_index = 0
      then Lane_head
      else Lane_fallback { ordinal = candidate_index }
    in
    let context_attempt =
      if context_shrink_attempt = 0
      then Initial_context { capacity_bytes = context_capacity_bytes }
      else
        Context_shrink
          { ordinal = context_shrink_attempt
          ; capacity_bytes = context_capacity_bytes
          }
    in
    let thinking_attempt =
      match thinking_override with
      | None -> Runtime_thinking_policy
      | Some true -> Force_thinking
      | Some false -> Force_no_thinking
    in
    let canonical =
      identity_json
        ~keeper_name
        ~trace_id
        ~keeper_turn_id
        ~runtime_id
        ~candidate_attempt
        ~context_attempt
        ~thinking_attempt
      |> Yojson.Safe.to_string
    in
    let operation_id =
      operation_id_prefix ^ Digestif.SHA256.(digest_string canonical |> to_hex)
    in
    Ok
      { keeper_name
      ; trace_id
      ; keeper_turn_id
      ; runtime_id
      ; candidate_attempt
      ; context_attempt
      ; thinking_attempt
      ; operation_id
      }
;;

let operation_id operation = operation.operation_id
let operation_id_to_string operation_id = operation_id

let operation_id_of_string value =
  let prefix_length = String.length operation_id_prefix in
  if
    String.length value < prefix_length
    || not (String.equal (String.sub value 0 prefix_length) operation_id_prefix)
  then Error Invalid_operation_id_prefix
  else
    let digest =
      String.sub value prefix_length (String.length value - prefix_length)
    in
    if String.length digest <> 64
    then Error Invalid_operation_id_digest_length
    else if
      not
        (String.for_all
           (function
             | '0' .. '9' | 'a' .. 'f' -> true
             | _ -> false)
           digest)
    then Error Invalid_operation_id_digest_character
    else Ok value
;;

let to_yojson operation =
  identity_json
    ~keeper_name:operation.keeper_name
    ~trace_id:operation.trace_id
    ~keeper_turn_id:operation.keeper_turn_id
    ~runtime_id:operation.runtime_id
    ~candidate_attempt:operation.candidate_attempt
    ~context_attempt:operation.context_attempt
    ~thinking_attempt:operation.thinking_attempt
;;

let candidate_index_of_yojson = function
  | `Assoc fields when exact_fields [ "kind" ] fields ->
    (match List.assoc "kind" fields with
     | `String "lane_head" -> Ok 0
     | _ -> Error Candidate_attempt_invalid)
  | `Assoc fields when exact_fields [ "kind"; "ordinal" ] fields ->
    (match List.assoc "kind" fields, List.assoc "ordinal" fields with
     | `String "lane_fallback", `Int ordinal when ordinal > 0 -> Ok ordinal
     | _ -> Error Candidate_attempt_invalid)
  | _ -> Error Candidate_attempt_invalid
;;

let context_attempt_of_yojson = function
  | `Assoc fields when exact_fields [ "kind"; "capacity_bytes" ] fields ->
    (match List.assoc "kind" fields, List.assoc "capacity_bytes" fields with
     | `String "initial_context", `Int capacity_bytes when capacity_bytes > 0 ->
       Ok (0, capacity_bytes)
     | _ -> Error Context_attempt_invalid)
  | `Assoc fields
    when exact_fields [ "kind"; "ordinal"; "capacity_bytes" ] fields ->
    (match
       List.assoc "kind" fields,
       List.assoc "ordinal" fields,
       List.assoc "capacity_bytes" fields
     with
     | `String "context_shrink", `Int ordinal, `Int capacity_bytes
       when ordinal > 0 && capacity_bytes > 0 -> Ok (ordinal, capacity_bytes)
     | _ -> Error Context_attempt_invalid)
  | _ -> Error Context_attempt_invalid
;;

let thinking_override_of_yojson = function
  | `String "runtime_policy" -> Ok None
  | `String "force_thinking" -> Ok (Some true)
  | `String "force_no_thinking" -> Ok (Some false)
  | _ -> Error Thinking_attempt_invalid
;;

let of_yojson = function
  | `Assoc fields
    when exact_fields
           [ "schema_version"
           ; "keeper_name"
           ; "trace_id"
           ; "keeper_turn_id"
           ; "runtime_id"
           ; "candidate_attempt"
           ; "context_attempt"
           ; "thinking_attempt"
           ]
           fields ->
    (match List.assoc "schema_version" fields with
     | `Int version when version <> 1 -> Error (Unsupported_schema_version version)
     | `Int 1 ->
       (match
          List.assoc "keeper_name" fields,
          List.assoc "trace_id" fields,
          List.assoc "keeper_turn_id" fields,
          List.assoc "runtime_id" fields
        with
        | `String keeper_name, `String trace_id, `Int keeper_turn_id, `String runtime_id
          ->
          let ( let* ) = Result.bind in
          let* candidate_index =
            candidate_index_of_yojson (List.assoc "candidate_attempt" fields)
          in
          let* context_shrink_attempt, context_capacity_bytes =
            context_attempt_of_yojson (List.assoc "context_attempt" fields)
          in
          let* thinking_override =
            thinking_override_of_yojson (List.assoc "thinking_attempt" fields)
          in
          create
            ~keeper_name
            ~trace_id
            ~keeper_turn_id
            ~runtime_id
            ~candidate_index
            ~context_shrink_attempt
            ~context_capacity_bytes
            ~thinking_override
          |> Result.map_error (fun error -> Identity_value_invalid error)
        | _ -> Error Identity_fields_invalid)
     | _ -> Error Identity_fields_invalid)
  | `Assoc _ -> Error Identity_fields_invalid
  | _ -> Error Identity_not_object
;;

let error_to_string = function
  | Invalid_keeper_name value ->
    Printf.sprintf "invalid keeper name %S" value
  | Invalid_trace_id value ->
    Printf.sprintf "invalid trace id %S" value
  | Invalid_runtime_id value ->
    Printf.sprintf "invalid runtime id %S" value
  | Non_positive_keeper_turn_id value ->
    Printf.sprintf "keeper turn id must be positive, received %d" value
  | Negative_candidate_attempt value ->
    Printf.sprintf "runtime candidate index must be non-negative, received %d" value
  | Negative_context_shrink_attempt value ->
    Printf.sprintf "context shrink attempt must be non-negative, received %d" value
  | Non_positive_context_capacity value ->
    Printf.sprintf "context capacity must be positive, received %d" value
;;
