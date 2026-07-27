type serving_input_capacity =
  | Boundary_unknown of
      { input_tokens : int
      ; accepted_through : int
      ; rejected_from : int option
      }
  | Input_rejected of
      { input_tokens : int
      ; accepted_through : int
      ; rejected_from : int
      }

type t =
  | Provider_overflow of { limit_tokens : int option }
  | Request_body_over_capacity of
      { actual_bytes : int
      ; limit_bytes : int
      }
  | Serving_input_capacity of serving_input_capacity
  | Manual

(* Field names are the wire contract for [of_detail_json]; naming them once keeps
   the encoder and the decoder from drifting apart. *)
let kind_field = "kind"
let limit_tokens_field = "limit_tokens"
let actual_bytes_field = "actual_bytes"
let limit_bytes_field = "limit_bytes"
let reason_field = "reason"
let input_tokens_field = "input_tokens"
let accepted_through_field = "accepted_through"
let rejected_from_field = "rejected_from"

(* Every key [to_detail_json] can emit, across all constructors. Consumers that
   filter the encoded object — the runtime manifest public projection is the
   one in tree — read this instead of restating the keys, so adding a field to
   a trigger constructor cannot leave a stale allowlist silently dropping it.
   Before this existed the manifest listed only [kind_field] and
   [limit_tokens_field], so the byte bounds of a
   [Request_body_over_capacity] refusal never reached the dashboard. *)
let wire_field_names =
  [ kind_field
  ; limit_tokens_field
  ; actual_bytes_field
  ; limit_bytes_field
  ; reason_field
  ; input_tokens_field
  ; accepted_through_field
  ; rejected_from_field
  ]
;;

let to_label = function
  | Provider_overflow _ -> "provider_overflow"
  | Request_body_over_capacity _ -> "request_body_over_capacity"
  | Serving_input_capacity _ -> "serving_input_capacity"
  | Manual -> "manual"
;;

let to_human = function
  | Provider_overflow { limit_tokens } ->
    Printf.sprintf
      "provider_overflow(limit=%s)"
      (match limit_tokens with
       | Some limit_tokens -> string_of_int limit_tokens
       | None -> "unknown")
  | Request_body_over_capacity { actual_bytes; limit_bytes } ->
    Printf.sprintf "request_body_over_capacity(%dB>%dB)" actual_bytes limit_bytes
  | Serving_input_capacity
      (Boundary_unknown { input_tokens; accepted_through; rejected_from }) ->
    Printf.sprintf
      "serving_input_capacity(boundary_unknown,input=%d,accepted=%d,rejected=%s)"
      input_tokens
      accepted_through
      (match rejected_from with
       | Some value -> string_of_int value
       | None -> "unknown")
  | Serving_input_capacity
      (Input_rejected { input_tokens; accepted_through; rejected_from }) ->
    Printf.sprintf
      "serving_input_capacity(input_rejected,input=%d,accepted=%d,rejected=%d)"
      input_tokens
      accepted_through
      rejected_from
  | Manual -> "manual"
;;

let to_detail_json : t -> Yojson.Safe.t = function
  | Provider_overflow { limit_tokens } ->
    `Assoc
      [ kind_field, `String "provider_overflow"
      ; ( limit_tokens_field
        , match limit_tokens with
          | Some limit_tokens -> `Int limit_tokens
          | None -> `Null )
      ]
  | Request_body_over_capacity { actual_bytes; limit_bytes } ->
    `Assoc
      [ kind_field, `String "request_body_over_capacity"
      ; actual_bytes_field, `Int actual_bytes
      ; limit_bytes_field, `Int limit_bytes
      ]
  | Serving_input_capacity
      (Boundary_unknown { input_tokens; accepted_through; rejected_from }) ->
    `Assoc
      [ kind_field, `String "serving_input_capacity"
      ; reason_field, `String "boundary_unknown"
      ; input_tokens_field, `Int input_tokens
      ; accepted_through_field, `Int accepted_through
      ; ( rejected_from_field
        , match rejected_from with
          | Some value -> `Int value
          | None -> `Null )
      ]
  | Serving_input_capacity
      (Input_rejected { input_tokens; accepted_through; rejected_from }) ->
    `Assoc
      [ kind_field, `String "serving_input_capacity"
      ; reason_field, `String "input_rejected"
      ; input_tokens_field, `Int input_tokens
      ; accepted_through_field, `Int accepted_through
      ; rejected_from_field, `Int rejected_from
      ]
  | Manual -> `Assoc [ kind_field, `String "manual" ]
;;

type decode_error =
  | Expected_object
  | Unknown_field of string
  | Duplicate_field of string
  | Missing_kind
  | Invalid_kind
  | Unknown_kind of string
  | Missing_provider_limit
  | Invalid_provider_limit
  | Missing_request_body_bytes of string
  | Invalid_request_body_bytes of string
  | Request_body_within_capacity of
      { actual_bytes : int
      ; limit_bytes : int
      }
  | Missing_serving_capacity_field of string
  | Invalid_serving_capacity_field of string
  | Serving_capacity_not_over_limit of
      { input_tokens : int
      ; accepted_through : int
      }
  | Invalid_boundary_unknown of
      { input_tokens : int
      ; rejected_from : int
      }
  | Invalid_input_rejected_boundary of
      { input_tokens : int
      ; accepted_through : int
      ; rejected_from : int option
      }

let decode_error_to_string = function
  | Expected_object -> "compaction trigger detail must be an object"
  | Unknown_field name ->
    Printf.sprintf "compaction trigger detail has unknown field %S" name
  | Duplicate_field name ->
    Printf.sprintf "compaction trigger detail has duplicate field %S" name
  | Missing_kind -> "compaction trigger detail is missing kind"
  | Invalid_kind -> "compaction trigger kind must be a string"
  | Unknown_kind kind -> Printf.sprintf "unknown compaction trigger kind %S" kind
  | Missing_provider_limit -> "provider overflow trigger is missing limit_tokens"
  | Invalid_provider_limit ->
    "provider overflow limit_tokens must be null or a positive integer"
  | Missing_request_body_bytes field ->
    Printf.sprintf "request body over capacity trigger is missing %s" field
  | Invalid_request_body_bytes field ->
    Printf.sprintf "request body over capacity %s must be a positive integer" field
  | Request_body_within_capacity { actual_bytes; limit_bytes } ->
    Printf.sprintf
      "request body over capacity requires actual_bytes > limit_bytes, got %d and %d"
      actual_bytes
      limit_bytes
  | Missing_serving_capacity_field field ->
    Printf.sprintf "serving input capacity trigger is missing %s" field
  | Invalid_serving_capacity_field field ->
    Printf.sprintf "serving input capacity trigger has invalid %s" field
  | Serving_capacity_not_over_limit { input_tokens; accepted_through } ->
    Printf.sprintf
      "serving input capacity requires input_tokens > accepted_through, got %d and %d"
      input_tokens
      accepted_through
  | Invalid_boundary_unknown { input_tokens; rejected_from } ->
    Printf.sprintf
      "serving input capacity boundary_unknown requires rejected_from > input_tokens, got input=%d rejected=%d"
      input_tokens
      rejected_from
  | Invalid_input_rejected_boundary
      { input_tokens; accepted_through; rejected_from } ->
    Printf.sprintf
      "serving input capacity input_rejected requires accepted_through < rejected_from <= input_tokens, got input=%d accepted=%d rejected=%s"
      input_tokens
      accepted_through
      (match rejected_from with
       | Some value -> string_of_int value
       | None -> "missing")
;;

let of_detail_json (json : Yojson.Safe.t) : (t, decode_error) result =
  match json with
  | `Assoc fields ->
    let rec reject_duplicate_fields seen = function
      | [] -> Ok ()
      | (name, _) :: _ when List.mem name seen -> Error (Duplicate_field name)
      | (name, _) :: rest -> reject_duplicate_fields (name :: seen) rest
    in
    let reject_unknown_fields allowed =
      match List.find_opt (fun (name, _) -> not (List.mem name allowed)) fields with
      | Some (name, _) -> Error (Unknown_field name)
      | None -> Ok ()
    in
    let ( let* ) = Result.bind in
    let* () = reject_duplicate_fields [] fields in
    (match List.assoc_opt kind_field fields with
     | Some (`String "provider_overflow") ->
       let* () = reject_unknown_fields [ kind_field; limit_tokens_field ] in
       (match List.assoc_opt limit_tokens_field fields with
        | Some `Null -> Ok (Provider_overflow { limit_tokens = None })
        | Some (`Int limit_tokens) when limit_tokens > 0 ->
          Ok (Provider_overflow { limit_tokens = Some limit_tokens })
        | None -> Error Missing_provider_limit
        | Some _ -> Error Invalid_provider_limit)
     | Some (`String "request_body_over_capacity") ->
       let* () =
         reject_unknown_fields [ kind_field; actual_bytes_field; limit_bytes_field ]
       in
       let positive_int field =
         match List.assoc_opt field fields with
         | Some (`Int value) when value > 0 -> Ok value
         | None -> Error (Missing_request_body_bytes field)
         | Some _ -> Error (Invalid_request_body_bytes field)
       in
       let* actual_bytes = positive_int actual_bytes_field in
       let* limit_bytes = positive_int limit_bytes_field in
       (* The name asserts a comparison, so a record that does not satisfy it is
          not a value of this type. Decoding it would put a trigger claiming
          over-capacity in front of a compaction that had no capacity reason. *)
       if actual_bytes > limit_bytes
       then Ok (Request_body_over_capacity { actual_bytes; limit_bytes })
       else Error (Request_body_within_capacity { actual_bytes; limit_bytes })
     | Some (`String "serving_input_capacity") ->
       let* () =
         reject_unknown_fields
           [ kind_field
           ; reason_field
           ; input_tokens_field
           ; accepted_through_field
           ; rejected_from_field
           ]
       in
       let integer_field ~positive field =
         match List.assoc_opt field fields with
         | Some (`Int value) when if positive then value > 0 else value >= 0 ->
           Ok value
         | None -> Error (Missing_serving_capacity_field field)
         | Some _ -> Error (Invalid_serving_capacity_field field)
       in
       let* input_tokens = integer_field ~positive:true input_tokens_field in
       let* accepted_through =
         integer_field ~positive:false accepted_through_field
       in
       let* reason =
         match List.assoc_opt reason_field fields with
         | Some (`String value) -> Ok value
         | None -> Error (Missing_serving_capacity_field reason_field)
         | Some _ -> Error (Invalid_serving_capacity_field reason_field)
       in
       let* rejected_from =
         match List.assoc_opt rejected_from_field fields with
         | Some `Null -> Ok None
         | Some (`Int value) when value > 0 -> Ok (Some value)
         | None -> Error (Missing_serving_capacity_field rejected_from_field)
         | Some _ -> Error (Invalid_serving_capacity_field rejected_from_field)
       in
       if input_tokens <= accepted_through
       then Error (Serving_capacity_not_over_limit { input_tokens; accepted_through })
       else
         (match reason, rejected_from with
          | "boundary_unknown", None ->
            Ok
              (Serving_input_capacity
                 (Boundary_unknown { input_tokens; accepted_through; rejected_from = None }))
          | "boundary_unknown", Some rejected_from
            when rejected_from > input_tokens ->
            Ok
              (Serving_input_capacity
                 (Boundary_unknown
                    { input_tokens
                    ; accepted_through
                    ; rejected_from = Some rejected_from
                    }))
          | "boundary_unknown", Some rejected_from ->
            Error
              (Invalid_boundary_unknown
                 { input_tokens; rejected_from })
          | "input_rejected", None ->
            Error
              (Invalid_input_rejected_boundary
                 { input_tokens; accepted_through; rejected_from })
          | "input_rejected", Some rejected_from
            when rejected_from > accepted_through
                 && rejected_from <= input_tokens ->
            Ok
              (Serving_input_capacity
                 (Input_rejected
                    { input_tokens; accepted_through; rejected_from }))
          | "input_rejected", Some _ ->
            Error
              (Invalid_input_rejected_boundary
                 { input_tokens; accepted_through; rejected_from })
          | _, _ -> Error (Invalid_serving_capacity_field reason_field))
     | Some (`String "manual") ->
       let* () = reject_unknown_fields [ kind_field ] in
       Ok Manual
     | Some (`String kind) -> Error (Unknown_kind kind)
     | Some _ -> Error Invalid_kind
     | None -> Error Missing_kind)
  | _ -> Error Expected_object
;;
