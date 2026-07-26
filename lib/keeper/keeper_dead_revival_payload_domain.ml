open Keeper_dead_revival_payload_types

let payload_schema = "masc.keeper-dead-revival-payload.v1"
let ref_schema = "masc.keeper-dead-revival-payload-ref.v1"
let transaction_domain = "keeper-dead-revival-transaction-v1"
let payload_digest_domain = "masc.keeper-dead-revival-payload-digest.v1"
let transaction_leaf_domain =
  "masc.keeper-dead-revival-payload-transaction-leaf.v1"
;;

let authority_leaf_domain = "keeper-dead-revival-journal-leaf-v1"
let payload_root_leaf = "payloads"
let authority_leaf_prefix = "revival-"
let transaction_leaf_prefix = "transaction-"
let json_leaf_suffix = ".json"

let ( let* ) result fn =
  match result with
  | Ok value -> fn value
  | Error error -> Error error
;;

let sha256 value =
  Digestif.SHA256.(digest_string value |> to_hex)
;;

let length_delimited value =
  Printf.sprintf "%d:%s" (String.length value) value
;;

let domain_digest domain values =
  domain :: values
  |> List.map length_delimited
  |> String.concat "\000"
  |> sha256
;;

let is_lowercase_sha256 value =
  match Digestif.SHA256.consistent_of_hex_opt value with
  | Some digest -> String.equal value (Digestif.SHA256.to_hex digest)
  | None -> false
;;

let exact_fields ~kind expected = function
  | `Assoc fields ->
    let expected = List.sort String.compare expected in
    let observed =
      List.map fst fields
      |> List.sort String.compare
    in
    if List.equal String.equal expected observed
    then Ok fields
    else
      Error
        (Printf.sprintf
           "%s fields differ expected=[%s] observed=[%s]"
           kind
           (String.concat "," expected)
           (String.concat "," observed))
  | _ -> Error (kind ^ " must be a JSON object")
;;

let required_field ~kind key fields =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s field %s is missing" kind key)
;;

let required_string ~kind key fields =
  let* value = required_field ~kind key fields in
  match value with
  | `String value when not (String.equal (String.trim value) "") -> Ok value
  | _ ->
    Error
      (Printf.sprintf
         "%s field %s must be a non-empty string"
         kind
         key)
;;

let required_int ~kind key fields =
  let* value = required_field ~kind key fields in
  match value with
  | `Int value -> Ok value
  | _ -> Error (Printf.sprintf "%s field %s must be an integer" kind key)
;;

let required_positive_int64 ~kind key fields =
  let* value = required_field ~kind key fields in
  match value with
  | `Int value when value > 0 -> Ok (Int64.of_int value)
  | `Intlit raw ->
    (match Int64.of_string_opt raw with
     | Some value
       when Int64.compare value 0L > 0
            && String.equal raw (Int64.to_string value) ->
       Ok value
     | Some _ | None ->
       Error
         (Printf.sprintf
            "%s field %s must be a canonical positive int64"
            kind
            key))
  | _ ->
    Error
      (Printf.sprintf
         "%s field %s must be a canonical positive int64"
         kind
         key)
;;

let transaction_digest
      ~owner_id
      ~keeper_name
      ~expected_trace_id
      ~expected_generation
      ~candidate_nonce
  =
  [ transaction_domain
  ; length_delimited owner_id
  ; length_delimited keeper_name
  ; length_delimited
      (Keeper_id.Trace_id.to_string expected_trace_id)
  ; string_of_int expected_generation
  ; string_of_int candidate_nonce
  ]
  |> String.concat "\000"
  |> sha256
;;

let validate_payload (payload : payload) =
  if String.equal (String.trim payload.transaction_id) ""
  then Error (Invalid_binding "transaction_id must be non-empty")
  else if not (is_lowercase_sha256 payload.transaction_id)
  then Error (Invalid_binding "transaction_id must be a lowercase SHA-256")
  else if String.equal (String.trim payload.owner_id) ""
  then Error (Invalid_binding "owner_id must be non-empty")
  else if String.equal (String.trim payload.keeper_name) ""
  then Error (Invalid_binding "keeper_name must be non-empty")
  else if payload.expected_generation < 0
  then Error (Invalid_binding "expected_generation must be non-negative")
  else if
    not (String.equal payload.original.name payload.keeper_name)
    || not (String.equal payload.candidate.name payload.keeper_name)
  then Error (Invalid_binding "metadata does not match keeper_name")
  else if
    not
      (Keeper_id.Trace_id.equal
         payload.original.runtime.trace_id
         payload.expected_trace_id)
  then Error (Invalid_binding "original metadata does not match expected_trace_id")
  else if
    not
      (Int.equal
         payload.original.runtime.nonce
         payload.expected_generation)
  then Error (Invalid_binding "original metadata does not match expected_generation")
  else if
    not
      (Keeper_id.Trace_id.equal
         payload.candidate.runtime.trace_id
         payload.expected_trace_id)
  then Error (Invalid_binding "candidate metadata does not preserve expected_trace_id")
  else if payload.candidate.runtime.nonce <= payload.expected_generation
  then
    Error
      (Invalid_binding
         "candidate lifecycle nonce must advance expected_generation")
  else
    let expected_transaction_id =
      transaction_digest
        ~owner_id:payload.owner_id
        ~keeper_name:payload.keeper_name
        ~expected_trace_id:payload.expected_trace_id
        ~expected_generation:payload.expected_generation
        ~candidate_nonce:payload.candidate.runtime.nonce
    in
    if not (String.equal payload.transaction_id expected_transaction_id)
    then
      Error
        (Invalid_binding
           "transaction_id does not bind owner and lifecycle metadata")
    else Ok ()
;;
