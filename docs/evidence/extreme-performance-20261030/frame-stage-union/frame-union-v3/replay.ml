module Timing = Masc_tui_frame_timing
open Yojson.Safe.Util

let ns row field = row |> member field |> to_string |> Int64.of_string
let frame row = match member "frame" row with `Null -> None | value -> Some (to_int value)
let replay path =
  let channel = open_in path in
  let rows = Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
    let rec read rows = match input_line channel with
      | line -> read (if String.length line > 0 && line.[0] = '{'
          then Yojson.Safe.from_string line :: rows else rows)
      | exception End_of_file -> List.rev rows
    in read []) in
  let frames, stages = List.fold_left (fun (frames, stages) row ->
    match row |> member "schema" |> to_string with
    | "masc.tui.frame.v2" ->
        let phase = match row |> member "phase" |> to_string with
          | "build" -> Timing.Build | "present" -> Timing.Present
          | other -> invalid_arg other in
        let tag = match member "surface" row with `Null -> None | value -> Some (to_string value) in
        Timing.Samples.add_timed frames phase ~tag
          ~started_ns:(ns row "started_ns") ~completed_ns:(ns row "completed_ns")
          ~home_questions:None ~output:None, stages
    | "masc.tui.stage.v1" ->
        frames, Timing.Stage_samples.add_timed stages ~frame:(frame row)
          ~name:(row |> member "name" |> to_string)
          ~started_ns:(ns row "started_ns") ~completed_ns:(ns row "completed_ns")
    | "masc.tui.stage_note.v1" ->
        frames, Timing.Stage_samples.add stages ~frame:(frame row)
          ~name:(row |> member "name" |> to_string) ~ms:None
    | _ -> frames, stages) (Timing.Samples.empty, Timing.Stage_samples.empty) rows in
  Timing.Stage_samples.build_residuals stages frames
  |> List.map (fun (r : Timing.Stage_samples.build_residual) ->
    `Assoc ["frame",`Int r.frame; "uncovered_ns",`String (Int64.to_string r.uncovered_ns)])
  |> fun rows -> Yojson.Safe.to_channel stdout (`List rows); output_char stdout '\n'

let () = if Array.length Sys.argv <> 2 then invalid_arg "replay CAPTURE" else replay Sys.argv.(1)
