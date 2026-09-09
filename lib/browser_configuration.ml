type t = Disabled | Webdriver of { endpoint : string; binary : string option }
let ( let* ) = Result.bind
let optional_string toml key =
  match Field_resolution.resolve_string toml ["browser"; key] with
  | Field_resolution.Missing -> Ok None
  | Field_resolution.Type_mismatch { expected; message } -> Error (expected ^ ": " ^ message)
  | Field_resolution.Present value -> Ok (Some value)
let parse toml =
  let* endpoint = optional_string toml "webdriver_url" in
  let* binary = optional_string toml "binary" in
  let* binary = match binary with
    | None -> Ok None
    | Some path when String.trim path <> "" && not (Filename.is_relative path) -> Ok (Some path)
    | Some _ -> Error "browser.binary must be an absolute browser executable or app bundle path" in
  match endpoint, binary with
  | None, None -> Ok Disabled
  | None, Some _ -> Error "browser.webdriver_url is required when browser.binary is configured"
  | Some endpoint, binary ->
    let uri = Uri.of_string endpoint in
    match Uri.scheme uri, Uri.host uri, Uri.userinfo uri, Uri.path uri,
          Uri.query uri, Uri.fragment uri with
    (* The three literals this used to list are a subset of what the error
       below promises. #27576 is the same shape one layer down: an
       implementation compared against 127.0.0.1 alone while saying
       "loopback", so 127.0.0.2 and systemd-resolved's 127.0.0.53 read as
       remote. [is_loopback_host] answers the question the message asks --
       the whole of 127.0.0.0/8, ::1, an IPv4-mapped ::ffff:127.0.0.1, and
       "localhost" in any case. *)
    | Some "http", Some host, None, ("" | "/"), [], None
      when Masc_network_defaults.is_loopback_host host ->
      Ok (Webdriver { endpoint = Uri.to_string (Uri.with_path uri ""); binary })
    | _ -> Error "browser.webdriver_url must be a loopback HTTP origin"
