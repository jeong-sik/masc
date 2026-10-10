(** Pure Read coordinate decoding and line-window projection. *)

type read_line_window =
  { start_line : int (* 1-based first line to return *)
  ; max_lines : int option (* cap on returned lines; None = to EOF *)
  }

type coordinate = Offset | Limit

type argument_error =
  | Invalid_integer of { coordinate : coordinate; value : Yojson.Safe.t }
  | Below_one of { coordinate : coordinate; value : int }
  | Not_an_object of Yojson.Safe.t

let of_args = function
  | `Assoc fields ->
    let open Result.Syntax in
    let integer coordinate key =
      match List.assoc_opt key fields with
      | None -> Ok None
      | Some value ->
        let parsed = match value with
          | `Int value -> Some value
          | `Intlit raw -> int_of_string_opt raw
          (* [min_int] is an exact power of two; its float negation is the
             exclusive upper index bound on both 32-bit and 64-bit OCaml. *)
          | `Float value
            when Float.is_finite value && Float.is_integer value
              && value >= float_of_int min_int
              && value < -. (float_of_int min_int) -> Some (int_of_float value)
          | `Float _ | `String _ | `Null | `Bool _ | `List _ | `Assoc _ -> None
        in
        match parsed with
        | None -> Error (Invalid_integer { coordinate; value })
        | Some value when value < 1 -> Error (Below_one { coordinate; value })
        | Some value -> Ok (Some value)
    in
    let* offset = integer Offset "offset" in
    let* max_lines = integer Limit "limit" in
    Ok { start_line = (match offset with None -> 1 | Some value -> value); max_lines }
  | value -> Error (Not_an_object value)
;;

type read_window_slice =
  { window_content : string
  ; returned_lines : int
  ; next_offset : int option (* set iff content remains past the window *)
  ; window_truncated : bool
  ; last_line_partial : bool
    (* the byte budget cut inside the final returned line; [next_offset]
       already points past that line so retrying cannot loop on it *)
  }

(* Byte index where 1-based [line] starts in [content], or None when the
   scanned content ends before that line begins. *)
let rec line_start_index content len idx line =
  if line <= 1
  then Some idx
  else if idx >= len
  then None
  else (
    match String.index_from_opt content idx '\n' with
    | None -> None
    | Some nl -> line_start_index content len (nl + 1) (line - 1))
;;

let count_returned_lines capped =
  let len = String.length capped in
  if len = 0
  then 0
  else (
    let newlines = String.fold_left (fun n c -> if c = '\n' then n + 1 else n) 0 capped in
    if capped.[len - 1] = '\n' then newlines else newlines + 1)
;;

(* [first_line] is the file line [content] begins at: 1 for a whole file or a
   prefix, [window.start_line] when the backend already streamed from there.
   [scan_complete=false] means [content] stops at a byte bound, so exhausting
   it does not prove EOF and line numbers past that bound cannot be mapped. *)
let slice_read_window ~(window : read_line_window) ~first_line ~max_bytes ~scan_complete
    content =
  let len = String.length content in
  match line_start_index content len 0 (window.start_line - first_line + 1) with
  | None ->
    if scan_complete
    then
      Ok
        { window_content = ""
        ; returned_lines = 0
        ; next_offset = None
        ; window_truncated = false
        ; last_line_partial = false
        }
    else Error `Offset_beyond_scan
  | Some start ->
    let stop =
      match window.max_lines with
      | None -> len
      | Some lines ->
        let rec advance idx remaining =
          if remaining = 0 || idx >= len
          then idx
          else (
            match String.index_from_opt content idx '\n' with
            | None -> len
            | Some nl -> advance (nl + 1) (remaining - 1))
        in
        advance start lines
    in
    let raw = String.sub content start (stop - start) in
    let raw_length = String.length raw in
    (* A prefix ending at the scan horizon may cut a line even when it fits
       the response budget. Only EOF or a newline proves that final line is
       complete; earlier requested line boundaries are already complete. *)
    let incomplete_scan_tail =
      not scan_complete && stop = len && raw_length > 0
      && raw.[raw_length - 1] <> '\n'
    in
    let capped, last_line_partial =
      if raw_length <= max_bytes && not incomplete_scan_tail
      then raw, false
      else (
        let capped_length = min raw_length max_bytes in
        match String.rindex_from_opt raw (capped_length - 1) '\n' with
        | Some nl -> String.sub raw 0 (nl + 1), false
        | None -> String.sub raw 0 capped_length, true)
    in
    let returned_lines = count_returned_lines capped in
    let consumed_to = start + String.length capped in
    let more_in_scan = consumed_to < len in
    let more_beyond_scan = (not scan_complete) && consumed_to >= len in
    let window_truncated = more_in_scan || more_beyond_scan || last_line_partial in
    let next_offset =
      if window_truncated then Some (window.start_line + returned_lines) else None
    in
    Ok
      { window_content = capped
      ; returned_lines
      ; next_offset
      ; window_truncated
      ; last_line_partial
      }
;;
