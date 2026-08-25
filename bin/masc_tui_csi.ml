type modifiers = {
  shift : bool;
  alt : bool;
  ctrl : bool;
}

let no_modifiers = { shift = false; alt = false; ctrl = false }

(* The mask is one more than the bits, so 1 means "no modifier held". A value
   that is not a number, or is below 1, is read as none: the press happened
   and the key is known, and refusing it over an unreadable mask would lose a
   keystroke to a detail nobody bound. *)
let decode_modifiers raw =
  match int_of_string_opt (String.trim raw) with
  | None -> no_modifiers
  | Some value when value < 1 -> no_modifiers
  | Some value ->
      let bits = value - 1 in
      { shift = bits land 1 <> 0; alt = bits land 2 <> 0; ctrl = bits land 4 <> 0 }

(* One order, always. Two spellings of the same chord would be two bindings
   that drift apart, and the one nobody typed would look dead. *)
let with_modifiers { shift; alt; ctrl } name =
  let prefix = if ctrl then "ctrl-" else "" in
  let prefix = if alt then prefix ^ "alt-" else prefix in
  let prefix = if shift then prefix ^ "shift-" else prefix in
  prefix ^ name

let split_parameters parameters =
  match String.split_on_char ';' parameters with
  | [] -> ("", "")
  | [ only ] -> (only, "")
  | first :: second :: _ -> (first, second)

(* The keys that have a legacy spelling. A terminal speaking the Kitty
   protocol still sends these finals; what it adds is the second parameter. *)
let final_name = function
  | 'A' -> Some "up"
  | 'B' -> Some "down"
  | 'C' -> Some "right"
  | 'D' -> Some "left"
  | 'H' -> Some "home"
  | 'F' -> Some "end"
  | _ -> None

(* [ESC \[ <n> ~] keys. The bare numbers are the ones this surface reads; the
   function keys are left out because nothing binds them and a name nobody
   uses is a name that goes stale. *)
let tilde_name = function
  | "1" -> Some "home"
  | "2" -> Some "insert"
  | "3" -> Some "delete"
  | "4" -> Some "end"
  | "5" -> Some "pageup"
  | "6" -> Some "pagedown"
  | _ -> None

(* Unicode code points the Kitty protocol reports as themselves. Only the ones
   with a name here are translated; a letter arrives as its own character
   rather than as its decimal number. *)
let codepoint_name code =
  if code >= 0x20 && code <= 0x7E then
    Some (String.make 1 (Char.lowercase_ascii (Char.chr code)))
  else
    match code with
    | 9 -> Some "tab"
    | 13 -> Some "enter"
    | 27 -> Some "esc"
    | 127 -> Some "backspace"
    | _ -> None

(* With disambiguation enabled, iTerm reports Ctrl+letter as CSI-u instead of
   the C0 byte sent in legacy mode. The bindings predate that protocol and
   intentionally read those bytes, so make both encodings identical here. *)
let legacy_control_byte { shift; alt; ctrl } name =
  if ctrl && not shift && not alt && String.length name = 1 then
    let letter = name.[0] in
    if letter >= 'a' && letter <= 'z' then
      Some (String.make 1 (Char.chr (Char.code letter - Char.code 'a' + 1)))
    else None
  else None

let name ~parameters ~final =
  let first, second = split_parameters parameters in
  let modifiers = decode_modifiers second in
  match final with
  (* [u] is the Kitty protocol's own final: the first parameter is the key's
     code point rather than a key number. *)
  | 'u' -> (
      match int_of_string_opt (String.trim first) with
      | None -> None
      | Some code -> (
          match codepoint_name code with
          | None -> None
          | Some key -> (
              match legacy_control_byte modifiers key with
              | Some byte -> Some byte
              | None -> Some (with_modifiers modifiers key))))
  | '~' -> Option.map (with_modifiers modifiers) (tilde_name (String.trim first))
  | 'Z' ->
      (* Backtab has carried its own final since long before modifiers were
         reportable, and it already means Shift+Tab. Naming it through the
         modifier path would spell it "shift-shift-tab". *)
      Some "shift-tab"
  | _ ->
      (* An arrow's first parameter is 1 when a modifier follows and empty
         when none does; neither carries a key number, so only the final
         names the key. *)
      Option.map (with_modifiers modifiers) (final_name final)

(* Flag 1 is "disambiguate escape codes", which is what makes a modifier
   reportable at all. The wider flags add release events and text reporting;
   this surface reads neither, and asking for them would put bytes on the
   stream that nothing consumes. *)
let enable_kitty_keyboard = "\027[>1u"
let disable_kitty_keyboard = "\027[<u"
