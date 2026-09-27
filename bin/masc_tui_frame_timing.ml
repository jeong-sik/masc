(** Frame-time histogram for the TUI, off unless MASC_TUI_FRAME_TIMING names a
    file.

    A frame's cost was not observable: the loop draws at up to 60 Hz and the
    only signal anyone had was whether the process looked busy in [top]. That
    is enough to notice a regression the size of hashing a 60 MB binary every
    frame, and not enough to see anything smaller, or to say which half of a
    frame is expensive, or which surface.

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

module Samples = struct
  type sample =
    { phase : phase;
      tag : string option;
      ordinal : int;
      ms : float;
    }

  (* Newest first, grown rather than pre-sized: a session's frame count is not
     known and a cap would silently drop the tail, which is the part worth
     reading. *)
  type t =
    { samples : sample list;
      build_count : int;
      present_count : int;
    }

  let empty = { samples = []; build_count = 0; present_count = 0 }

  (* Frame ordinal alongside the cost: a 192 ms outlier is a different problem
     depending on whether it is frame 1 -- first paint, once per session -- or
     frame 900. The number is what tells those apart. *)
  let add t phase ~tag ~ms =
    match phase with
    | Build ->
        let ordinal = t.build_count + 1 in
        { t with
          samples = { phase; tag; ordinal; ms } :: t.samples;
          build_count = ordinal
        }
    | Present ->
        let ordinal = t.present_count + 1 in
        { t with
          samples = { phase; tag; ordinal; ms } :: t.samples;
          present_count = ordinal
        }
  ;;

  let percentile sorted p =
    match sorted with
    | [||] -> 0.0
    | arr ->
        let n = Array.length arr in
        let idx = int_of_float (Float.round (p *. float_of_int (n - 1))) in
        arr.(max 0 (min (n - 1) idx))
  ;;

  let stats_line label values =
    let values = Array.of_list values in
    Array.sort Float.compare values;
    let n = Array.length values in
    let total = Array.fold_left ( +. ) 0.0 values in
    Printf.sprintf
      "%s frames=%d mean=%.2fms p50=%.2f p95=%.2f p99=%.2f max=%.2f"
      label
      n
      (total /. float_of_int n)
      (percentile values 0.50)
      (percentile values 0.95)
      (percentile values 0.99)
      values.(n - 1)
  ;;

  let tag_text = function
    | None -> ""
    | Some tag -> Printf.sprintf " tag=%s" tag
  ;;

  let phase_lines t phase =
    let mine = List.filter (fun sample -> sample.phase = phase) t.samples in
    match mine with
    | [] -> []
    | _ ->
        let name = phase_name phase in
        let overall = stats_line name (List.map (fun s -> s.ms) mine) in
        (* Per tag, most frames first: the surface the operator spent the
           session on is the one whose tail matters. *)
        let tags =
          List.fold_left
            (fun tags sample ->
              match sample.tag with
              | None -> tags
              | Some tag ->
                  if List.mem tag tags then tags else tag :: tags)
            [] mine
          |> List.rev
        in
        let per_tag =
          tags
          |> List.map (fun tag ->
                 let values =
                   List.filter_map
                     (fun s ->
                       if s.tag = Some tag then Some s.ms else None)
                     mine
                 in
                 (List.length values, tag, values))
          |> List.stable_sort (fun (a, _, _) (b, _, _) -> compare b a)
          |> List.map (fun (_, tag, values) ->
                 "  " ^ stats_line (Printf.sprintf "%s[%s]" name tag) values)
        in
        (* The worst frames, with their ordinals, because a tail is only
           actionable once you know which frames made it. *)
        let worst =
          mine
          |> List.sort (fun a b -> Float.compare b.ms a.ms)
          |> List.filteri (fun rank _ -> rank < 5)
          |> List.mapi (fun rank s ->
                 Printf.sprintf
                   "  worst[%d] frame=%d %.2fms%s"
                   rank
                   s.ordinal
                   s.ms
                   (tag_text s.tag))
        in
        (overall :: per_tag) @ worst
  ;;

  let summary_lines t = phase_lines t Build @ phase_lines t Present
end

module Stage_samples = struct
  type sample = { frame : int option; name : string; ms : float option }
  type t = sample list

  let empty = []
  let add t ~frame ~name ~ms = { frame; name; ms } :: t

  let summary_lines t =
    let samples = List.rev t in
    let groups = Hashtbl.create 16 in
    List.iter
      (fun sample ->
        let key = sample.frame, sample.name in
        let count, total, measured =
          Option.value ~default:(0, 0.0, false) (Hashtbl.find_opt groups key)
        in
        Hashtbl.replace groups key
          ( count + 1,
            total +. Option.value ~default:0.0 sample.ms,
            measured || Option.is_some sample.ms ))
      samples;
    let grouped =
      Hashtbl.fold (fun key value pairs -> (key, value) :: pairs) groups []
      |> List.sort (fun ((frame_a, name_a), _) ((frame_b, name_b), _) ->
           let by_frame = compare frame_a frame_b in
           if by_frame = 0 then String.compare name_a name_b else by_frame)
    in
    let populations = Hashtbl.create 16 in
    let add_population key ms =
      let prior = Option.value ~default:[] (Hashtbl.find_opt populations key) in
      Hashtbl.replace populations key (ms :: prior)
    in
    List.iter
      (fun ((frame, name), (_, total, measured)) ->
        match frame, measured with
        | Some _, true -> add_population (true, name) total
        | None, _ | _, false -> ())
      grouped;
    (* A Build frame contributes one summed sample per stage. Outside Build
       there is no frame key, so each timed call is its own population member. *)
    List.iter
      (fun sample ->
        match sample.frame, sample.ms with
        | None, Some ms -> add_population (false, sample.name) ms
        | Some _, _ | None, None -> ())
      samples;
    let population_lines =
      Hashtbl.fold (fun key values lines -> (key, values) :: lines) populations []
      |> List.sort (fun (a, _) (b, _) -> compare a b)
      |> List.map (fun ((inside_build, name), values) ->
           let values = Array.of_list values in
           Array.sort Float.compare values;
           let n = Array.length values in
           Printf.sprintf "  stage[%s] %s=%d p50=%.3fms p95=%.3f max=%.3f"
             name (if inside_build then "frames" else "calls") n
             (Samples.percentile values 0.50)
             (Samples.percentile values 0.95) values.(n - 1))
    in
    let frame_lines =
      List.map (fun ((frame, name), (count, total, measured)) ->
        let location =
          match frame with
          | Some frame -> Printf.sprintf "frame=%d" frame
          | None -> "outside-build"
        in
        let value =
          if measured then Printf.sprintf "ms=%.3f calls=%d" total count
          else Printf.sprintf "note calls=%d" count
        in
        Printf.sprintf "  stage %s name=%s %s" location name value) grouped
    in
    population_lines @ frame_lines

  let residual_lines t frames =
    let totals = Hashtbl.create 16 in
    List.iter
      (fun sample ->
        match sample.frame, sample.ms with
        | Some frame, Some ms ->
            let prior = Option.value ~default:0.0 (Hashtbl.find_opt totals frame) in
            Hashtbl.replace totals frame (prior +. ms)
        | None, _ | _, None -> ())
      t;
    frames.Samples.samples
    |> List.filter (fun (sample : Samples.sample) ->
         sample.phase = Build && Hashtbl.mem totals sample.ordinal)
    |> List.rev
    |> List.map (fun (sample : Samples.sample) ->
         let measured =
           Option.value ~default:0.0 (Hashtbl.find_opt totals sample.ordinal)
         in
         Printf.sprintf
           "  stage frame=%d name=unattributed ms=%.3f (includes timing overhead)"
           sample.ordinal (max 0.0 (sample.ms -. measured)))
end

let samples = ref Samples.empty
let stage_samples = ref Stage_samples.empty
let active_build_frame = ref None

let record_stage ~name ~ms =
  stage_samples :=
    Stage_samples.add !stage_samples ~frame:!active_build_frame ~name ~ms
;;

let note_stage ~name =
  if enabled then record_stage ~name ~ms:None
;;

let time_stage_tagged ~name f =
  if not enabled then f ()
  else begin
    let started = Mtime_clock.elapsed_ns () in
    let result = f () in
    let elapsed_ns = Int64.sub (Mtime_clock.elapsed_ns ()) started in
    record_stage ~name:(name result) ~ms:(Some (Int64.to_float elapsed_ns /. 1e6));
    result
  end
;;

let time_stage ~name f = time_stage_tagged ~name:(fun _ -> name) f

let start_stage () =
  if enabled then Some (Mtime_clock.elapsed_ns ()) else None
;;

let finish_stage ~name = function
  | None -> ()
  | Some started ->
      let elapsed_ns = Int64.sub (Mtime_clock.elapsed_ns ()) started in
      record_stage ~name ~ms:(Some (Int64.to_float elapsed_ns /. 1e6))
;;

let record phase ~tag ~elapsed_ns =
  if enabled
  then
    samples :=
      Samples.add
        !samples
        phase
        ~tag
        ~ms:(Int64.to_float elapsed_ns /. 1e6)
;;

let within_phase phase f =
  match phase with
  | Present -> f ()
  | Build ->
      let previous = !active_build_frame in
      active_build_frame := Some ((!samples).Samples.build_count + 1);
      Fun.protect ~finally:(fun () -> active_build_frame := previous) f
;;

let time_tagged phase ~tag f =
  if not enabled
  then f ()
  else begin
    let started = Mtime_clock.elapsed_ns () in
    let result = within_phase phase f in
    let elapsed_ns = Int64.sub (Mtime_clock.elapsed_ns ()) started in
    record phase ~tag:(Some (tag result)) ~elapsed_ns;
    result
  end
;;

let time phase f =
  if not enabled
  then f ()
  else begin
    let started = Mtime_clock.elapsed_ns () in
    let result = within_phase phase f in
    record phase ~tag:None ~elapsed_ns:(Int64.sub (Mtime_clock.elapsed_ns ()) started);
    result
  end
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
           List.iter
             (fun line -> output_string out (line ^ "\n"))
             (Samples.summary_lines !samples
              @ Stage_samples.summary_lines !stage_samples
              @ Stage_samples.residual_lines !stage_samples !samples)))
;;
