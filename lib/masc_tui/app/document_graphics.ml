open Masc_tui_core
open Masc_tui_term
open Masc_tui_net
open Masc_tui_protocol

type pele_request = {
  format : Pele.format;
  source : string;
  colors : string * string;
  pixel_width : int;
  pixel_height : int;
}

let equal_pele_format a b =
  match a, b with
  | Pele.Mermaid, Pele.Mermaid
  | Pele.Svg, Pele.Svg
  | Pele.Graph, Pele.Graph
  | Pele.Chart, Pele.Chart ->
      true
  | Pele.Mermaid, (Pele.Svg | Pele.Graph | Pele.Chart)
  | Pele.Svg, (Pele.Mermaid | Pele.Graph | Pele.Chart)
  | Pele.Graph, (Pele.Mermaid | Pele.Svg | Pele.Chart)
  | Pele.Chart, (Pele.Mermaid | Pele.Svg | Pele.Graph) ->
      false

type render_mode =
  | Mode_kitty
  | Mode_iterm2
  | Mode_halfblock

let equal_render_mode a b =
  match a, b with
  | Mode_kitty, Mode_kitty
  | Mode_iterm2, Mode_iterm2
  | Mode_halfblock, Mode_halfblock ->
      true
  | Mode_kitty, (Mode_iterm2 | Mode_halfblock)
  | Mode_iterm2, (Mode_kitty | Mode_halfblock)
  | Mode_halfblock, (Mode_kitty | Mode_iterm2) ->
      false

type request =
  | Pele of pele_request * render_mode
  | Embedded of Graphics.embedded_png * render_mode
  | Retained of {
      endpoint : Http_client.endpoint;
      fetch_path : string;
      mode : render_mode;
    }

type raster =
  | Raw_raster of { bytes : string; pixels : int * int; mode : render_mode }
  | Halfblock_raster of { rgba : Png_decode.rgba_image; raw_bytes : int }

type preview_result =
  | Preview_ready of raster
  | Budget_limited
  | Retry_at of Clock.Mono.t
  | Unavailable

type placement = {
  image_id : int;
  request : request;
  raster : raster;
  rect : Rect.t;
  cells : int * int;
}

type cached_preview = {
  requested : request;
  result : preview_result;
  pixel_budget : int;
  byte_budget : int;
}

type t = {
  mutable pending : (unit ref * request * (unit -> unit)) option;
  mutable retry_deadline : Clock.Mono.t option;
  mutable cached : cached_preview list;
  mutable active : placement list;
  mutable dirty : bool;
}

let create () =
  { pending = None; retry_deadline = None; cached = []; active = []; dirty = false }

let next_retry_deadline t = t.retry_deadline

let take_dirty t ~now =
  let retry_due =
    match t.retry_deadline with
    | Some deadline when Clock.Mono.compare now deadline >= 0 ->
        t.retry_deadline <- None;
        true
    | Some _ | None -> false
  in
  let dirty = t.dirty || retry_due in
  t.dirty <- false;
  dirty

let same_request a b =
  match a, b with
  | Pele (a, ma), Pele (b, mb) ->
      equal_render_mode ma mb
      && equal_pele_format a.format b.format
      && String.equal a.source b.source
      && a.pixel_width = b.pixel_width
      && a.pixel_height = b.pixel_height
      && Pair.equal String.equal String.equal a.colors b.colors
  | Embedded (a, ma), Embedded (b, mb) ->
      equal_render_mode ma mb && String.equal a.data_uri b.data_uri
  | ( Retained { endpoint = ea; fetch_path = pa; mode = ma }
    , Retained { endpoint = eb; fetch_path = pb; mode = mb } ) ->
      equal_render_mode ma mb && ea = eb && String.equal pa pb
  | (Pele _ | Embedded _ | Retained _), _ -> false

let same_placement a b =
  a.image_id = b.image_id
  && same_request a.request b.request
  && Rect.equal a.rect b.rect
  && Pair.equal Int.equal Int.equal a.cells b.cells

let is_kitty_placement p =
  match p.raster with
  | Raw_raster { mode = Mode_kitty; _ } -> true
  | Raw_raster { mode = Mode_iterm2 | Mode_halfblock; _ } | Halfblock_raster _ ->
      false

let is_iterm2_placement p =
  match p.raster with
  | Raw_raster { mode = Mode_iterm2; _ } -> true
  | Raw_raster { mode = Mode_kitty | Mode_halfblock; _ } | Halfblock_raster _ ->
      false

let delete_placements ~in_tmux placements =
  placements
  |> List.filter is_kitty_placement
  |> List.map (fun p ->
         Graphics.maybe_tmux_wrapped ~in_tmux
           (Graphics.delete_image ~image_id:p.image_id))
  |> String.concat ""

let clear t ~in_tmux =
  let removed = t.active in
  t.active <- [];
  delete_placements ~in_tmux removed

let cancel_pending t =
  t.retry_deadline <- None;
  Option.iter (fun (_, _, cancel) -> cancel ()) t.pending

let halfblock_max_px = 240
let halfblock_max_pixels = 512 * 512

let within_document_pixel_budget (w, h) =
  w > 0 && h > 0 && w <= 4096 && h <= 4096
  && w * h <= Graphics.document_png_pixel_budget

let request_preview t ~sw ~base_path ~fetch_retained ~pixels_left ~bytes_left
    ~on_ready request =
  let token = ref () in
  let cancelled = Atomic.make false in
  let cancel_p, cancel_u = Eio.Promise.create () in
  let cancel () =
    if not (Atomic.exchange cancelled true) then Eio.Promise.resolve cancel_u ()
  in
  t.pending <- Some (token, request, cancel);
  let raster_pele req mode =
    let max_width = Int.max 320 req.pixel_width in
    let scene =
      Pele.scene ~format:req.format ~max_width ~font_size:15
        ~now_ms:(Int64.of_float (Unix.gettimeofday () *. 1000.))
        ~colors:(Some req.colors) req.source
    in
    let raster : Pele.raster =
      match mode with
      | Mode_halfblock ->
          let w = Int.min halfblock_max_px (Int.max 64 req.pixel_width) in
          let h = Int.min halfblock_max_px (Int.max 48 req.pixel_height) in
          { width = w; height = h; crop = None }
      | Mode_kitty | Mode_iterm2 ->
          { width = req.pixel_width; height = req.pixel_height; crop = None }
    in
    match
      Pele.render ~cache_dir:(Pele.cache_dir ~base_path) ~raster
        ~cancelled:(fun () -> Atomic.get cancelled) scene
    with
    | Ok png -> (
        match mode with
        | Mode_halfblock -> (
            match Png_decode.decode_rgba ~max_pixels:halfblock_max_pixels png with
            | Ok rgba ->
                Some (Halfblock_raster { rgba; raw_bytes = String.length png })
            | Error _ -> None)
        | Mode_kitty | Mode_iterm2 -> (
            match Graphics.png_dimensions png with
            | Some ((width, height) as pixels)
              when width <= req.pixel_width && height <= req.pixel_height ->
                Some (Raw_raster { bytes = png; pixels; mode })
            | _ -> None))
    | Error _ -> None
    | exception (Sys_error _ | Unix.Unix_error _) -> None
  in
  let preview_of_raster = function
    | Some raster -> Preview_ready raster
    | None -> Unavailable
  in
  let decode_for_mode ~mode ~pixels_left body =
    match mode with
    | Mode_kitty -> (
        match Graphics.complete_document_png_dimensions body with
        | Some ((width, height) as pixels) when width * height <= pixels_left ->
            Preview_ready (Raw_raster { bytes = body; pixels; mode })
        | Some _ -> Budget_limited
        | None -> Unavailable)
    | Mode_iterm2 -> (
        match Png_decode.image_dimensions body with
        | Some ((width, height) as pixels) when within_document_pixel_budget pixels ->
            if width * height <= pixels_left then
              Preview_ready (Raw_raster { bytes = body; pixels; mode })
            else Budget_limited
        | Some _ | None -> Unavailable)
    | Mode_halfblock -> (
        match Png_decode.decode_rgba ~max_pixels:halfblock_max_pixels body with
        | Ok rgba ->
            if rgba.width * rgba.height <= pixels_left then
              Preview_ready
                (Halfblock_raster { rgba; raw_bytes = String.length body })
            else Budget_limited
        | Error _ -> Unavailable)
  in
  let work () =
    match request with
    | Pele (req, mode) ->
        Eio_unix.run_in_systhread (fun () ->
            preview_of_raster (raster_pele req mode))
    | Embedded (image, mode) ->
        Eio_unix.run_in_systhread (fun () ->
            match Graphics.decode_embedded_png image with
            | None -> Unavailable
            | Some png -> (
                match mode with
                | Mode_kitty | Mode_iterm2 ->
                    Preview_ready
                      (Raw_raster
                         { bytes = png; pixels = (image.width, image.height); mode })
                | Mode_halfblock -> (
                    match Png_decode.decode_rgba ~max_pixels:halfblock_max_pixels png with
                    | Ok rgba ->
                        Preview_ready
                          (Halfblock_raster { rgba; raw_bytes = String.length png })
                    | Error _ -> Unavailable)))
    | Retained { endpoint; fetch_path; mode } -> (
        let max_body_bytes = (bytes_left / 4) * 3 in
        let fetched =
          Eio.Fiber.first
            (fun () ->
              Eio.Promise.await cancel_p;
              Error Http_client.Unavailable)
            (fun () -> fetch_retained endpoint ~path:fetch_path ~max_body_bytes)
        in
        match fetched with
        | Error Http_client.Limit_exceeded -> Budget_limited
        | Error (Http_client.Retry_after delay) ->
            Retry_at (Clock.Mono.after_s (Clock.Mono.now ()) delay)
        | Error Http_client.Unavailable -> Unavailable
        | Ok _ when Atomic.get cancelled -> Unavailable
        | Ok body ->
            Eio_unix.run_in_systhread (fun () ->
                decode_for_mode ~mode ~pixels_left body))
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      let clear_own_pending () =
        match t.pending with
        | Some (tok, _, _) when tok == token -> t.pending <- None
        | Some _ | None -> ()
      in
      let done_p, done_u = Eio.Promise.create () in
      let result = ref Unavailable in
      Fun.protect ~finally:clear_own_pending (fun () ->
          Eio.Fiber.both
            (fun () ->
              match Eio.Promise.await done_p with
              | () -> ()
              | exception (Eio.Cancel.Cancelled _ as ex) ->
                  cancel ();
                  raise ex)
            (fun () ->
              Fun.protect
                ~finally:(fun () -> Eio.Promise.resolve done_u ())
                (fun () ->
                  result :=
                    try work () with
                    | Eio.Cancel.Cancelled _ as ex -> raise ex
                    | _ -> Unavailable)));
      if not (Atomic.get cancelled) then
        t.cached <-
          {
            requested = request;
            result = !result;
            pixel_budget = pixels_left;
            byte_budget = bytes_left;
          }
          :: List.filter
               (fun entry -> not (same_request request entry.requested))
               t.cached;
      t.dirty <- true;
      on_ready ();
      `Stop_daemon)

let raster_pixels = function
  | Raw_raster { pixels; _ } -> pixels
  | Halfblock_raster { rgba; _ } -> (rgba.width, rgba.height)

let raster_transfer_cost = function
  | Raw_raster { bytes; _ } -> ((String.length bytes + 2) / 3) * 4
  | Halfblock_raster { raw_bytes; _ } -> raw_bytes

let with_pixel_budget ~cached visible =
  let pixels_left, accepted =
    List.fold_left
      (fun (pixels, accepted) ((_, _, request) as item) ->
        let pixel_cost =
          match request with
          | Pele (req, _) -> req.pixel_width * req.pixel_height
          | Embedded (image, _) -> image.width * image.height
          | Retained _ -> (
              match cached request with
              | Some { result = Preview_ready r; _ } ->
                  let w, h = raster_pixels r in
                  w * h
              | Some { result = (Budget_limited | Retry_at _ | Unavailable); _ }
              | None ->
                  0)
        in
        if pixel_cost > pixels then (pixels, accepted)
        else (pixels - pixel_cost, item :: accepted))
      (Graphics.document_png_pixel_budget, [])
      visible
  in
  (pixels_left, List.rev accepted)

let fetch_path_for_mode ~mode ~path ~mime_type =
  let is_png =
    match mime_type with
    | Some m -> String.equal (String.lowercase_ascii (String.trim m)) "image/png"
    | None -> false
  in
  match mode with
  | Mode_kitty ->
      if Wire_attachment.is_attachment_path path && not is_png then
        Wire_attachment.attachment_render_path ~format:"png" path
      else path
  | Mode_iterm2 ->
      (* iTerm2 OSC 1337 renders PNG, JPEG, GIF, WebP natively. *)
      path
  | Mode_halfblock ->
      if Wire_attachment.is_attachment_path path then
        Wire_attachment.attachment_render_path ~format:"png"
          ~max_px:halfblock_max_px path
      else path

let prepare t ~sw ~now ~base_path ~endpoint ~fetch_retained ~on_ready
    ?(term_program = None) ?(in_tmux = false) ~(probe : Probe.observation)
    ~theme grid =
  t.retry_deadline <- None;
  let eff_tp = if in_tmux then None else term_program in
  let mode =
    match Graphics.protocol_of_probe ~graphics:probe.graphics ~term_program:eff_tp with
    | Graphics.Kitty_protocol -> Mode_kitty
    | Graphics.ITerm2_protocol -> Mode_iterm2
    | Graphics.Unsupported_protocol -> Mode_halfblock
  in
  let cell_width, cell_height =
    Option.value probe.cell_pixels ~default:Graphics.default_cell_pixels
  in
  let colors =
    let palette = Option.value probe.palette ~default:(Palette.of_theme theme) in
    Pele.colors_of_palette palette
  in
  let pixels cols size = Int.min 1240 (Int.max 1 (cols * size)) in
  let pele_format_of_grid = function
    | Cell_grid.Pele_mermaid -> Pele.Mermaid
    | Cell_grid.Pele_chart -> Pele.Chart
    | Cell_grid.Pele_svg -> Pele.Svg
    | Cell_grid.Pele_graph -> Pele.Graph
  in
  let visible =
    Cell_grid.document_placements grid
    |> List.filter_map (fun ({ image; rect } : Cell_grid.document_placement) ->
           match image, mode with
           | Mermaid _, Mode_halfblock ->
               (* Mermaid already paints crisp ASCII diagram fallback in text mode. *)
               None
           | Mermaid source, (Mode_kitty | Mode_iterm2) ->
               Some
                 ( rect
                 , Pele
                     ( {
                         format = Pele.Mermaid;
                         source;
                         pixel_width = pixels rect.w cell_width;
                         pixel_height = pixels rect.h cell_height;
                         colors;
                       }
                     , mode ) )
           | Pele_scene { format; source }, _ ->
               Some
                 ( rect
                 , Pele
                     ( {
                         format = pele_format_of_grid format;
                         source;
                         pixel_width = pixels rect.w cell_width;
                         pixel_height = pixels rect.h cell_height;
                         colors;
                       }
                     , mode ) )
           | Embedded_png image, _ -> Some (rect, Embedded (image, mode))
           | Retained_png path, _ ->
               let fetch_path =
                 fetch_path_for_mode ~mode ~path ~mime_type:(Some "image/png")
               in
               Some (rect, Retained { endpoint; fetch_path; mode })
           | Retained_image { path; mime_type }, _ ->
               let fetch_path = fetch_path_for_mode ~mode ~path ~mime_type in
               Some (rect, Retained { endpoint; fetch_path; mode }))
    |> List.mapi (fun index (rect, request) ->
           (Graphics.resource_image_id index, rect, request))
  in
  if visible = [] then begin
    cancel_pending t;
    []
  end
  else
    let cached request =
      List.find_opt (fun entry -> same_request request entry.requested) t.cached
    in
    let pixels_left, visible = with_pixel_budget ~cached visible in
    let bytes_left, placements =
      List.fold_left
        (fun (bytes, placements) (image_id, (rect : Rect.t), request) ->
          match cached request with
          | None
          | Some { result = (Budget_limited | Retry_at _ | Unavailable); _ } ->
              (bytes, placements)
          | Some { result = Preview_ready raster; _ } ->
              let byte_cost = raster_transfer_cost raster in
              if byte_cost > bytes then (bytes, placements)
              else
                let img_px = raster_pixels raster in
                let cells =
                  match raster with
                  | Raw_raster { mode = Mode_kitty; _ } ->
                      Graphics.fit_cells ~cell_pixels:probe.cell_pixels
                        ~image_pixels:(Some img_px) ~columns:rect.w ~rows:rect.h
                  | Raw_raster { mode = Mode_iterm2 | Mode_halfblock; _ } ->
                      (rect.w, rect.h)
                  | Halfblock_raster _ ->
                      Halfblock.fit_cells ~image_pixels:img_px ~columns:rect.w
                        ~rows:rect.h
                in
                let placement = { image_id; request; raster; rect; cells } in
                (bytes - byte_cost, placement :: placements))
        (Graphics.document_png_transfer_budget, [])
        visible
    in
    let is_visible request =
      List.exists (fun (_, _, current) -> same_request request current) visible
    in
    t.cached <-
      List.filter
        (fun entry ->
          is_visible entry.requested
          ||
          match entry.result with
          | Retry_at retry_at -> Clock.Mono.compare now retry_at < 0
          | Preview_ready _ | Budget_limited | Unavailable -> visible = [])
        t.cached;
    (match t.pending with
    | Some (_, request, _) when not (is_visible request) -> cancel_pending t
    | Some _ -> ()
    | None ->
        let retained_fits = pixels_left > 0 && bytes_left >= 4 in
        let ready (_, _, request) =
          match request, cached request with
          | Retained _, None -> retained_fits
          | ( Retained _
            , Some { result = Budget_limited; pixel_budget; byte_budget; _ } ) ->
              retained_fits
              && (pixels_left > pixel_budget || bytes_left > byte_budget)
          | Retained _, Some { result = Retry_at retry_at; _ } ->
              retained_fits && Clock.Mono.compare now retry_at >= 0
          | (Pele _ | Embedded _), None -> true
          | (Pele _ | Embedded _), Some _
          | Retained _, Some { result = (Preview_ready _ | Unavailable); _ } ->
              false
        in
        match List.find_opt ready visible with
        | Some (_, _, request) ->
            request_preview t ~sw ~base_path ~fetch_retained ~pixels_left
              ~bytes_left ~on_ready request
        | None when retained_fits ->
            t.retry_deadline <-
              List.fold_left
                (fun earliest (_, _, request) ->
                  match cached request with
                  | Some { result = Retry_at retry_at; _ } ->
                      Some
                        (Clock.Mono.min retry_at
                           (Option.value earliest ~default:retry_at))
                  | Some
                      {
                        result = Preview_ready _ | Budget_limited | Unavailable;
                        _;
                      }
                  | None ->
                      earliest)
                None visible
        | None -> ());
    List.rev placements

let mask_fallback ?(bg_rgb = 0x111111) grid ~style p =
  Cell_grid.fill_rect grid ~rect:p.rect ~style ();
  match p.raster with
  | Halfblock_raster { rgba; _ } ->
      Halfblock.draw_rgba ~bg_rgb grid ~rect:p.rect rgba
  | Raw_raster _ -> ()

type before_present_effect = {
  escape_bytes : string;
  invalidate_screen : bool;
}

let before_present t ~in_tmux desired =
  let retained, removed =
    List.partition (fun p -> List.exists (same_placement p) desired) t.active
  in
  t.active <- retained;
  {
    escape_bytes = delete_placements ~in_tmux removed;
    invalidate_screen = List.exists is_iterm2_placement removed;
  }

let after_present t ~in_tmux ~full_repaint desired =
  let previous = t.active in
  t.active <- desired;
  desired
  |> List.filter_map (fun next ->
         match next.raster with
         | Halfblock_raster _ -> None
         | Raw_raster { bytes; mode; _ } ->
             if not full_repaint && List.exists (same_placement next) previous
             then None
             else
               let cols, rows = next.cells in
               let payload =
                 match mode with
                 | Mode_kitty ->
                     Graphics.replace_png ~image_id:next.image_id
                       ~placement_id:1 ~data:bytes ~rows ~cols ~crop:None
                 | Mode_iterm2 ->
                     Graphics.iterm2_place ~data:bytes
                       { Graphics.columns = cols; rows }
                 | Mode_halfblock -> ""
               in
               let placed =
                 Graphics.place_at_cursor ~in_tmux ~row:(next.rect.y + 1)
                   ~col:(next.rect.x + 1) payload
               in
               if String.equal placed "" then None else Some placed)
  |> String.concat ""
