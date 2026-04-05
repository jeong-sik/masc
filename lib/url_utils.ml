let is_loopback_host = function
  | Some "localhost" | Some "127.0.0.1" -> true
  | _ -> false

let is_loopback_url url =
  is_loopback_host (Uri.host (Uri.of_string url))
