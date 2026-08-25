let ( let* ) = Result.bind

let field ~entry_id ~expected getter key toml =
  try Ok (Otoml.find_opt toml getter [ key ]) with
  | Otoml.Type_error _ ->
    Error (Printf.sprintf "model entry %S field %S expected %s" entry_id key expected)
;;

let string_field ~entry_id = field ~entry_id ~expected:"string" Otoml.get_string
let int_field ~entry_id = field ~entry_id ~expected:"integer" Otoml.get_integer

let parse ~entry_id toml =
  let* source_kind_raw = string_field ~entry_id "serving_constraint_source_kind" toml in
  let* source_ref = string_field ~entry_id "serving_constraint_source" toml in
  let* checked_at_unix_s =
    int_field ~entry_id "serving_constraint_checked_at_unix_s" toml
  in
  let* confidence_raw = string_field ~entry_id "serving_constraint_confidence" toml in
  let* expires_at_unix_s =
    int_field ~entry_id "serving_constraint_expires_at_unix_s" toml
  in
  let* accepted_through =
    int_field ~entry_id "serving_constraint_accepted_through_tokens" toml
  in
  let* rejected_from =
    int_field ~entry_id "serving_constraint_rejected_from_tokens" toml
  in
  match
    ( source_kind_raw
    , source_ref
    , checked_at_unix_s
    , confidence_raw
    , expires_at_unix_s
    , accepted_through
    , rejected_from )
  with
  | None, None, None, None, None, None, None -> Ok None
  | ( Some source_kind_raw
    , Some source_ref
    , Some checked_at_unix_s
    , Some confidence_raw
    , expires_at_unix_s
    , Some accepted_through
    , rejected_from ) ->
    let source_kind_raw = String.lowercase_ascii (String.trim source_kind_raw) in
    let confidence_raw = String.lowercase_ascii (String.trim confidence_raw) in
    let* source_kind =
      match Serving_constraint.source_kind_of_string source_kind_raw with
      | Some value -> Ok value
      | None ->
        Error
          (Printf.sprintf
             "model entry %S field %S has unknown value %S (canonical: declaration, \
              probe)"
             entry_id
             "serving_constraint_source_kind"
             source_kind_raw)
    in
    let* confidence =
      match Serving_constraint.confidence_of_string confidence_raw with
      | Some value -> Ok value
      | None ->
        Error
          (Printf.sprintf
             "model entry %S field %S has unknown value %S (canonical: low, medium, high)"
             entry_id
             "serving_constraint_confidence"
             confidence_raw)
    in
    Serving_constraint.make
      ~source_kind
      ~source_ref
      ~checked_at_unix_s
      ~confidence
      ?expires_at_unix_s
      ~accepted_through
      ?rejected_from
      ()
    |> Result.map Option.some
    |> Result.map_error (fun error ->
      Printf.sprintf
        "model entry %S has invalid serving constraint: %s"
        entry_id
        (Serving_constraint.show_validation_error error))
  | _ ->
    Error
      (Printf.sprintf
         "model entry %S serving constraint requires source_kind, source, checked_at, \
          confidence, and accepted_through"
         entry_id)
;;
