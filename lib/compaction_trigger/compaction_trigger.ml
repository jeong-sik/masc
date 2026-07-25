type capacity_dimension =
  | Input_tokens
  | Serialized_bytes

type t =
  | Provider_overflow of { limit_tokens : int option }
  | Measured_capacity_exceeded of
      { dimension : capacity_dimension
      ; measured : int
      ; limit : int
      }
  | Manual

let dimension_to_string = function
  | Input_tokens -> "input_tokens"
  | Serialized_bytes -> "serialized_bytes"
;;

let dimension_of_string = function
  | "input_tokens" -> Some Input_tokens
  | "serialized_bytes" -> Some Serialized_bytes
  | _ -> None
;;

let to_label = function
  | Provider_overflow _ -> "provider_overflow"
  | Measured_capacity_exceeded _ -> "measured_capacity_exceeded"
  | Manual -> "manual"
;;

let to_human = function
  | Provider_overflow { limit_tokens } ->
    Printf.sprintf
      "provider_overflow(limit=%s)"
      (match limit_tokens with
       | Some limit_tokens -> string_of_int limit_tokens
       | None -> "unknown")
  | Measured_capacity_exceeded { dimension; measured; limit } ->
    Printf.sprintf
      "measured_capacity_exceeded(dimension=%s,measured=%d,limit=%d)"
      (dimension_to_string dimension)
      measured
      limit
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
  | Measured_capacity_exceeded { dimension; measured; limit } ->
    `Assoc
      [ "kind", `String "measured_capacity_exceeded"
      ; "dimension", `String (dimension_to_string dimension)
      ; "measured", `Int measured
      ; "limit", `Int limit
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
  | Missing_measured_field of string
  | Invalid_measured_field of string
  | Unknown_dimension of string
  | Measured_not_exceeding_limit

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
  | Missing_measured_field name ->
    Printf.sprintf "measured capacity trigger is missing field %S" name
  | Invalid_measured_field name ->
    Printf.sprintf "measured capacity trigger field %S must be a positive integer" name
  | Unknown_dimension dimension ->
    Printf.sprintf "unknown capacity dimension %S" dimension
  | Measured_not_exceeding_limit ->
    "measured capacity trigger requires measured > limit; a value at the limit has \
     not been exceeded"
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
     | Some (`String "measured_capacity_exceeded") ->
       let* () = reject_unknown_fields [ "kind"; "dimension"; "measured"; "limit" ] in
       let positive_int name =
         match List.assoc_opt name fields with
         | None -> Error (Missing_measured_field name)
         | Some (`Int value) when value > 0 -> Ok value
         | Some _ -> Error (Invalid_measured_field name)
       in
       let* dimension =
         match List.assoc_opt "dimension" fields with
         | None -> Error (Missing_measured_field "dimension")
         | Some (`String raw) ->
           (match dimension_of_string raw with
            | Some dimension -> Ok dimension
            | None -> Error (Unknown_dimension raw))
         | Some _ -> Error (Invalid_measured_field "dimension")
       in
       let* measured = positive_int "measured" in
       let* limit = positive_int "limit" in
       if measured > limit
       then Ok (Measured_capacity_exceeded { dimension; measured; limit })
       else Error Measured_not_exceeding_limit
     | Some (`String "manual") ->
       let* () = reject_unknown_fields [ "kind" ] in
       Ok Manual
     | Some (`String kind) -> Error (Unknown_kind kind)
     | Some _ -> Error Invalid_kind
     | None -> Error Missing_kind)
  | _ -> Error Expected_object
;;
