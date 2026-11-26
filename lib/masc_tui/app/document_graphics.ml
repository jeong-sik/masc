open Masc_tui_core
open Masc_tui_term
open Masc_tui_net

type mermaid_request = {
  source : string;
  colors : string * string;
  pixel_width : int;
  pixel_height : int;
}

type request =
  | Mermaid of mermaid_request
  | Embedded of Graphics.embedded_png
  | Retained of Http_client.endpoint * string

type raster = { png : string; pixels : int * int }

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
  kitty_cells : int * int;
}

type cached_preview = {
  requested : request;
  result : preview_result;
  pixel_budget : int;
  byte_budget : int;
}

type t = {
  mutable pending : (request * (unit -> unit)) option;
  mutable retry_deadline : Clock.Mono.t option;
  mutable cached : cached_preview list;
  mutable active : placement list;
  mutable dirty : bool;
}

let create () = { pending = None; retry_deadline = None; cached = []; active = []; dirty = false }

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
  | Mermaid a, Mermaid b ->
      String.equal a.source b.source && a.pixel_width = b.pixel_width
      && a.pixel_height = b.pixel_height
      && Pair.equal String.equal String.equal a.colors b.colors
  | Embedded a, Embedded b -> String.equal a.data_uri b.data_uri
  | Retained (a, path_a), Retained (b, path_b) -> a = b && String.equal path_a path_b
  | (Mermaid _ | Embedded _ | Retained _), _ -> false

let same_placement a b =
  a.image_id = b.image_id && same_request a.request b.request && Rect.equal a.rect b.rect
  && Pair.equal Int.equal Int.equal a.kitty_cells b.kitty_cells

let delete_placements ~in_tmux placements =
  List.map
    (fun p ->
      Graphics.maybe_tmux_wrapped ~in_tmux
        (Graphics.delete_image ~image_id:p.image_id))
    placements
  |> String.concat ""

let clear t ~in_tmux =
  let removed = t.active in
  t.active <- [];
  delete_placements ~in_tmux removed

let cancel_pending t =
  t.retry_deadline <- None;
  Option.iter (fun (_, cancel) -> cancel ()) t.pending

let request_preview t ~sw ~base_path ~fetch_retained ~pixels_left ~bytes_left ~on_ready request =
  let cancelled = Atomic.make false in
  let cancel_p, cancel_u = Eio.Promise.create () in
  let cancel () =
    if not (Atomic.exchange cancelled true) then Eio.Promise.resolve cancel_u ()
  in
  t.pending <- Some (request, cancel);
  let raster_mermaid request =
    let max_width = Int.max 320 request.pixel_width in
    let scene =
      Pele.scene ~format:Pele.Mermaid ~max_width ~font_size:15
        ~now_ms:(Int64.of_float (Unix.gettimeofday () *. 1000.))
        ~colors:(Some request.colors) request.source
    in
    let raster : Pele.raster =
      { width = request.pixel_width; height = request.pixel_height; crop = None }
    in
    match
      Pele.render ~cache_dir:(Pele.cache_dir ~base_path) ~raster
        ~cancelled:(fun () -> Atomic.get cancelled) scene
    with
    | Ok png -> (
        match Graphics.png_dimensions png with
        | Some ((width, height) as pixels)
          when width <= request.pixel_width && height <= request.pixel_height ->
            Some { png; pixels }
        | _ -> None)
    | Error _ -> None
    | exception (Sys_error _ | Unix.Unix_error _) -> None
  in
  let preview_of_raster = function
    | Some raster -> Preview_ready raster
    | None -> Unavailable
  in
  let work () =
    match request with
    | Mermaid request ->
        Eio_unix.run_in_systhread (fun () -> preview_of_raster (raster_mermaid request))
    | Embedded image ->
        Eio_unix.run_in_systhread (fun () ->
            Option.map (fun png -> { png; pixels = (image.width, image.height) })
              (Graphics.decode_embedded_png image)
            |> preview_of_raster)
    | Retained (endpoint, path) ->
        let max_body_bytes = (bytes_left / 4) * 3 in
        let fetched =
          Eio.Fiber.first
            (fun () -> Eio.Promise.await cancel_p; Error Http_client.Unavailable)
            (fun () -> fetch_retained endpoint ~path ~max_body_bytes)
        in
        match fetched with
        | Error Http_client.Limit_exceeded -> Budget_limited
        | Error (Http_client.Retry_after delay) ->
            Retry_at (Clock.Mono.after_s (Clock.Mono.now ()) delay)
        | Error Http_client.Unavailable -> Unavailable
        | Ok _ when Atomic.get cancelled -> Unavailable
        | Ok png ->
            Eio_unix.run_in_systhread (fun () ->
                match Graphics.complete_document_png_dimensions png with
                | Some ((width, height) as pixels) when width * height <= pixels_left ->
                    Preview_ready { png; pixels }
                | Some _ -> Budget_limited
                | None -> Unavailable)
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      let done_p, done_u = Eio.Promise.create () in
      let result = ref Unavailable in
      Eio.Fiber.both
        (fun () ->
          match Eio.Promise.await done_p with
          | () -> ()
          | exception (Eio.Cancel.Cancelled _ as ex) ->
              cancel ();
              raise ex)
        (fun () ->
          Fun.protect ~finally:(fun () -> Eio.Promise.resolve done_u ())
            (fun () -> result := work ()));
      t.pending <- None;
      if not (Atomic.get cancelled) then
        t.cached <-
          { requested = request; result = !result; pixel_budget = pixels_left; byte_budget = bytes_left }
          :: List.filter (fun entry -> not (same_request request entry.requested)) t.cached;
      t.dirty <- true;
      on_ready ();
      `Stop_daemon)

let with_pixel_budget ~cached visible =
  let pixels_left, accepted =
    List.fold_left
      (fun (pixels, accepted) ((_, _, request) as item) ->
        let pixel_cost =
          match request with
          | Mermaid request -> request.pixel_width * request.pixel_height
          | Embedded image -> image.width * image.height
          | Retained _ -> (
              match cached request with
              | Some { result = Preview_ready { pixels = width, height; _ }; _ } -> width * height
              | Some { result = (Budget_limited | Retry_at _ | Unavailable); _ }
              | None -> 0)
        in
        if pixel_cost > pixels then (pixels, accepted)
        else (pixels - pixel_cost, item :: accepted))
      (Graphics.document_png_pixel_budget, []) visible
  in
  (pixels_left, List.rev accepted)

let prepare t ~sw ~now ~base_path ~endpoint ~fetch_retained ~on_ready
    ~(probe : Probe.observation) ~theme grid =
  t.retry_deadline <- None;
  match probe.graphics with
  | None | Some (Probe.Graphics_refused _) ->
      cancel_pending t;
      []
  | Some Probe.Graphics_supported ->
      let cell_width, cell_height =
        Option.value probe.cell_pixels ~default:Graphics.default_cell_pixels
      in
      let colors =
        let palette = Option.value probe.palette ~default:(Palette.of_theme theme) in
        Pele.colors_of_palette palette
      in
      let pixels cols size = Int.min 1240 (Int.max 1 (cols * size)) in
      let visible =
        Cell_grid.document_placements grid
        |> List.mapi (fun index ({ image; rect } : Cell_grid.document_placement) ->
               let request =
                 match image with
                 | Mermaid source ->
                     Mermaid
                       { source; pixel_width = pixels rect.w cell_width;
                         pixel_height = pixels rect.h cell_height; colors }
                 | Embedded_png image -> Embedded image
                 | Retained_png path -> Retained (endpoint, path)
               in
               Graphics.resource_image_id index, rect, request)
      in
      let cached request = List.find_opt (fun entry -> same_request request entry.requested) t.cached in
      let pixels_left, visible = with_pixel_budget ~cached visible in
      let bytes_left, placements =
        List.fold_left
          (fun (bytes, placements) (image_id, (rect : Rect.t), request) ->
            match cached request with
            | None | Some { result = (Budget_limited | Retry_at _ | Unavailable); _ } ->
                (bytes, placements)
            | Some { result = Preview_ready raster; _ } ->
                (* Kitty sends the actual PNG as padded base64. Count its
                   payload without encoding it a second time. *)
                let byte_cost = ((String.length raster.png + 2) / 3) * 4 in
                if byte_cost > bytes then (bytes, placements)
                else
                  let kitty_cells =
                    Graphics.fit_cells ~cell_pixels:probe.cell_pixels
                      ~image_pixels:(Some raster.pixels) ~columns:rect.w ~rows:rect.h
                  in
                  let placement = { image_id; request; raster; rect; kitty_cells } in
                  (bytes - byte_cost, placement :: placements))
          (Graphics.document_png_transfer_budget, []) visible
      in
      let is_visible request =
        List.exists (fun (_, _, current) -> same_request request current) visible
      in
      t.cached <-
        List.filter
          (fun entry ->
            is_visible entry.requested
            || match entry.result with
               | Retry_at retry_at -> Clock.Mono.compare now retry_at < 0
               | Preview_ready _ | Budget_limited | Unavailable -> visible = [])
          t.cached;
      (match t.pending with
      | Some (request, _) when not (is_visible request) -> cancel_pending t
      | Some _ -> ()
      | None ->
          let retained_fits = pixels_left > 0 && bytes_left >= 4 in
          let ready (_, _, request) =
            match request, cached request with
            | Retained _, None -> retained_fits
            | Retained _, Some { result = Budget_limited; pixel_budget; byte_budget; _ } ->
                retained_fits && (pixels_left > pixel_budget || bytes_left > byte_budget)
            | Retained _, Some { result = Retry_at retry_at; _ } ->
                retained_fits && Clock.Mono.compare now retry_at >= 0
            | (Mermaid _ | Embedded _), None -> true
            | (Mermaid _ | Embedded _), Some _
            | Retained _, Some { result = (Preview_ready _ | Unavailable); _ } -> false
          in
          match List.find_opt ready visible with
          | Some (_, _, request) ->
              request_preview t ~sw ~base_path ~fetch_retained ~pixels_left ~bytes_left ~on_ready request
          | None when retained_fits ->
              (* A cooling-down image leaves the fetch slot free for other previews. *)
              t.retry_deadline <-
                List.fold_left
                  (fun earliest (_, _, request) ->
                    match cached request with
                    | Some { result = Retry_at retry_at; _ } ->
                        Some (Clock.Mono.min retry_at (Option.value earliest ~default:retry_at))
                    | Some { result = (Preview_ready _ | Budget_limited | Unavailable); _ }
                    | None -> earliest)
                  None visible
          | None -> ());
      List.rev placements

let mask_fallback grid ~style p = Cell_grid.fill_rect grid ~rect:p.rect ~style ()

let before_present t ~in_tmux desired =
  let retained, removed =
    List.partition (fun p -> List.exists (same_placement p) desired) t.active
  in
  t.active <- retained;
  delete_placements ~in_tmux removed

let after_present t ~in_tmux ~full_repaint desired =
  let previous = t.active in
  t.active <- desired;
  desired
  |> List.filter_map (fun next ->
         if not full_repaint && List.exists (same_placement next) previous then None
         else
           let cols, rows = next.kitty_cells in
           let payload =
             Graphics.replace_png ~image_id:next.image_id ~placement_id:1 ~data:next.raster.png
               ~rows ~cols ~crop:None
           in
           let placed =
             Graphics.place_at_cursor ~in_tmux ~row:(next.rect.y + 1)
               ~col:(next.rect.x + 1) payload
           in
           if String.equal placed "" then None else Some placed)
  |> String.concat ""
