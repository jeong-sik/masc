let prune_http_json ~config ~operator_name : (Yojson.Safe.t, string) result =
  let operator_name = String.trim operator_name in
  if String.equal operator_name ""
  then Error "authenticated operator is required"
  else
    match Schedule_service.prune config with
    | Error error -> Error (Schedule_service.service_error_to_string error)
    | Ok (_, count) ->
      Ok (`Assoc [ "ok", `Bool true; "pruned_count", `Int count ])
;;
