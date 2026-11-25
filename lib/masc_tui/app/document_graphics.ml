open Masc_tui_core
open Masc_tui_term

type mermaid_request = {
  source : string;
  colors : string * string;
  pixel_width : int;
  pixel_height : int;
}

type request =
  | Mermaid of mermaid_request
  | Embedded of Graphics.embedded_png

type raster = { png : string; pixels : int * int }

type placement = {
  image_id : int;
  request : request;
  raster : raster;
  rect : Rect.t;
  kitty_cells : int * int;
}

type t = {
  mutable pending : (request * bool Atomic.t) option;
  mutable cached : (request * raster option) list;
  mutable active : placement list;
  mutable dirty : bool;
}

let create () = { pending = None; cached = []; active = []; dirty = false }

let take_dirty t =
  let dirty = t.dirty in
  t.dirty <- false;
  dirty

let same_request a b =
  match a, b with
  | Mermaid a, Mermaid b ->
      String.equal a.source b.source && a.pixel_width = b.pixel_width
      && a.pixel_height = b.pixel_height
      && Pair.equal String.equal String.equal a.colors b.colors
  | Embedded a, Embedded b -> String.equal a.data_uri b.data_uri
  | (Mermaid _ | Embedded _), _ -> false

let same_placement a b =
  a.image_id = b.image_id && same_request a.request b.request && Rect.equal a.rect b.rect
  && Pair.equal Int.equal Int.equal a.kitty_cells b.kitty_cells

let wrap ~in_tmux payload =
  if in_tmux then Graphics.tmux_wrapped payload else payload

let delete_placements ~in_tmux placements =
  List.map
    (fun p -> wrap ~in_tmux (Graphics.delete_image ~image_id:p.image_id))
    placements
  |> String.concat ""

let clear t ~in_tmux =
  let removed = t.active in
  t.active <- [];
  delete_placements ~in_tmux removed

let cancel_pending t =
  Option.iter (fun (_, cancelled) -> Atomic.set cancelled true) t.pending

let request_preview t ~sw ~base_path ~on_ready request =
  let cancelled = Atomic.make false in
  t.pending <- Some (request, cancelled);
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
  let work () =
    match request with
    | Mermaid request -> raster_mermaid request
    | Embedded image ->
        Option.map (fun png -> { png; pixels = (image.width, image.height) })
          (Graphics.decode_embedded_png image)
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      let done_p, done_u = Eio.Promise.create () in
      let result = ref None in
      Eio.Fiber.both
        (fun () ->
          match Eio.Promise.await done_p with
          | () -> ()
          | exception (Eio.Cancel.Cancelled _ as ex) ->
              Atomic.set cancelled true;
              raise ex)
        (fun () ->
          Fun.protect ~finally:(fun () -> Eio.Promise.resolve done_u ())
            (fun () -> result := Eio_unix.run_in_systhread work));
      t.pending <- None;
      if not (Atomic.get cancelled) then t.cached <- (request, !result) :: t.cached;
      t.dirty <- true;
      on_ready ();
      `Stop_daemon)

let with_pixel_budget visible =
  let _, accepted =
    List.fold_left
      (fun (pixels, accepted) ((_, _, request) as item) ->
        let pixel_cost =
          match request with
          | Mermaid request -> request.pixel_width * request.pixel_height
          | Embedded image -> image.width * image.height
        in
        if pixel_cost > pixels then (pixels, accepted)
        else (pixels - pixel_cost, item :: accepted))
      (Graphics.document_png_pixel_budget, []) visible
  in
  List.rev accepted

let prepare t ~sw ~base_path ~on_ready ~(probe : Probe.observation) ~theme grid =
  match probe.graphics with
  | None | Some (Probe.Graphics_refused _) ->
      cancel_pending t;
      []
  | Some Probe.Graphics_supported ->
      let cell_width, cell_height = Option.value probe.cell_pixels ~default:(8, 16) in
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
               in
               Graphics.resource_image_id index, rect, request)
        |> with_pixel_budget
      in
      let is_visible request =
        List.exists (fun (_, _, current) -> same_request request current) visible
      in
      if visible <> [] then t.cached <- List.filter (fun (r, _) -> is_visible r) t.cached;
      let cached request = List.find_opt (fun (r, _) -> same_request request r) t.cached in
      (match t.pending with
      | Some (request, _) when not (is_visible request) -> cancel_pending t
      | Some _ -> ()
      | None ->
          visible
          |> List.find_opt (fun (_, _, request) -> Option.is_none (cached request))
          |> Option.iter (fun (_, _, request) -> request_preview t ~sw ~base_path ~on_ready request));
      let _, accepted =
        List.fold_left
          (fun (bytes, accepted) (image_id, (rect : Rect.t), request) ->
            match cached request with
            | None | Some (_, None) -> (bytes, accepted)
            | Some (_, Some raster) ->
                (* Kitty sends the actual PNG as padded base64. Count its
                   payload without encoding it a second time. *)
                let byte_cost = ((String.length raster.png + 2) / 3) * 4 in
                if byte_cost > bytes then (bytes, accepted)
                else
                  let kitty_cells =
                    Graphics.fit_cells ~cell_pixels:probe.cell_pixels
                      ~image_pixels:(Some raster.pixels) ~columns:rect.w ~rows:rect.h
                  in
                  let placement = { image_id; request; raster; rect; kitty_cells } in
                  (bytes - byte_cost, placement :: accepted))
          (Graphics.document_png_transfer_budget, []) visible
      in
      List.rev accepted

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
           Some (Printf.sprintf "\x1b7\x1b[%d;%dH%s\x1b8"
                   (next.rect.y + 1) (next.rect.x + 1) (wrap ~in_tmux payload)))
  |> String.concat ""
