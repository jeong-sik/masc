(* SMF bytes -> what the pane shows. A cursor over the bytes, a track event
   reader per MTrk chunk, a merged tempo map for the duration. Pure: the
   fetch stays with the caller. *)

type info = {
  format : int;
  track_count : int;
  track_names : string option list;
  division_ppq : int;
  initial_bpm : int option;
  tempo_changes : (int * int) list;
  time_signatures : (int * int * int) list;
  duration_sec : float option;
}

type failure =
  | Not_midi
  | Truncated
  | Bad_varlen
  | Unsupported_division
  | Unsupported_format of int
  | Running_status_without_status
  | Bad_status of int
  | Meta_truncated

let failure_text = function
  | Not_midi -> "not a Standard MIDI file (no MThd header)"
  | Truncated -> "the file ends in the middle of a structure"
  | Bad_varlen -> "a delta time runs past four bytes"
  | Unsupported_division ->
      "0 or SMPTE time division is not supported (positive PPQ only)"
  | Unsupported_format format ->
      Printf.sprintf "MIDI format %d is not supported (0 to 2 are)" format
  | Running_status_without_status ->
      "a data byte with no status byte before it"
  | Bad_status status ->
      Printf.sprintf "status byte 0x%02X is not a track event" status
  | Meta_truncated -> "a meta event is cut off by its track's end"

(* {1 Cursor} *)

type cursor = {
  source : string;
  mutable pos : int;
}

let remaining cursor = String.length cursor.source - cursor.pos

let take cursor count =
  if remaining cursor < count then Error Truncated
  else begin
    let piece = String.sub cursor.source cursor.pos count in
    cursor.pos <- cursor.pos + count;
    Ok piece
  end

let u8 cursor =
  if remaining cursor < 1 then Error Truncated
  else begin
    let byte = Char.code cursor.source.[cursor.pos] in
    cursor.pos <- cursor.pos + 1;
    Ok byte
  end

let be16 cursor =
  Result.map
    (fun piece -> (Char.code piece.[0] lsl 8) lor Char.code piece.[1])
    (take cursor 2)

let be32 cursor =
  Result.map
    (fun piece ->
       (Char.code piece.[0] lsl 24)
       lor (Char.code piece.[1] lsl 16)
       lor (Char.code piece.[2] lsl 8)
       lor Char.code piece.[3])
    (take cursor 4)

(* A delta time: 7 bits a byte, high bit set means more, four bytes at most. *)
let varlen cursor =
  let open Result.Syntax in
  let rec loop count acc =
    if count >= 4 then Error Bad_varlen
    else
      let* byte = u8 cursor in
      let acc = (acc lsl 7) lor (byte land 0x7F) in
      if byte land 0x80 <> 0 then loop (count + 1) acc else Ok acc
  in
  loop 0 0

(* {1 Track events}

   One [MTrk] chunk's bytes, read event by event. Channel events cost their
   status byte's data length; a data byte where a status belongs re-uses the
   running status. The SMF specification cancels running status on Meta and
   SysEx, but real-world files often omit the status byte after them, so we
   permissively keep it until a new channel status replaces it. *)

let channel_data_bytes status =
  match status lsr 4 with
  | 0x8 | 0x9 | 0xA | 0xB | 0xE -> Ok 2
  | 0xC | 0xD -> Ok 1
  | _ -> Error (Bad_status status)

type events = {
  name : string option;
  end_tick : int;
  tempos : (int * int) list;  (* (tick, micros_per_quarter), ascending *)
  signatures : (int * int * int) list;  (* ascending *)
}

let bpm_of_micros micros = 60_000_000 / micros

let parse_events body =
  let open Result.Syntax in
  let cursor = { source = body; pos = 0 } in
  let name = ref None in
  let tempos = ref [] in
  let signatures = ref [] in
  let tick = ref 0 in
  let running = ref None in
  let rec loop () =
    if remaining cursor = 0 then Ok ()
    else begin
      let* delta = varlen cursor in
      tick := !tick + delta;
      let* first = u8 cursor in
      if first = 0xFF then begin
        let* event_type = u8 cursor in
        let* length = varlen cursor in
        match take cursor length with
        | Error _ -> Error Meta_truncated
        | Ok data ->
            (match event_type with
             | 0x03 when length > 0 -> name := Some data
             | 0x51 when length = 3 ->
                 let micros =
                   (Char.code data.[0] lsl 16)
                   lor (Char.code data.[1] lsl 8)
                   lor Char.code data.[2]
                 in
                 if micros > 0 then
                   tempos := (!tick, micros) :: !tempos
             | 0x58 when length = 4 ->
                 (* The wire keeps the denominator as a power of two
                    (4/4 is 04 02); the score speaks the human value. *)
                 let exponent = Char.code data.[1] in
                 if exponent <= 30 then
                   signatures :=
                     (!tick, Char.code data.[0], 1 lsl exponent) :: !signatures
             | _ -> ());
            loop ()
      end
      else if first = 0xF0 || first = 0xF7 then begin
        let* length = varlen cursor in
        let* _data = take cursor length in
        loop ()
      end
      else if first land 0x80 <> 0 then begin
        let* data_bytes = channel_data_bytes first in
        let* _data = take cursor data_bytes in
        running := Some first;
        loop ()
      end
      else begin
        match !running with
        | None -> Error Running_status_without_status
        | Some status ->
            let* data_bytes = channel_data_bytes status in
            (* The byte already read is this event's first data byte; the
               push-back puts it on the stream again, so the event costs
               [data_bytes] more, not one plus them. *)
            cursor.pos <- cursor.pos - 1;
            let* _data = take cursor data_bytes in
            loop ()
      end
    end
  in
  let* () = loop () in
  Ok
    { name = !name
    ; end_tick = !tick
    ; tempos = List.rev !tempos
    ; signatures = List.rev !signatures
    }

(* {1 Tempo map and duration}

   Every track's tempos merge into one map, ascending, one entry a tick
   (the later event wins a tie). A track's length is the sum of its
   segments, each ticks at that segment's tempo; a song whose first tempo
   comes after tick 0 keeps [None] rather than inventing what played
   before it. The song is as long as its longest track. *)

let merge_tempos tracks =
  tracks
  |> List.concat_map (fun (events : events) -> events.tempos)
  |> List.stable_sort (fun (a, _) (b, _) -> Int.compare a b)
  |> List.fold_left
       (fun merged (tick, micros) ->
          match merged with
          | (seen, _) :: rest when seen = tick -> (tick, micros) :: rest
          | _ -> (tick, micros) :: merged)
       []
  |> List.rev

let merge_signatures tracks =
  tracks
  |> List.concat_map (fun (events : events) -> events.signatures)
  |> List.stable_sort (fun (a, _, _) (b, _, _) -> Int.compare a b)
  |> List.fold_left
       (fun merged (tick, top, bottom) ->
          match merged with
          | (seen, _, _) :: rest when seen = tick -> (tick, top, bottom) :: rest
          | _ -> (tick, top, bottom) :: merged)
       []
  |> List.rev

let track_duration division tempos end_tick =
  match tempos with
  | [] -> None
  | (first_tick, _) :: _ when first_tick > 0 -> None
  | (first_tick, first_micros) :: rest ->
      let boundaries =
        List.filter (fun (tick, _) -> tick < end_tick) rest
        @ [ (end_tick, 0) ]
      in
      let rec walk prev_tick prev_micros seconds = function
        | [] -> Some seconds
        | (tick, micros) :: more ->
            let segment =
              float_of_int (tick - prev_tick)
              *. (float_of_int prev_micros /. 1_000_000.)
              /. float_of_int division
            in
            let seconds = seconds +. segment in
            (match more with
             | [] -> Some seconds
             | _ -> walk tick micros seconds more)
      in
      walk first_tick first_micros 0.0 boundaries

let duration division tracks tempos =
  let rec longest = function
    | [] -> Some 0.0
    | (events : events) :: rest -> (
        match track_duration division tempos events.end_tick with
        | None -> None
        | Some seconds -> (
            match longest rest with
            | None -> None
            | Some rest_seconds -> Some (max seconds rest_seconds)))
  in
  if tempos = [] then None else longest tracks

(* {1 File} *)

let read source =
  let open Result.Syntax in
  let cursor = { source; pos = 0 } in
  let* tag = take cursor 4 in
  if not (String.equal tag "MThd") then Error Not_midi
  else
    let* header_length = be32 cursor in
    if header_length < 6 then Error Truncated
    else begin
      let* format = be16 cursor in
      let* track_total = be16 cursor in
      let* division = be16 cursor in
      let* _rest = take cursor (header_length - 6) in
      if format < 0 || format > 2 then Error (Unsupported_format format)
      else if division <= 0 || division land 0x8000 <> 0 then
        Error Unsupported_division
      else begin
        let rec collect remaining_tracks acc =
          if remaining_tracks = 0 then Ok (List.rev acc)
          else if remaining cursor = 0 then Error Truncated
          else
            let* chunk_tag = take cursor 4 in
            let* chunk_length = be32 cursor in
            if String.equal chunk_tag "MTrk" then begin
              let* body = take cursor chunk_length in
              let* events = parse_events body in
              collect (remaining_tracks - 1) (events :: acc)
            end
            else
              (* A chunk this reader has no use for: its length is known,
                 so it is skipped whole. *)
              let* _skipped = take cursor chunk_length in
              collect remaining_tracks acc
        in
        let* tracks = collect track_total [] in
        let tempo_micros = merge_tempos tracks in
        let tempos =
          List.map (fun (tick, micros) -> (tick, bpm_of_micros micros)) tempo_micros
        in
        let signatures = merge_signatures tracks in
        Ok
          { format
          ; track_count = List.length tracks
          ; track_names = List.map (fun (events : events) -> events.name) tracks
          ; division_ppq = division
          ; initial_bpm = (match tempos with (_, bpm) :: _ -> Some bpm | [] -> None)
          ; tempo_changes = tempos
          ; time_signatures = signatures
          ; duration_sec = duration division tracks tempo_micros
          }
      end
    end

(* {1 Summary} *)

let duration_text seconds =
  let clamped = if Float.is_finite seconds && seconds >= 0.0 then seconds else 0.0 in
  let total = int_of_float (clamped +. 0.5) in
  Printf.sprintf "%d:%02d" (total / 60) (total mod 60)

let summary info =
  let pieces =
    [ Printf.sprintf "%d track%s" info.track_count
        (if info.track_count = 1 then "" else "s")
    ]
    @ (match info.initial_bpm with
       | Some bpm -> [ Printf.sprintf "%d BPM" bpm ]
       | None -> [])
    @ (match info.time_signatures with
       | (_, top, bottom) :: _ -> [ Printf.sprintf "%d/%d" top bottom ]
       | [] -> [])
    @ (match info.duration_sec with
       | Some seconds -> [ duration_text seconds ]
       | None -> [])
  in
  String.concat " · " pieces
