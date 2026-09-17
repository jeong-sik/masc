type t =
  { message : string
  ; error_type : string option
  ; http_status : int option
  }

let http_status_min = 100
let http_status_max = 599

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let of_error_value ~fallback_message = function
  | `Assoc _ as error ->
    let message =
      match member "message" error with
      | Some (`String message) -> message
      | None | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
        -> fallback_message
    in
    let error_type =
      match member "type" error with
      | Some (`String error_type) -> Some error_type
      | None | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
        -> None
    in
    let http_status =
      match member "code" error with
      | Some (`Int code) when code >= http_status_min && code <= http_status_max ->
        Some code
      | None
      | Some (`Int _ | `Assoc _ | `List _ | `String _ | `Intlit _ | `Float _ | `Bool _ | `Null)
        -> None
    in
    Some { message; error_type; http_status }
  | `String message -> Some { message; error_type = None; http_status = None }
  | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let without_error_object =
  { message = "the provider ended the choice with finish_reason error and no error object"
  ; error_type = None
  ; http_status = None
  }
;;

let of_errored_choice ~fallback_message choice =
  match Option.bind (member "error" choice) (of_error_value ~fallback_message) with
  | Some envelope -> envelope
  | None -> without_error_object
;;

let%test "OpenRouter's documented mid-stream error declares its HTTP status" =
  of_error_value
    ~fallback_message:"raw"
    (Yojson.Safe.from_string
       {|{"code":502,"message":"Provider disconnected","metadata":{"error_type":"provider_unavailable"}}|})
  = Some { message = "Provider disconnected"; error_type = None; http_status = Some 502 }
;;

let%test "a string code or a vendor number is not an HTTP status" =
  let status json =
    Option.map
      (fun envelope -> envelope.http_status)
      (of_error_value ~fallback_message:"raw" (Yojson.Safe.from_string json))
  in
  status {|{"code":"server_error","message":"m"}|} = Some None
  && status {|{"code":"1261","message":"Prompt exceeds max length"}|} = Some None
  && status {|{"code":1261,"message":"m"}|} = Some None
  && status {|{"code":99,"message":"m"}|} = Some None
  && status {|{"code":600,"message":"m"}|} = Some None
  && status {|{"code":100,"message":"m"}|} = Some (Some 100)
  && status {|{"code":599,"message":"m"}|} = Some (Some 599)
;;

let%test "OpenAI's own error object keeps its type and falls back for a missing message" =
  of_error_value
    ~fallback_message:"raw"
    (Yojson.Safe.from_string {|{"type":"rate_limit_exceeded","code":"rate_limit_exceeded"}|})
  = Some { message = "raw"; error_type = Some "rate_limit_exceeded"; http_status = None }
;;

let%test "an errored choice without an error object still reads as the provider failing" =
  of_errored_choice
    ~fallback_message:"raw"
    (Yojson.Safe.from_string {|{"index":0,"delta":{"content":""},"finish_reason":"error"}|})
  = without_error_object
  && of_errored_choice
       ~fallback_message:"raw"
       (Yojson.Safe.from_string
          {|{"index":0,"finish_reason":"error","error":{"code":429,"message":"slow down"}}|})
     = { message = "slow down"; error_type = None; http_status = Some 429 }
;;
