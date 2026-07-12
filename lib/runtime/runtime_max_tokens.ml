type source =
  | Omitted
  | Explicit_override

let source_of_value = function
  | None -> Omitted
  | Some _ -> Explicit_override
;;

let source_to_string = function
  | Omitted -> "omitted"
  | Explicit_override -> "explicit_override"
;;

let telemetry_fields value =
  [ "max_tokens", Json_util.int_opt_to_json value
  ; "max_tokens_source", `String (source_of_value value |> source_to_string)
  ]
;;
