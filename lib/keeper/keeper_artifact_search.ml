let default_max_matches = 20
let minimum_max_matches = 1
let maximum_max_matches = 100
let maximum_needle_bytes = 512
let line_text_bytes = 240

(* One chunk is read, searched and dropped before the next, so memory stays at
   a chunk plus the unfinished line whatever the artifact size. *)
let default_chunk_bytes = 1_048_576

(* A line longer than this is skipped and counted rather than held in memory
   until its terminator arrives. A minified bundle or a one-line JSON dump is
   the usual case. *)
let default_max_line_bytes = 1_048_576

(* One call examines at most this much. The first read of an artifact already
   hashes the whole file once; this bounds the search work on top of it, and the
   caller continues from [next_offset] for the rest. *)
let default_scan_budget_bytes = 16_777_216

type spec =
  { needle : string
  ; ignore_case : bool
  ; max_matches : int
  ; start : int
  }

type hit =
  { offset : int
  ; line_bytes : int
  ; text : string
  }

type outcome =
  { hits : hit list
  ; next_offset : int
  ; total_bytes : int
  ; skipped_lines : int
  }

type 'e failure =
  | Read_failed of 'e
  | Offset_past_end of
      { offset : int
      ; total_bytes : int
      }
  | Short_read of
      { offset : int
      ; total_bytes : int
      }

let valid_utf8_prefix_length source =
  let source_length = String.length source in
  let rec loop index =
    if index = source_length
    then index
    else
      let decoded = String.get_utf_8_uchar source index in
      let decoded_length = Uchar.utf_decode_length decoded in
      if decoded_length > 0 && Uchar.utf_decode_is_valid decoded
      then loop (index + decoded_length)
      else index
  in
  loop 0
;;

let clip_text line =
  let head = String.sub line 0 (min (String.length line) line_text_bytes) in
  String.sub head 0 (valid_utf8_prefix_length head)
;;

type progress =
  { hits_rev : hit list
  ; hit_count : int
  ; skipped : int
  }

(* Everything a line needs to be judged, so complete lines and the final
   unterminated line follow one rule. *)
type judge =
  { max_matches : int
  ; max_line_bytes : int
  ; matches : string -> bool
  }

let strip_carriage_return data ~index ~newline =
  let raw_length = newline - index in
  if raw_length > 0 && String.get data (newline - 1) = '\r'
  then raw_length - 1
  else raw_length
;;

let judge_line judge progress ~offset ~line =
  let line_bytes = String.length line in
  if line_bytes > judge.max_line_bytes
  then { progress with skipped = progress.skipped + 1 }
  else if judge.matches line
  then
    { progress with
      hits_rev = { offset; line_bytes; text = clip_text line } :: progress.hits_rev
    ; hit_count = progress.hit_count + 1
    }
  else progress
;;

type consumed =
  | Tail of
      { tail_start : int
      ; progress : progress
      }
  | Limit_reached of
      { next_offset : int
      ; progress : progress
      }

(* Judge every complete line of [data], whose first byte is at absolute offset
   [base], starting at [index]. *)
let rec consume_lines judge ~data ~base ~index progress =
  match String.index_from_opt data index '\n' with
  | None -> Tail { tail_start = index; progress }
  | Some newline ->
    let line_length = strip_carriage_return data ~index ~newline in
    let line = String.sub data index line_length in
    let progress = judge_line judge progress ~offset:(base + index) ~line in
    if progress.hit_count >= judge.max_matches
    then Limit_reached { next_offset = base + newline + 1; progress }
    else consume_lines judge ~data ~base ~index:(newline + 1) progress
;;

let scan
      ?(chunk_bytes = default_chunk_bytes)
      ?(max_line_bytes = default_max_line_bytes)
      ?(scan_budget_bytes = default_scan_budget_bytes)
      ~read
      (spec : spec)
  =
  let fold = if spec.ignore_case then String.lowercase_ascii else Fun.id in
  let needle = fold spec.needle in
  let judge =
    { max_matches = spec.max_matches
    ; max_line_bytes
    ; matches = (fun line -> String_util.contains_substring (fold line) needle)
    }
  in
  let finish progress ~next_offset ~total =
    Ok
      { hits = List.rev progress.hits_rev
      ; next_offset
      ; total_bytes = total
      ; skipped_lines = progress.skipped
      }
  in
  (* [carry] is the unfinished line that starts at [carry_start]. [pos] is the
     offset of the next unread byte. [discarding] means the current line is
     longer than [max_line_bytes], its bytes are dropped as they arrive, and it
     is counted when its terminator or the end arrives. *)
  let rec step ~pos ~total ~carry ~carry_start ~discarding progress =
    if pos >= total
    then
      if discarding
      then finish { progress with skipped = progress.skipped + 1 } ~next_offset:total ~total
      else if String.equal carry ""
      then finish progress ~next_offset:total ~total
      else (
        let line_length =
          let length = String.length carry in
          if length > 0 && String.get carry (length - 1) = '\r' then length - 1 else length
        in
        let line = String.sub carry 0 line_length in
        finish
          (judge_line judge progress ~offset:carry_start ~line)
          ~next_offset:total
          ~total)
    else if
      (not discarding)
      (* A stop before the first line ends would return [spec.start] as the
         place to continue, and the caller would repeat the same scan. *)
      && carry_start > spec.start
      && pos - spec.start >= scan_budget_bytes
    then finish progress ~next_offset:carry_start ~total
    else (
      match read ~offset:pos ~max_bytes:chunk_bytes with
      | Error error -> Error (Read_failed error)
      | Ok (chunk, _) when String.equal chunk "" ->
        Error (Short_read { offset = pos; total_bytes = total })
      | Ok (chunk, _) ->
        let next_pos = pos + String.length chunk in
        if discarding
        then (
          match String.index_opt chunk '\n' with
          | None ->
            step
              ~pos:next_pos
              ~total
              ~carry:""
              ~carry_start:next_pos
              ~discarding:true
              progress
          | Some newline ->
            let progress = { progress with skipped = progress.skipped + 1 } in
            continue_with
              ~data:chunk
              ~base:pos
              ~index:(newline + 1)
              ~next_pos
              ~total
              progress)
        else
          continue_with
            ~data:(carry ^ chunk)
            ~base:carry_start
            ~index:0
            ~next_pos
            ~total
            progress)
  and continue_with ~data ~base ~index ~next_pos ~total progress =
    match consume_lines judge ~data ~base ~index progress with
    | Limit_reached { next_offset; progress } -> finish progress ~next_offset ~total
    | Tail { tail_start; progress } ->
      let tail = String.sub data tail_start (String.length data - tail_start) in
      (* One more byte than the limit: the tail may end in the ['\r'] of a
         terminator that has not arrived, and that byte is not line content. *)
      if String.length tail > max_line_bytes + 1
      then
        step
          ~pos:next_pos
          ~total
          ~carry:""
          ~carry_start:next_pos
          ~discarding:true
          progress
      else
        step
          ~pos:next_pos
          ~total
          ~carry:tail
          ~carry_start:(base + tail_start)
          ~discarding:false
          progress
  in
  (* A one-byte read reports the size without reading the artifact; the first
     read of an artifact validates it once whatever the length asked for. *)
  match read ~offset:spec.start ~max_bytes:1 with
  | Error error -> Error (Read_failed error)
  | Ok (_, total) ->
    if spec.start > total
    then Error (Offset_past_end { offset = spec.start; total_bytes = total })
    else
      step
        ~pos:spec.start
        ~total
        ~carry:""
        ~carry_start:spec.start
        ~discarding:false
        { hits_rev = []; hit_count = 0; skipped = 0 }
;;
