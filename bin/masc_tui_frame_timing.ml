(** Frame-time histogram for the TUI, off unless MASC_TUI_FRAME_TIMING names a
    file.

    A frame's cost was not observable: the loop draws at up to 60 Hz and the
    only signal anyone had was whether the process looked busy in [top]. That
    is enough to notice a regression the size of hashing a 60 MB binary every
    frame, and not enough to see anything smaller, or to say which half of a
    frame is expensive.

    Off by default and cheap when off: [enabled] is read once, and every entry
    point returns immediately when it is false, so a build that nobody
    instruments pays one boolean test per frame.

    Percentiles rather than a mean, because a frame loop is judged by its bad
    frames -- a p99 of 80 ms is a visible stutter that a 4 ms mean hides. *)

let output_path = Sys.getenv_opt "MASC_TUI_FRAME_TIMING"

let enabled =
  match output_path with
  | Some path -> String.trim path <> ""
  | None -> false
;;

type phase =
  | Build  (** state -> frame *)
  | Present  (** frame -> terminal *)

let phase_name = function
  | Build -> "build"
  | Present -> "present"
;;

(* Grown rather than pre-sized: a session's frame count is not known and a cap
   would silently drop the tail, which is the part worth reading. *)
let samples : (phase * int * float) list ref = ref []

(* Frame ordinal alongside the cost: a 192 ms outlier is a different problem
   depending on whether it is frame 1 -- first paint, once per session -- or
   frame 900. The number is what tells those apart. *)
let frame_counts : (phase * int ref) list =
  [ Build, ref 0; Present, ref 0 ]
;;

let count_of phase = List.assoc phase frame_counts

let record phase ~elapsed_ns =
  if enabled
  then (
    let counter = count_of phase in
    incr counter;
    samples := (phase, !counter, Int64.to_float elapsed_ns /. 1e6) :: !samples)
;;

let time phase f =
  if not enabled
  then f ()
  else begin
    let started = Mtime_clock.elapsed_ns () in
    let result = f () in
    record phase ~elapsed_ns:(Int64.sub (Mtime_clock.elapsed_ns ()) started);
    result
  end
;;

let percentile sorted p =
  match sorted with
  | [||] -> 0.0
  | arr ->
    let n = Array.length arr in
    let idx = int_of_float (Float.round (p *. float_of_int (n - 1))) in
    arr.(max 0 (min (n - 1) idx))
;;

let report_phase out phase =
  let values =
    !samples
    |> List.filter_map (fun (p, _, ms) -> if p = phase then Some ms else None)
    |> Array.of_list
  in
  Array.sort Float.compare values;
  let n = Array.length values in
  if n > 0
  then (
    let total = Array.fold_left ( +. ) 0.0 values in
    Printf.fprintf
      out
      "%s frames=%d mean=%.2fms p50=%.2f p95=%.2f p99=%.2f max=%.2f\n"
      (phase_name phase)
      n
      (total /. float_of_int n)
      (percentile values 0.50)
      (percentile values 0.95)
      (percentile values 0.99)
      values.(n - 1);
    (* The worst frames, with their ordinals, because a tail is only
       actionable once you know which frames made it. *)
    let worst =
      !samples
      |> List.filter_map (fun (p, i, ms) -> if p = phase then Some (i, ms) else None)
      |> List.sort (fun (_, a) (_, b) -> Float.compare b a)
    in
    List.iteri
      (fun rank (ordinal, ms) ->
        if rank < 5 then Printf.fprintf out "  worst[%d] frame=%d %.2fms\n" rank ordinal ms)
      worst)
;;

(* Written at exit rather than streamed: a line per frame would itself become
   part of what the frame costs. *)
let report () =
  match output_path with
  | None -> ()
  | Some path when String.trim path = "" -> ()
  | Some path ->
    (match open_out_gen [ Open_creat; Open_append; Open_wronly ] 0o600 path with
     | exception Sys_error _ -> ()
     | out ->
       Fun.protect
         ~finally:(fun () -> close_out_noerr out)
         (fun () ->
           report_phase out Build;
           report_phase out Present))
;;
