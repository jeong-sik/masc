type t = {
  text : string;
  dropped : int;
}

let end_marker = "\x1b[201~"
let max_bytes = 1_048_576

type decoder = {
  text : Buffer.t;
  mutable dropped : int;
  mutable matched : int;
}

let create () = { text = Buffer.create 4096; dropped = 0; matched = 0 }

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
let keep decoder string =
  let room = max 0 (max_bytes - Buffer.length decoder.text) in
  let length = String.length string in
  if length <= room then Buffer.add_string decoder.text string
  else begin
    if room > 0 then Buffer.add_string decoder.text (String.sub string 0 room);
    decoder.dropped <- decoder.dropped + (length - room)
  end

let contents decoder =
  { text = newlines_normalized (Buffer.contents decoder.text);
    dropped = decoder.dropped }

let finish_unterminated decoder =
  (* A terminal can lose the end marker partway through. Those bytes still
     belong to the draft if the operator ends the stalled paste explicitly. *)
  if decoder.matched > 0 then
    keep decoder (String.sub end_marker 0 decoder.matched);
  decoder.matched <- 0;
  contents decoder

let snapshot_payload decoder = contents decoder

let feed decoder byte =
  let marker_length = String.length end_marker in
  if byte = end_marker.[decoder.matched] then begin
    decoder.matched <- decoder.matched + 1;
    if decoder.matched = marker_length then Some (contents decoder) else None
  end
  else begin
    keep decoder (String.sub end_marker 0 decoder.matched);
    decoder.matched <- 0;
    if byte = end_marker.[0] then decoder.matched <- 1
    else keep decoder (String.make 1 byte);
    None
  end

let read ~next_byte =
  let decoder = create () in
  let finished = ref false in
  let ended = ref false in
  let result = ref None in
  while not (!finished || !ended) do
    match next_byte () with
    | None -> ended := true
    | Some byte ->
        (match feed decoder byte with
         | Some paste -> result := Some paste; finished := true
         | None -> ())
  done;
  match !result with
  | Some paste -> paste
  | None -> finish_unterminated decoder

(* Dragging a file onto a terminal, or copying it in Finder, pastes the path
   the way a shell would need it: every space backslash-escaped. The draft is
   not a shell, so what lands in it is a path nobody can open —
   [/Users/x/스크린샷\ 2026-08-25.png].

   Unescaping every paste would be wrong: a pasted snippet containing "\\n" or
   a Windows path would come out altered, and the operator would have no way
   to paste those bytes. So this recognises one shape and refuses everything
   else — a single line that looks like an absolute path and whose only
   backslashes escape a character a shell would have escaped. Whether the
   result names a file is the caller's question; this cannot reach a
   filesystem and should not pretend to. *)
let shell_escapable_character = function
  | ' ' | '\t' | '\\' | '\'' | '"' | '(' | ')' | '[' | ']' | '{' | '}' | '&'
  | ';' | '<' | '>' | '|' | '*' | '?' | '$' | '`' | '!' | '#' | '~' ->
      true
  | _ -> false

let unescaped_path text =
  let trimmed = String.trim text in
  let length = String.length trimmed in
  let looks_absolute = length > 1 && trimmed.[0] = '/' in
  let single_line = not (String.contains trimmed '\n') in
  if not (looks_absolute && single_line) then None
  else begin
    let output = Buffer.create length in
    let rec walk offset =
      if offset >= length then Some (Buffer.contents output)
      else
        match trimmed.[offset] with
        | '\\' when offset + 1 < length ->
            let escaped = trimmed.[offset + 1] in
            if shell_escapable_character escaped then begin
              Buffer.add_char output escaped;
              walk (offset + 2)
            end
            else
              (* A backslash before an ordinary character is not shell
                 escaping. Whatever this text is, it is not the shape this
                 recognises. *)
              None
        | '\\' -> None (* trailing backslash *)
        | byte ->
            Buffer.add_char output byte;
            walk (offset + 1)
    in
    match walk 0 with
    | Some path when String.length path > 1 -> Some path
    | Some _ | None -> None
  end
