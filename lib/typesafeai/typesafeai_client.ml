let ( let* ) = Result.bind

let evaluate
      ?(endpoint = Typesafeai_config.endpoint ())
      ?(model = Typesafeai_config.model ())
      ?(timeout_sec = Masc_http_client.default_request_timeout_sec)
      ?clock
      ~api_key
      ~state
      ~questions
      ()
  =
  let request_json = Typesafeai_types.request_to_yojson ~model ~state ~questions in
  let body = Yojson.Safe.to_string request_json in
  let headers =
    [ "authorization", "Bearer " ^ api_key
    ; "content-type", "application/json"
    ; "accept", "application/json"
    ]
  in
  let* status, response_body =
    Masc_http_client.post_sync
      ?clock
      ~timeout_sec
      ~url:endpoint
      ~headers
      ~body
      ()
  in
  if status = 200
  then
    let* parsed_json =
      match Yojson.Safe.from_string response_body with
      | json -> Ok json
      | exception Yojson.Json_error msg ->
        Error (Printf.sprintf "typesafeai: invalid response JSON: %s" msg)
    in
    Typesafeai_types.eval_response_of_yojson parsed_json
  else
    Error
      (Printf.sprintf
         "typesafeai: HTTP %d returned by %s: %s"
         status
         endpoint
         response_body)
;;
