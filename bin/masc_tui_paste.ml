type t = {
  text : string;
  dropped : int;
}

let end_marker = "\x1b[201~"
let max_bytes = 1_048_576

(* A line break in pasted text is whatever the sender's terminal writes for
   one, and terminals disagree: CR, LF, or CRLF, depending on the emulator and
   on what was on the clipboard. The draft holds LF -- that is what Ctrl-J
   puts there, what the composer lays out, and the only break
   [terminal_safe_text] keeps -- so a CR that arrived as a line break has to
   become one here or it is sanitized into a space and the paste comes out as
   one long line. *)
let newlines_normalized text =
  let output = Buffer.create (String.length text) in
  let length = String.length text in
  let rec loop offset =
    if offset < length then
      match text.[offset] with
      | '\r' ->
          Buffer.add_char output '\n';
          (* CRLF is one break, not two. *)
          if offset + 1 < length && text.[offset + 1] = '\n' then loop (offset + 2)
          else loop (offset + 1)
      | byte ->
          Buffer.add_char output byte;
          loop (offset + 1)
  in
  loop 0;
  Buffer.contents output

(* The marker does not appear inside the payload: a terminal with bracketed
   paste on removes it from the pasted text, which is what the mode is for.
   The partial-match handling is still needed for a terminal that sends a bare
   ESC, and it is correct for this marker in particular -- ESC occurs only at
   its first byte, so a broken match can restart only on ESC, and re-testing
   the byte that broke it against the first byte covers every restart. A
   marker whose bytes repeat (say "aab") would need the real fallback table;
   this one does not have that shape. *)
let read ~next_byte =
  let text = Buffer.create 4096 in
  let dropped = ref 0 in
  let matched = ref 0 in
  let marker_length = String.length end_marker in
  (* Counting before the append keeps a large paste linear; appending and then
     trimming would recopy the whole buffer once per byte. *)
  let keep string =
    let room = max 0 (max_bytes - Buffer.length text) in
    let length = String.length string in
    if length <= room then Buffer.add_string text string
    else begin
      if room > 0 then Buffer.add_string text (String.sub string 0 room);
      dropped := !dropped + (length - room)
    end
  in
  let finished = ref false in
  let ended = ref false in
  while not (!finished || !ended) do
    match next_byte () with
    | None -> ended := true
    | Some byte ->
        if byte = end_marker.[!matched] then begin
          incr matched;
          if !matched = marker_length then finished := true
        end
        else begin
          keep (String.sub end_marker 0 !matched);
          matched := 0;
          if byte = end_marker.[0] then matched := 1
          else keep (String.make 1 byte)
        end
  done;
  (* A partial match the stream ended on is payload the operator typed, not a
     marker that never came. *)
  if !ended && !matched > 0 then keep (String.sub end_marker 0 !matched);
  { text = newlines_normalized (Buffer.contents text); dropped = !dropped }
