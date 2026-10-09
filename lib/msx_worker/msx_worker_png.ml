(* The lane retains immutable RGB strings until machine mutation. Retain one
   encoded frame by physical pixel identity and geometry; metadata is always
   captured afresh by the worker.
   Stdlib mutex protects only cache lookup/publication; it performs no I/O or
   encoding. *)
let png_mutex = Mutex.create ()
let retained_png : (int * int * string * string) option ref = ref None

let cached_png (frame : Msx_lane.frame) =
  Mutex.lock png_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock png_mutex) (fun () ->
    match !retained_png with
    | Some (width, height, rgb, png)
      when width = frame.width && height = frame.height && rgb == frame.rgb ->
        Some png
    | _ -> None)

let encode_frame (frame : Msx_lane.frame) =
  match cached_png frame with
  | Some png -> Ok png
  | None ->
      (* Expensive encoding never holds the lookup lock. Concurrent misses may
         encode independently; either published entry is valid for its key. *)
      Result.map
        (fun png ->
          Mutex.lock png_mutex;
          Fun.protect ~finally:(fun () -> Mutex.unlock png_mutex) (fun () ->
            retained_png := Some (frame.width, frame.height, frame.rgb, png));
          png)
        (Rgb_png.encode ~width:frame.width ~height:frame.height ~rgb:frame.rgb)
