type t =
  { message : string
  ; error_type : string option
  ; provider_status : Types.provider_status option
  ; report : Types.provider_report
  }

(* RFC 6585 section 4. *)
let too_many_requests = 429

(* RFC 9110 section 15.6: the server error class. *)
let server_error_min = 500
let server_error_max = 599

(* Only a status that states the provider's condition is used. The request was
   already accepted when the response's [200] went out, so a 4xx the provider
   reports after it does not say this request is invalid -- and OpenRouter
   tells readers not to tell its error categories apart by the status alone.
   429 (rate limited) and 5xx (the provider failing) mean the same before the
   stream started and after, so classifying them as the status line they
   would have been reads the same condition. See the .mli for the sources. *)
let states_provider_condition code =
  code = too_many_requests || (code >= server_error_min && code <= server_error_max)
;;

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let string_member name json =
  match member name json with
  | Some (`String value) -> Some value
  | None | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) ->
    None
;;

(* OpenAI names the category in [type]; OpenRouter in [metadata.error_type]. *)
let error_type_of_object error =
  match string_member "type" error with
  | Some _ as error_type -> error_type
  | None -> Option.bind (member "metadata" error) (string_member "error_type")
;;

(* The error object alone, at the top level where [Retry.classify_error] reads
   [error.message] and [error.retry_after]. Whatever else the response or chunk
   carried -- a choice's content, tool arguments, usage -- is not part of the
   refusal. *)
let error_body error = Yojson.Safe.to_string (`Assoc [ "error", error ])

let provider_status_of_object error =
  match member "code" error with
  | Some (`Int code) when states_provider_condition code ->
    Some { Types.status = code; error_body = error_body error }
  | None
  | Some (`Int _ | `Assoc _ | `List _ | `String _ | `Intlit _ | `Float _ | `Bool _ | `Null)
    -> None
;;

let of_error_value ~fallback_message = function
  | `Assoc _ as error ->
    Some
      { message = Option.value (string_member "message" error) ~default:fallback_message
      ; error_type = error_type_of_object error
      ; provider_status = provider_status_of_object error
      ; report = Types.Provider_stated
      }
  | `String message ->
    Some
      { message
      ; error_type = None
      ; provider_status = None
      ; report = Types.Provider_stated
      }
  | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let without_error_object =
  { message = "the provider ended the choice with finish_reason error and no error object"
  ; error_type = None
  ; provider_status = None
  ; report = Types.Unstated_errored_choice
  }
;;

let of_errored_choice ~fallback_message choice =
  match Option.bind (member "error" choice) (of_error_value ~fallback_message) with
  | Some envelope -> envelope
  | None -> without_error_object
;;

let%test "OpenRouter's documented mid-stream error keeps its object as the body" =
  of_error_value
    ~fallback_message:"raw"
    (Yojson.Safe.from_string
       {|{"code":502,"message":"Provider disconnected","metadata":{"error_type":"provider_unavailable"}}|})
  = Some
      { message = "Provider disconnected"
      ; error_type = Some "provider_unavailable"
      ; provider_status =
          Some
            { Types.status = 502
            ; error_body =
                {|{"error":{"code":502,"message":"Provider disconnected","metadata":{"error_type":"provider_unavailable"}}}|}
            }
      ; report = Types.Provider_stated
      }
;;

let%test "only 429 and the 5xx class state the provider's condition" =
  let status json =
    Option.map
      (fun envelope ->
         Option.map (fun (s : Types.provider_status) -> s.status) envelope.provider_status)
      (of_error_value ~fallback_message:"raw" (Yojson.Safe.from_string json))
  in
  let numeric code = status (Printf.sprintf {|{"code":%d,"message":"m"}|} code) in
  List.for_all (fun code -> numeric code = Some (Some code)) [ 429; 500; 502; 599 ]
  && List.for_all
       (fun code -> numeric code = Some None)
       [ 200; 400; 401; 402; 403; 413; 428; 430; 499; 600; 1261 ]
  && status {|{"code":"server_error","message":"m"}|} = Some None
  && status {|{"code":"1261","message":"Prompt exceeds max length"}|} = Some None
  && status {|{"code":"429","message":"m"}|} = Some None
;;

let%test "the object's type wins over OpenRouter's metadata error_type" =
  let error_type json =
    Option.map
      (fun envelope -> envelope.error_type)
      (of_error_value ~fallback_message:"raw" (Yojson.Safe.from_string json))
  in
  error_type
    {|{"type":"rate_limit_exceeded","code":"rate_limit_exceeded","metadata":{"error_type":"server"}}|}
  = Some (Some "rate_limit_exceeded")
  && error_type {|{"code":429,"metadata":{"error_type":"rate_limit_exceeded"}}|}
     = Some (Some "rate_limit_exceeded")
  && error_type {|{"code":429,"metadata":{"error_type":7}}|} = Some None
;;

let%test "OpenAI's own error object falls back for a missing message" =
  of_error_value
    ~fallback_message:"raw"
    (Yojson.Safe.from_string {|{"type":"rate_limit_exceeded","code":"rate_limit_exceeded"}|})
  = Some
      { message = "raw"
      ; error_type = Some "rate_limit_exceeded"
      ; provider_status = None
      ; report = Types.Provider_stated
      }
;;

let%test "a bare string error declares no status" =
  of_error_value ~fallback_message:"raw" (`String "model failed")
  = Some
      { message = "model failed"
      ; error_type = None
      ; provider_status = None
      ; report = Types.Provider_stated
      }
  && of_error_value ~fallback_message:"raw" (`Int 502) = None
;;

let%test "an errored choice without an error object still reads as the provider failing" =
  of_errored_choice
    ~fallback_message:"raw"
    (Yojson.Safe.from_string {|{"index":0,"delta":{"content":""},"finish_reason":"error"}|})
  = without_error_object
  && of_errored_choice
       ~fallback_message:"raw"
       (Yojson.Safe.from_string
          {|{"index":0,"delta":{"content":"partial answer"},"finish_reason":"error","error":{"code":429,"message":"slow down","retry_after":7.0}}|})
     = { message = "slow down"
       ; error_type = None
       ; provider_status =
           Some
             { Types.status = 429
             ; error_body = {|{"error":{"code":429,"message":"slow down","retry_after":7.0}}|}
             }
       ; report = Types.Provider_stated
       }
;;
