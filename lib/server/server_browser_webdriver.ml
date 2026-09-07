(* Browser policy and session ownership run in OCaml. geckodriver is the
   Firefox vendor's WebDriver remote end, configured in runtime.toml. *)
let configured_browser () =
  let resolution = Config_dir_resolver.resolve () in
  let path = Filename.concat resolution.Config_dir_resolver.config_root.path
      Config_dir_resolver.runtime_toml_filename in
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Browser_configuration.Disabled
  | exception Unix.Unix_error (code, _, _) -> Error (Unix.error_message code)
  | _ ->
    match Safe_ops.read_file_safe path with
    | Error detail -> Error detail
    | Ok text ->
      match Otoml.Parser.from_string_result text with
      | Error detail -> Error detail
      | Ok toml -> Browser_configuration.parse toml

let request ~pool ~clock ~endpoint ~method_ ~path ~body =
  match Masc_http_client.Pool.request pool ~clock ~timeout_seconds:60.
    ~method_ ~url:(endpoint ^ path)
    ~headers:["Content-Type", "application/json"]
    ?body:(Option.map Yojson.Safe.to_string body) () with
  | Error detail -> Error (Browser_webdriver.Transport detail)
  | Ok response -> Browser_webdriver.decode_response ~status:response.status response.body

let close_with_fresh_pool ~env ~endpoint driver =
  let clock = Eio.Stdenv.clock env in
  let result, finished = Eio.Promise.create () in
  (* The root switch is already releasing its sockets. This worker owns a
     fresh switch; after DELETE finishes, [first] cancels its pool's eviction
     fiber and releases all connections before returning the result. *)
  Eio.Fiber.first
    (fun () ->
      Eio.Switch.run (fun sw ->
        let pool = Masc_http_client.Pool.create ~sw ~env () in
        let outcome = Browser_webdriver.close driver
            ~request:(request ~pool ~clock ~endpoint) in
        Eio.Promise.resolve finished outcome;
        Eio.Fiber.await_cancel ()))
    (fun () -> Eio.Promise.await result)

let start ~sw ~env =
  match configured_browser () with
  | Error detail -> Log.Server.error "browser-lane: %s" detail
  | Ok Browser_configuration.Disabled -> Log.Server.info "browser-lane: automation has no browser.webdriver_url"
  | Ok (Browser_configuration.Webdriver { endpoint; binary }) ->
    let pool = Masc_http_client.Pool.create ~sw ~env () in
    let clock = Eio.Stdenv.clock env in
    let driver = Browser_webdriver.create ?binary ~request:(request ~pool ~clock ~endpoint) () in
    Browser_lane.install_automation_executor (Some (Browser_webdriver.execute driver));
    Eio.Switch.on_release sw (fun () ->
      Browser_lane.install_automation_executor None;
      match close_with_fresh_pool ~env ~endpoint driver with
      | Ok () -> ()
      | Error error -> Log.Server.warn "browser-lane: close failed: %s"
          (Browser_webdriver.error_message error));
    Log.Server.info "browser-lane: Gecko WebDriver configured at %s" endpoint
