type t =
  | Provider_overflow of { limit_tokens : int option }
  | Manual

let to_label = function
  | Provider_overflow _ -> "provider_overflow"
  | Manual -> "manual"
;;

let to_human = function
  | Provider_overflow { limit_tokens } ->
    Printf.sprintf
      "provider_overflow(limit=%s)"
      (match limit_tokens with
       | Some limit_tokens -> string_of_int limit_tokens
       | None -> "unknown")
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
     | Some (`String "manual") ->
       let* () = reject_unknown_fields [ "kind" ] in
       Ok Manual
     | Some (`String kind) -> Error (Unknown_kind kind)
     | Some _ -> Error Invalid_kind
     | None -> Error Missing_kind)
  | _ -> Error Expected_object
;;
