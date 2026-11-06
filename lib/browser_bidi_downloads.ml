let verify_file ~root path =
  try
    let root = Unix.realpath root in
    let stat = Unix.lstat path in
    let canonical = Unix.realpath path in
    if stat.Unix.st_kind <> Unix.S_REG then Error "download is not a regular file"
    else if not (String.starts_with ~prefix:(root ^ Filename.dir_sep) canonical)
    then Error "download path is outside session staging"
    else Ok (canonical, stat.Unix.st_size)
  with
  | Unix.Unix_error (code, _, _) -> Error (Unix.error_message code)
  | Sys_error detail -> Error detail

let not_a_loopback_endpoint = "Firefox must return a loopback ws URL with an explicit port"

let endpoint_uri url =
  (* [Uri.of_string] is meant to take any string. uri 4.4.0 raises [Failure]
     on a dotted host with a number too large for an int
     ("ws://127.0.0.99999999999999999999:9222/"). Such a string is no address. *)
  match Uri.of_string url with
  | exception Failure _ -> Error not_a_loopback_endpoint
  | uri ->
    (match Uri.scheme uri, Uri.host uri, Uri.port uri, Uri.userinfo uri, Uri.fragment uri with
     (* Firefox reports whatever it bound. The three literals this used to list
        are narrower than the error below claims and narrower than
        [is_loopback_host], which is the one place that decides this (#27576). *)
     | Some "ws", Some host, Some port, None, None
       when Masc_network_defaults.is_loopback_host host
            && port > 0 && port <= 65535 ->
       let resource = Uri.path_and_query uri in
       if resource = "" || resource.[0] <> '/' then Error "invalid BiDi WebSocket path"
       else Ok (uri, (host, port, resource))
     | _ -> Error not_a_loopback_endpoint)

let endpoint url = Result.map snd (endpoint_uri url)
