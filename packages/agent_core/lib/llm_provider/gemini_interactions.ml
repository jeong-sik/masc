type usage =
  { input_tokens : int option
  ; output_tokens : int option
  ; total_tokens : int option
  ; cached_tokens : int option
  ; thought_tokens : int option
  ; tool_use_tokens : int option
  }

type 'payload response =
  { provider_response_id : string
  ; created_at_rfc3339 : string option
  ; payload : 'payload
  ; usage : usage option
  }

let parse_failure ~parser message =
  Error
    (Http_client.ProviderFailure
       { kind = Http_client.Provider_parse_error { parser = Some parser }; message })
;;

(* A well-formed interaction whose status is not "completed" is a
   provider-reported outcome, not a parser defect: keep it out of
   Provider_parse_error so parse-error alarms stay meaningful. *)
let status_failure status =
  Error
    (Http_client.ProviderFailure
       { kind =
           Http_client.Unknown_provider_failure
             { reason = Some (Printf.sprintf "gemini interaction status %s" status) }
       ; message =
           Printf.sprintf
             "Gemini interaction finished with status %S, not completed"
             status
       })
;;

let optional_string ~parser name json =
  match Yojson.Safe.Util.member name json with
  | `Null -> Ok None
  | `String value when String.trim value <> "" -> Ok (Some value)
  | _ ->
    parse_failure ~parser (Printf.sprintf "Gemini interaction %s must be non-empty" name)
;;

let required_string ~parser name json =
  match optional_string ~parser name json with
  | Ok (Some value) -> Ok value
  | Ok None ->
    parse_failure ~parser (Printf.sprintf "Gemini interaction %s is required" name)
  | Error _ as error -> error
;;

let optional_int ~parser name json =
  match Yojson.Safe.Util.member name json with
  | `Null -> Ok None
  | `Int value -> Ok (Some value)
  | _ ->
    parse_failure ~parser (Printf.sprintf "Gemini interaction %s must be an integer" name)
;;

let usage_of_json ~parser json =
  match Yojson.Safe.Util.member "usage" json with
  | `Null -> Ok None
  | `Assoc _ as usage_json ->
    let ( let* ) = Result.bind in
    let* input_tokens = optional_int ~parser "total_input_tokens" usage_json in
    let* output_tokens = optional_int ~parser "total_output_tokens" usage_json in
    let* total_tokens = optional_int ~parser "total_tokens" usage_json in
    let* cached_tokens = optional_int ~parser "total_cached_tokens" usage_json in
    let* thought_tokens = optional_int ~parser "total_thought_tokens" usage_json in
    let* tool_use_tokens = optional_int ~parser "total_tool_use_tokens" usage_json in
    Ok
      (Some
         { input_tokens
         ; output_tokens
         ; total_tokens
         ; cached_tokens
         ; thought_tokens
         ; tool_use_tokens
         })
  | _ -> parse_failure ~parser "Gemini interaction usage must be an object"
;;

let model_output_items ~parser ~content_type ~item_of_json json =
  let open Yojson.Safe.Util in
  let add_content acc = function
    | `Assoc _ as content ->
      (match member "type" content with
       | `String kind when String.equal kind content_type ->
         Result.map (fun item -> item :: acc) (item_of_json content)
       | `String kind ->
         parse_failure
           ~parser
           (Printf.sprintf "unexpected Gemini model_output content type %S" kind)
       | _ -> parse_failure ~parser "Gemini model_output content requires a type")
    | _ -> parse_failure ~parser "Gemini model_output content must be an object"
  in
  let add_step acc = function
    | `Assoc _ as step ->
      (match member "type" step with
       | `String "thought" -> Ok acc
       | `String "model_output" ->
         (match member "content" step with
          | `List contents ->
            List.fold_left
              (fun result item -> Result.bind result (fun acc -> add_content acc item))
              (Ok acc)
              contents
          | _ -> parse_failure ~parser "Gemini model_output content must be a list")
       | `String kind ->
         parse_failure
           ~parser
           (Printf.sprintf "unexpected Gemini interaction step %S" kind)
       | _ -> parse_failure ~parser "Gemini interaction step requires a type")
    | _ -> parse_failure ~parser "Gemini interaction step must be an object"
  in
  match Yojson.Safe.Util.member "steps" json with
  | `List steps ->
    Result.map
      List.rev
      (List.fold_left
         (fun result step -> Result.bind result (fun acc -> add_step acc step))
         (Ok [])
         steps)
  | _ -> parse_failure ~parser "Gemini interaction steps must be a list"
;;

let decode_envelope ~parser ~payload_of_json body =
  let decode json =
    let ( let* ) = Result.bind in
    let* provider_response_id = required_string ~parser "id" json in
    let* status = required_string ~parser "status" json in
    let* () = if String.equal status "completed" then Ok () else status_failure status in
    let* created_at_rfc3339 = optional_string ~parser "created" json in
    let* payload = payload_of_json json in
    let* usage = usage_of_json ~parser json in
    Ok { provider_response_id; created_at_rfc3339; payload; usage }
  in
  match Json_util.decode_json_with decode body with
  | Ok result -> result
  | Error message -> parse_failure ~parser ("invalid Gemini interaction JSON: " ^ message)
;;
