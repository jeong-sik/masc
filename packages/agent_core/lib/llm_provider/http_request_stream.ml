type fields =
  | Stream_only
  | Stream_with_usage

let rec requires_text_validation = function
  | `Intlit _ -> true
  | `Float value -> not (Float.is_finite value)
  | `List values -> List.exists requires_text_validation values
  | `Assoc fields -> List.exists (fun (_, value) -> requires_text_validation value) fields
  | `Null | `Bool _ | `Int _ | `String _ -> false
;;

let encode ~fields json =
  if requires_text_validation json
  then
    let body = Yojson.Safe.to_string json in
    match fields with
    | Stream_only -> Http_client.inject_stream_param body
    | Stream_with_usage -> Http_client.inject_stream_and_options body
  else
    match json with
    | `Assoc members ->
      let members =
        match fields with
        | Stream_only ->
          ("stream", `Bool true)
          :: List.filter (fun (key, _) -> not (String.equal key "stream")) members
        | Stream_with_usage ->
          ("stream_options", `Assoc [ "include_usage", `Bool true ])
          :: ("stream", `Bool true)
          :: List.filter
               (fun (key, _) ->
                  not (String.equal key "stream" || String.equal key "stream_options"))
               members
      in
      Ok (Yojson.Safe.to_string (`Assoc members))
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error Http_client.Body_not_object
;;
