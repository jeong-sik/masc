type t =
  | Ok_summary
  | Timed_out
  | Http_error
  | Empty_response
  | Invalid_structured_response

let to_label = function
  | Ok_summary -> "ok_summary"
  | Timed_out -> "timed_out"
  | Http_error -> "http_error"
  | Empty_response -> "empty_response"
  | Invalid_structured_response -> "invalid_structured_response"
;;
