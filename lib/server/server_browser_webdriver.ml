(* Browser policy and session ownership run in OCaml. geckodriver is the
   Firefox vendor's WebDriver remote end, configured in runtime.toml. *)
let configured_endpoint () =
  let resolution = Config_dir_resolver.resolve () in
  let path = Filename.concat resolution.Config_dir_resolver.config_root.path
      Config_dir_resolver.runtime_toml_filename in
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | exception Unix.Unix_error (code, _, _) -> Error (Unix.error_message code)
  | _ ->
    match Safe_ops.read_file_safe path with
    | Error detail -> Error detail
    | Ok text ->
      match Otoml.Parser.from_string_result text with
      | Error detail -> Error detail
      | Ok toml ->
        match Field_resolution.resolve_string toml ["browser"; "webdriver_url"] with
        | Field_resolution.Missing -> Ok None
        | Field_resolution.Type_mismatch { expected; message } -> Error (expected ^ ": " ^ message)
        | Field_resolution.Present endpoint ->
          let uri = Uri.of_string endpoint in
          match Uri.scheme uri, Uri.host uri, Uri.userinfo uri, Uri.path uri,
                Uri.query uri, Uri.fragment uri with
          | Some "http", Some ("127.0.0.1" | "localhost" | "::1"), None,
            ("" | "/"), [], None ->
            Ok (Some (Uri.to_string (Uri.with_path uri "")))
          | _ -> Error "browser.webdriver_url must be a loopback HTTP origin"

let start ~sw ~env =
  match configured_endpoint () with
  | Error detail -> Log.Server.error "browser-lane: %s" detail
  | Ok None -> Log.Server.info "browser-lane: native Firefox has no browser.webdriver_url"
  | Ok (Some endpoint) ->
    let pool = Masc_http_client.Pool.create ~sw ~env () in
    let clock = Eio.Stdenv.clock env in
    let request ~method_ ~path ~body =
      match Masc_http_client.Pool.request pool ~clock ~timeout_seconds:60.
        ~method_ ~url:(endpoint ^ path)
        ~headers:["Content-Type", "application/json"]
        ?body:(Option.map Yojson.Safe.to_string body) () with
      | Error detail -> Error (Browser_webdriver.Transport detail)
      | Ok response -> Browser_webdriver.decode_response ~status:response.status response.body
    in
    let driver = Browser_webdriver.create ~request in
    Browser_lane.install_automation_executor (Some (Browser_webdriver.execute driver));
    Eio.Switch.on_release sw (fun () ->
      Browser_lane.install_automation_executor None;
      match Browser_webdriver.close driver with
      | Ok () -> ()
      | Error error -> Log.Server.warn "browser-lane: close failed: %s"
          (Browser_webdriver.error_message error));
    Log.Server.info "browser-lane: native Firefox WebDriver configured at %s" endpoint
