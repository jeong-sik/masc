type source =
  | Local_file of string
  | Draft of Masc_tui_keeper_chat_projection.attachment
  | Retained of { reference : Tool_output.artifact_ref;
      format : Masc_tui_image_payload.format }
  | Board_artifact of Masc_tui_board_reader.key
  | Generated of Masc_tui_image_preview.output_source

let is_vector = function
  | Draft attachment ->
      Masc_tui_image_payload.format_of_mime attachment.Masc_tui_keeper_chat_projection.mime_type = Svg
  | Retained {format;_} -> format = Svg
  | Generated (Inline_data data) -> Masc_tui_image_payload.format data = Svg
  | Generated (Inline_svg _ | Inline_mermaid _) -> true
  | Local_file _ | Board_artifact _ | Generated (Remote_uri _ | Server_path _) -> false

let load ~host ~port ~cache_dir ~diagram_width ~diagram_height ~diagram_font_size
    ~diagram_colors ~board_worker ~admit_vector ~run ~vector_run ~display source =
  (* Non-Board vector admission runs on the owning Eio fiber immediately
     before dispatch. Board work acquires its slot in the system thread.
     After admission, withdrawal only discards the result; the physical worker
     owns its slot until it actually returns. *)
  let in_thread ~label work = match board_worker, is_vector source with
    | Some slot, _ -> Eio_guard.run_in_systhread ~label (fun () ->
        Masc_tui_board_preview_work.run slot work)
    | None, false -> Eio_guard.run_in_systhread ~label work
    | None, true ->
        (match admit_vector () with
         | Error _ as error -> error
         | Ok (worker,admission) ->
             Fun.protect ~finally:(fun () -> Masc_tui_board_preview_work.withdraw worker admission)
               (fun () -> Eio_guard.run_in_systhread ~label (fun () ->
                 match Masc_tui_board_preview_work.run_reserved worker admission work with
                 | None -> Error "vector image preparation stopped before starting"
                 | Some result -> result))) in
  let present ?scene ?(present_run=run) result = Result.bind result (fun png ->
    let valid_structure = Option.is_none board_worker || Masc_tui_image_cache.has_png_structure png in
    if not valid_structure then Error "image has an invalid or truncated PNG structure"
    else Masc_tui_image_cache.prepare_presentation ~run:present_run
      ~cache_dir:(cache_dir ()) display png
      |> Result.map (fun presentation -> presentation,scene)) in
  let prepare bytes =
    Masc_tui_image_cache.prepare_payload ~run ~cache_dir:(cache_dir ()) bytes in
  let vector format bytes =
    let render run =
    let scene = Masc_tui_pele.scene ~format ~max_width:diagram_width
      ~font_size:diagram_font_size
      ~now_ms:(Int64.of_float (Unix.gettimeofday () *. 1000.))
      ~colors:diagram_colors bytes in
    let raster = {Masc_tui_pele.width=diagram_width;height=diagram_height;crop=None} in
    let runner = Masc_tui_pele.command_runner ~run in
    present ~scene ~present_run:run (Masc_tui_pele.render ~cache_dir:(cache_dir ()) ~raster ~runner scene) in
    match board_worker, is_vector source with
    | Some _, _ -> render run
    | None, true -> render vector_run
    | None, false -> Error "vector image renderer was not admitted" in
  let prepare_declared format bytes = match format with
    | Masc_tui_image_payload.Svg ->
      vector Svg bytes
    | General_image -> present (prepare bytes) in
  let peer path =
    match Masc_tui_http.http_get ~host ~port ~path with
    | Error _ as error -> error
    | Ok (status_code, body) when Masc.Tui_decode.is_success_http_status status_code ->
      Ok (status_code, body)
    | Ok (status_code, body) -> Error (Masc_tui_http.refusal ~status_code ~body) in
  match source with
  | Local_file path ->
    in_thread ~label:"tui-local-image-read" (fun () ->
      present (Masc_tui_image_cache.prepare_file ~run ~cache_dir:(cache_dir ()) path))
  | Draft attachment ->
    in_thread ~label:"tui-draft-image-decode" (fun () ->
      let data = Masc_tui_image_payload.of_base64
        ~mime_type:attachment.Masc_tui_keeper_chat_projection.mime_type attachment.data in
      Result.bind (Masc_tui_image_payload.decode data)
        (prepare_declared (Masc_tui_image_payload.format data)))
  | Retained {reference;format} ->
    Result.bind (peer ("/api/v1/artifacts/" ^ reference.Tool_output.sha256))
      (fun (status_code, body) ->
        in_thread ~label:"tui-sent-image-decode" (fun () ->
          let open Result.Syntax in
          let* response = Masc_tui_http.decode_json ~allow_empty:false ~status_code ~body in
          let* bytes = Masc_tui_image_preview.decode_artifact reference response in
          prepare_declared format bytes))
  | Board_artifact key ->
    Result.bind
      (Masc_tui_http.get_workspace_bytes ~host ~port
         ~max_body_bytes:Masc_tui_board_upload.max_attachment_bytes
         ~path:("/api/v1/artifact-bytes/" ^ key.sha256))
      (fun bytes ->
        in_thread ~label:"tui-board-image-decode" (fun () ->
          Result.bind (Masc_tui_board_reader.validate key bytes) (fun _ ->
            prepare_declared (Masc_tui_image_payload.format_of_bytes bytes) bytes)))
  | Generated (Masc_tui_image_preview.Inline_data data) ->
    in_thread ~label:"tui-output-image-decode" (fun () ->
      Result.bind (Masc_tui_image_payload.decode data)
        (prepare_declared (Masc_tui_image_payload.format data)))
  | Generated (Masc_tui_image_preview.Inline_svg svg) ->
    in_thread ~label:"tui-output-svg-convert" (fun () -> vector Svg svg)
  | Generated (Masc_tui_image_preview.Inline_mermaid source) ->
    in_thread ~label:"tui-pele-render" (fun () -> vector Mermaid source)
  | Generated (Masc_tui_image_preview.Remote_uri url) ->
    in_thread ~label:"tui-output-image-download" (fun () ->
      present (Masc_tui_image_cache.prepare_png ~run ~cache_dir:(cache_dir ()) url))
  | Generated (Masc_tui_image_preview.Server_path path) ->
    Result.bind (peer path) (fun (_, body) ->
      in_thread ~label:"tui-output-image-convert" (fun () -> present (prepare body)))
