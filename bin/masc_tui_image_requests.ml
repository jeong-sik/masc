type source =
  | Retained of Tool_output.artifact_ref
  | Generated of Masc_tui_image_preview.output_source

let load ~host ~port ~cache_dir source =
  let prepare bytes =
    Masc_tui_image_cache.prepare_payload ~run:Unix.system ~cache_dir:(cache_dir ()) bytes in
  let peer path =
    match Masc_tui_http.http_get ~host ~port ~path with
    | Error _ as error -> error
    | Ok (status_code, body) when Masc.Tui_decode.is_success_http_status status_code ->
      Ok (status_code, body)
    | Ok (status_code, body) -> Error (Masc_tui_http.refusal ~status_code ~body) in
  match source with
  | Retained reference ->
    Result.bind (peer ("/api/v1/artifacts/" ^ reference.Tool_output.sha256))
      (fun (status_code, body) ->
        Eio_guard.run_in_systhread ~label:"tui-sent-image-decode" (fun () ->
          let ( let* ) = Result.bind in
          let* response = Masc_tui_http.decode_json ~allow_empty:false ~status_code ~body in
          let* bytes = Masc_tui_image_preview.decode_artifact reference response in
          prepare bytes))
  | Generated (Masc_tui_image_preview.Inline_data data) ->
    Eio_guard.run_in_systhread ~label:"tui-output-image-decode" (fun () ->
      Result.bind (Masc_tui_image_preview.decode_payload data) prepare)
  | Generated (Masc_tui_image_preview.Inline_svg svg) ->
    Eio_guard.run_in_systhread ~label:"tui-output-svg-convert" (fun () -> prepare svg)
  | Generated (Masc_tui_image_preview.Remote_uri url) ->
    Eio_guard.run_in_systhread ~label:"tui-output-image-download" (fun () ->
      Masc_tui_image_cache.prepare_png ~run:Unix.system ~cache_dir:(cache_dir ()) url)
  | Generated (Masc_tui_image_preview.Server_path path) ->
    Result.bind (peer path) (fun (_, body) ->
      Eio_guard.run_in_systhread ~label:"tui-output-image-convert" (fun () -> prepare body))
