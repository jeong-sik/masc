type modifiers = {
  shift : bool;
  alt : bool;
  ctrl : bool;
}

let no_modifiers = { shift = false; alt = false; ctrl = false }

(* Kitty encodes one plus the modifier bits. Shift/Alt/Ctrl have bindings;
   Caps/Num Lock do not alter shortcut identity. Super/Hyper/Meta and unknown
   bits must remain unclaimed rather than becoming a plain or Ctrl action. *)
let decode_modifiers raw =
  let raw = String.trim raw in
  if String.equal raw "" then Some no_modifiers
  else match int_of_string_opt raw with
  | None -> None
  | Some value when value < 1 -> None
  | Some value ->
      let bits = value - 1 in
      let supported_bits = 1 lor 2 lor 4 lor 64 lor 128 in
      if bits land (lnot supported_bits) <> 0 then None
      else Some
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
  | 'Q' -> Some "f2"
  | 'S' -> Some "f4"
  | _ -> None

(* [ESC \[ <n> ~] keys, including the MSX checkpoint bindings. *)
let tilde_name = function
  | "1" -> Some "home"
  | "2" -> Some "insert"
  | "3" -> Some "delete"
  | "4" -> Some "end"
  | "5" -> Some "pageup"
  | "6" -> Some "pagedown"
  | "12" -> Some "f2"
  | "14" -> Some "f4"
  | "15" -> Some "f5"
  | "17" -> Some "f6"
  | "18" -> Some "f7"
  | "19" -> Some "f8"
  | "20" -> Some "f9"
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
    | 57365 -> Some "f2"
    | 57367 -> Some "f4"
    | 57368 -> Some "f5"
    | 57369 -> Some "f6"
    | 57370 -> Some "f7"
    | 57371 -> Some "f8"
    | 57372 -> Some "f9"
    | _ -> None

(* The surface handlers predate CSI-u and consume the legacy byte vocabulary.
   Normalize at this protocol boundary, including punctuation control keys;
   teaching every composer, form and global binding another spelling drifts. *)
let legacy_key { shift; alt; ctrl } name =
  match shift, alt, ctrl, name with
  | false, false, false, "tab" -> Some "\t"
  | false, false, false, "enter" -> Some "\r"
  | false, false, false, "backspace" -> Some "\127"
  | false, false, true, "[" -> Some "esc"
  | false, false, true, "\\" -> Some "\028"
  | false, false, true, "]" -> Some "\029"
  | false, false, true, "^" | true, false, true, "6" -> Some "\030"
  | false, false, true, "_" -> Some "\031"
  | false, false, true, "@" | false, false, true, " " -> Some "\000"
  | false, false, true, name when String.length name = 1 ->
      let letter = name.[0] in
      if letter >= 'a' && letter <= 'z' then
        Some (String.make 1 (Char.chr (Char.code letter - Char.code 'a' + 1)))
      else None
  | _ -> None

let name ~parameters ~final =
  let first, second = split_parameters parameters in
  (* Kitty's optional event subfield is 1=press, 2=repeat, 3=release.
     A release must not invoke the checkpoint binding a second time. *)
  let modifiers =
    match String.split_on_char ':' second with
    | [mask] -> decode_modifiers mask
    | [mask; event] -> (
        match int_of_string_opt (String.trim event) with
        | Some (1 | 2) -> decode_modifiers mask
        | _ -> None)
    | _ -> None
  in
  match modifiers with
  | None -> None
  | Some modifiers ->
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
              match legacy_key modifiers key with
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
