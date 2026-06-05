type t =
  | Ok_summary
  | Timed_out
  | Http_error
  | Empty_response

let to_label = function
  | Ok_summary -> "ok_summary"
  | Timed_out -> "timed_out"
  | Http_error -> "http_error"
  | Empty_response -> "empty_response"
;;
