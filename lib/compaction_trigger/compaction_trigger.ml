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
let actual_bytes_field = "actual_bytes"
let limit_bytes_field = "limit_bytes"

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
      [ "kind", `String "provider_overflow"
      ; ( "limit_tokens"
        , match limit_tokens with
          | Some limit_tokens -> `Int limit_tokens
          | None -> `Null )
      ]
  | Request_body_over_capacity { actual_bytes; limit_bytes } ->
    `Assoc
      [ "kind", `String "request_body_over_capacity"
      ; actual_bytes_field, `Int actual_bytes
      ; limit_bytes_field, `Int limit_bytes
      ]
  | Serving_input_capacity
      (Boundary_unknown { input_tokens; accepted_through; rejected_from }) ->
    `Assoc
      [ "kind", `String "serving_input_capacity"
      ; "reason", `String "boundary_unknown"
      ; "input_tokens", `Int input_tokens
      ; "accepted_through", `Int accepted_through
      ; ( "rejected_from"
        , match rejected_from with
          | Some value -> `Int value
          | None -> `Null )
      ]
  | Serving_input_capacity
      (Input_rejected { input_tokens; accepted_through; rejected_from }) ->
    `Assoc
      [ "kind", `String "serving_input_capacity"
      ; "reason", `String "input_rejected"
      ; "input_tokens", `Int input_tokens
      ; "accepted_through", `Int accepted_through
      ; "rejected_from", `Int rejected_from
      ]
  | Manual -> `Assoc [ "kind", `String "manual" ]
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
  | Invalid_serving_capacity_boundary of
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
  | Invalid_serving_capacity_boundary
      { input_tokens; accepted_through; rejected_from } ->
    Printf.sprintf
      "serving input capacity rejected_from must be greater than accepted_through and no greater than input_tokens, got input=%d accepted=%d rejected=%s"
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
    (match List.assoc_opt "kind" fields with
     | Some (`String "provider_overflow") ->
       let* () = reject_unknown_fields [ "kind"; "limit_tokens" ] in
       (match List.assoc_opt "limit_tokens" fields with
        | Some `Null -> Ok (Provider_overflow { limit_tokens = None })
        | Some (`Int limit_tokens) when limit_tokens > 0 ->
          Ok (Provider_overflow { limit_tokens = Some limit_tokens })
        | None -> Error Missing_provider_limit
        | Some _ -> Error Invalid_provider_limit)
     | Some (`String "request_body_over_capacity") ->
       let* () =
         reject_unknown_fields [ "kind"; actual_bytes_field; limit_bytes_field ]
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
           [ "kind"; "reason"; "input_tokens"; "accepted_through"; "rejected_from" ]
       in
       let integer_field ~positive field =
         match List.assoc_opt field fields with
         | Some (`Int value) when if positive then value > 0 else value >= 0 ->
           Ok value
         | None -> Error (Missing_serving_capacity_field field)
         | Some _ -> Error (Invalid_serving_capacity_field field)
       in
       let* input_tokens = integer_field ~positive:true "input_tokens" in
       let* accepted_through = integer_field ~positive:false "accepted_through" in
       let* reason =
         match List.assoc_opt "reason" fields with
         | Some (`String value) -> Ok value
         | None -> Error (Missing_serving_capacity_field "reason")
         | Some _ -> Error (Invalid_serving_capacity_field "reason")
       in
       let* rejected_from =
         match List.assoc_opt "rejected_from" fields with
         | Some `Null -> Ok None
         | Some (`Int value) when value > 0 -> Ok (Some value)
         | None -> Error (Missing_serving_capacity_field "rejected_from")
         | Some _ -> Error (Invalid_serving_capacity_field "rejected_from")
       in
       if input_tokens <= accepted_through
       then Error (Serving_capacity_not_over_limit { input_tokens; accepted_through })
       else
         let boundary_valid =
           match rejected_from with
           | None -> true
           | Some value ->
             value > accepted_through && value <= input_tokens
         in
         if not boundary_valid
         then
           Error
             (Invalid_serving_capacity_boundary
                { input_tokens; accepted_through; rejected_from })
         else
           (match reason, rejected_from with
            | "boundary_unknown", rejected_from ->
              Ok
                (Serving_input_capacity
                   (Boundary_unknown
                      { input_tokens; accepted_through; rejected_from }))
            | "input_rejected", Some rejected_from ->
              Ok
                (Serving_input_capacity
                   (Input_rejected
                      { input_tokens; accepted_through; rejected_from }))
            | "input_rejected", None ->
              Error
                (Invalid_serving_capacity_boundary
                   { input_tokens; accepted_through; rejected_from = None })
            | _, _ -> Error (Invalid_serving_capacity_field "reason"))
     | Some (`String "manual") ->
       let* () = reject_unknown_fields [ "kind" ] in
       Ok Manual
     | Some (`String kind) -> Error (Unknown_kind kind)
     | Some _ -> Error Invalid_kind
     | None -> Error Missing_kind)
  | _ -> Error Expected_object
;;
