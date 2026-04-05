(** Return [true] when the optional hostname is a loopback endpoint we treat
    as local-only. *)
let is_loopback_host = function
  | Some "localhost" | Some "::1" -> true
  | Some host when String.starts_with ~prefix:"127." host -> true
  | _ -> false

(** Parse [url] and return [true] when its host is a recognized loopback
    endpoint. *)
let is_loopback_url url =
  is_loopback_host (Uri.host (Uri.of_string url))
