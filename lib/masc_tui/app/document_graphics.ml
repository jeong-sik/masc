open Masc_tui_core
open Masc_tui_term
open Masc_tui_store

type request = {
  source : string;
  colors : string * string;
  pixel_width : int;
  pixel_height : int;
}

type raster = { png : string; pixels : int * int }

type placement = {
  request : request;
  raster : raster;
  rect : Rect.t;
  kitty_cells : int * int;
}

type t = {
  mutable pending : (request * bool Atomic.t) option;
  mutable cached : (request * raster option) option;
  mutable active : placement option;
  mutable dirty : bool;
}

let create () = { pending = None; cached = None; active = None; dirty = false }

let take_dirty t =
  let dirty = t.dirty in
  t.dirty <- false;
  dirty

let same_request a b =
  String.equal a.source b.source && a.pixel_width = b.pixel_width
  && a.pixel_height = b.pixel_height
  && Pair.equal String.equal String.equal a.colors b.colors

let same_placement a b =
  same_request a.request b.request && Rect.equal a.rect b.rect
  && Pair.equal Int.equal Int.equal a.kitty_cells b.kitty_cells

let image_id = Graphics.resource_image_id 0

let wrap ~in_tmux payload =
  if in_tmux then Graphics.tmux_wrapped payload else payload

let clear t ~in_tmux =
  match t.active with
  | None -> "", false
  | Some _ ->
      t.active <- None;
      wrap ~in_tmux (Graphics.delete_image ~image_id), true

let cancel_pending t =
  Option.iter (fun (_, cancelled) -> Atomic.set cancelled true) t.pending

let request_preview t ~sw ~base_path ~on_ready request =
  let cancelled = Atomic.make false in
  t.pending <- Some (request, cancelled);
  let work () =
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
    | Ok png ->
        Option.map (fun pixels -> { png; pixels }) (Memory_diagram.parse_png_dimensions png)
    | Error _ -> None
    | exception (Sys_error _ | Unix.Unix_error _) -> None
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
      if not (Atomic.get cancelled) then t.cached <- Some (request, !result);
      t.dirty <- true;
      on_ready ();
      `Stop_daemon)

let prepare t ~sw ~base_path ~on_ready ~(probe : Probe.observation)
    ~term_program ~in_tmux ~theme grid =
  let term_program = if in_tmux then None else term_program in
  let protocol = Graphics.protocol_of_probe ~graphics:probe.graphics ~term_program in
  match protocol, Cell_grid.document_placements grid with
  | (Graphics.Unsupported_protocol | Graphics.ITerm2_protocol), _ | _, [] ->
      cancel_pending t;
      None
  | Graphics.Kitty_protocol, { image = Mermaid source; rect } :: _ ->
      let cell_width, cell_height = Option.value probe.cell_pixels ~default:(8, 16) in
      let pixel_width = Int.min 1240 (Int.max 1 (rect.w * cell_width)) in
      let pixel_height = Int.min 1240 (Int.max 1 (rect.h * cell_height)) in
      let colors =
        let palette = Option.value probe.palette ~default:(Palette.of_theme theme) in
        Pele.colors_of_palette palette
      in
      let request = { source; pixel_width; pixel_height; colors } in
      (match t.pending with
      | Some (pending, _) when not (same_request request pending) -> cancel_pending t
      | None | Some _ -> ());
      match t.cached with
      | Some (cached, raster) when same_request request cached ->
          Option.map
            (fun raster ->
              let kitty_cells =
                Graphics.fit_cells ~cell_pixels:probe.cell_pixels
                  ~image_pixels:(Some raster.pixels) ~columns:rect.w ~rows:rect.h
              in
              { request; raster; rect; kitty_cells })
            raster
      | _ ->
          if Option.is_none t.pending then request_preview t ~sw ~base_path ~on_ready request;
          None

let mask_fallback grid ~style p = Cell_grid.fill_rect grid ~rect:p.rect ~style ()

let before_present t ~in_tmux desired =
  match t.active, desired with
  | None, _ -> "", false
  | Some previous, Some next when same_placement previous next -> "", false
  | Some _, _ -> clear t ~in_tmux

let after_present t ~in_tmux ~full_repaint = function
  | None -> ""
  | Some next when not full_repaint
                   && Option.exists (fun previous -> same_placement previous next) t.active -> ""
  | Some next ->
      let cols, rows = next.kitty_cells in
      let payload =
        Graphics.replace_png ~image_id ~placement_id:1 ~data:next.raster.png
          ~rows ~cols ~crop:None
      in
      if String.equal payload "" then ""
      else begin
        t.active <- Some next;
        Printf.sprintf "\x1b7\x1b[%d;%dH%s\x1b8" (next.rect.y + 1) (next.rect.x + 1)
          (wrap ~in_tmux payload)
      end
