type modifiers = {
  ctrl : bool;
  alt : bool;
  shift : bool;
}

let no_mods = { ctrl = false; alt = false; shift = false }

let equal_modifiers a b =
  Bool.equal a.ctrl b.ctrl
  && Bool.equal a.alt b.alt
  && Bool.equal a.shift b.shift

type key =
  | Char of string
  | Enter
  | Tab
  | Backspace
  | Escape
  | Delete
  | Insert
  | Up
  | Down
  | Left
  | Right
  | Home
  | End
  | Page_up
  | Page_down
  | Function of int

let key_tag = function
  | Char _ -> 0
  | Enter -> 1
  | Tab -> 2
  | Backspace -> 3
  | Escape -> 4
  | Delete -> 5
  | Insert -> 6
  | Up -> 7
  | Down -> 8
  | Left -> 9
  | Right -> 10
  | Home -> 11
  | End -> 12
  | Page_up -> 13
  | Page_down -> 14
  | Function _ -> 15

let equal_key a b =
  if not (Int.equal (key_tag a) (key_tag b)) then false
  else
    match a with
    | Char x -> (
        match b with
        | Char y -> String.equal x y
        | Enter | Tab | Backspace | Escape | Delete | Insert | Up | Down | Left
        | Right | Home | End | Page_up | Page_down | Function _ ->
            false)
    | Function x -> (
        match b with
        | Function y -> Int.equal x y
        | Char _ | Enter | Tab | Backspace | Escape | Delete | Insert | Up
        | Down | Left | Right | Home | End | Page_up | Page_down ->
            false)
    | Enter | Tab | Backspace | Escape | Delete | Insert | Up | Down | Left
    | Right | Home | End | Page_up | Page_down ->
        true

type key_event = {
  key : key;
  mods : modifiers;
}

let equal_key_event a b = equal_key a.key b.key && equal_modifiers a.mods b.mods

type wheel_direction =
  | Wheel_up
  | Wheel_down

let equal_wheel_dir a b =
  match a, b with
  | Wheel_up, Wheel_up | Wheel_down, Wheel_down -> true
  | Wheel_up, Wheel_down | Wheel_down, Wheel_up -> false

type mouse_event =
  | Wheel of { dir : wheel_direction; col : int; row : int }
  | Left_press of { col : int; row : int }
  | Left_drag of { col : int; row : int }
  | Left_release of { col : int; row : int }

let equal_mouse_event a b =
  match a, b with
  | Wheel x, Wheel y ->
      equal_wheel_dir x.dir y.dir
      && Int.equal x.col y.col
      && Int.equal x.row y.row
  | Left_press x, Left_press y ->
      Int.equal x.col y.col && Int.equal x.row y.row
  | Left_drag x, Left_drag y ->
      Int.equal x.col y.col && Int.equal x.row y.row
  | Left_release x, Left_release y ->
      Int.equal x.col y.col && Int.equal x.row y.row
  | Wheel _, (Left_press _ | Left_drag _ | Left_release _)
  | Left_press _, (Wheel _ | Left_drag _ | Left_release _)
  | Left_drag _, (Wheel _ | Left_press _ | Left_release _)
  | Left_release _, (Wheel _ | Left_press _ | Left_drag _) ->
      false

type paste_event = {
  text : string;
  dropped_bytes : int;
}

let equal_paste_event a b =
  String.equal a.text b.text && Int.equal a.dropped_bytes b.dropped_bytes

type terminal_reply =
  | Palette_reply of { slot : Palette.slot; color : Palette.rgb option }
  | Cell_pixels_reply of { width : int; height : int }
  | Graphics_reply of string

type event =
  | Key of key_event
  | Paste of paste_event
  | Mouse of mouse_event
  | Reply of terminal_reply
  | Unknown_escape
  | Invalid_utf8

type pending =
  | Prefix
  | Sequence
  | Character
  | Pasting
  | Draining

let enable_kitty_keyboard = "\x1b[>1u"
let disable_kitty_keyboard = "\x1b[<u"

(* ---- Korean 2-bulsik IME helpers ---- *)
module Ime = struct
  let two_set =
    [
      ("ㄱ", "r"); ("ㄲ", "R"); ("ㄳ", "rt"); ("ㄴ", "s"); ("ㄵ", "sw"); ("ㄶ", "sg");
      ("ㄷ", "e"); ("ㄸ", "E"); ("ㄹ", "f"); ("ㄺ", "fr"); ("ㄻ", "fa"); ("ㄼ", "fq");
      ("ㄽ", "ft"); ("ㄾ", "fx"); ("ㄿ", "fv"); ("ㅀ", "fg"); ("ㅁ", "a"); ("ㅂ", "q");
      ("ㅃ", "Q"); ("ㅄ", "qt"); ("ㅅ", "t"); ("ㅆ", "T"); ("ㅇ", "d"); ("ㅈ", "w");
      ("ㅉ", "W"); ("ㅊ", "c"); ("ㅋ", "z"); ("ㅌ", "x"); ("ㅍ", "v"); ("ㅎ", "g");
      ("ㅏ", "k"); ("ㅐ", "o"); ("ㅑ", "i"); ("ㅒ", "O"); ("ㅓ", "j"); ("ㅔ", "p");
      ("ㅕ", "u"); ("ㅖ", "P"); ("ㅗ", "h"); ("ㅘ", "hk"); ("ㅙ", "ho"); ("ㅚ", "hl");
      ("ㅛ", "y"); ("ㅜ", "n"); ("ㅝ", "nj"); ("ㅞ", "np"); ("ㅟ", "nl"); ("ㅠ", "b");
      ("ㅡ", "m"); ("ㅢ", "ml"); ("ㅣ", "l");
    ]

  let cho_letters =
    [
      "ㄱ"; "ㄲ"; "ㄴ"; "ㄷ"; "ㄸ"; "ㄹ"; "ㅁ"; "ㅂ"; "ㅃ"; "ㅅ";
      "ㅆ"; "ㅇ"; "ㅈ"; "ㅉ"; "ㅊ"; "ㅋ"; "ㅌ"; "ㅍ"; "ㅎ";
    ]

  let jung_letters =
    [
      "ㅏ"; "ㅐ"; "ㅑ"; "ㅒ"; "ㅓ"; "ㅔ"; "ㅕ"; "ㅖ"; "ㅗ"; "ㅘ"; "ㅙ";
      "ㅚ"; "ㅛ"; "ㅜ"; "ㅝ"; "ㅞ"; "ㅟ"; "ㅠ"; "ㅡ"; "ㅢ"; "ㅣ";
    ]

  let jong_letters =
    [
      "ㄱ"; "ㄲ"; "ㄳ"; "ㄴ"; "ㄵ"; "ㄶ"; "ㄷ"; "ㄹ"; "ㄺ"; "ㄻ"; "ㄼ"; "ㄽ";
      "ㄾ"; "ㄿ"; "ㅀ"; "ㅁ"; "ㅂ"; "ㅄ"; "ㅅ"; "ㅆ"; "ㅇ"; "ㅈ"; "ㅊ"; "ㅋ";
      "ㅌ"; "ㅍ"; "ㅎ";
    ]

  let keys_of_spelling spelling =
    String.to_seq spelling |> Seq.map (String.make 1) |> List.of_seq

  let keys_of_letter letter = keys_of_spelling (List.assoc letter two_set)
  let cho_keys = Array.of_list (List.map keys_of_letter cho_letters)
  let jung_keys = Array.of_list (List.map keys_of_letter jung_letters)
  let jong_keys = Array.of_list (List.map keys_of_letter jong_letters)

  let compat_keys =
    Array.of_list (List.map (fun (_, sp) -> keys_of_spelling sp) two_set)

  let syllable_first = 0xAC00
  let syllable_last = 0xD7A3
  let compatibility_first = 0x3131
  let compatibility_last = 0x3163
  let choseong_first = 0x1100
  let choseong_last = 0x1112
  let jungseong_first = 0x1161
  let jungseong_last = 0x1175
  let jongseong_first = 0x11A8
  let jongseong_last = 0x11C2

  let syllable_keys codepoint =
    let offset = codepoint - syllable_first in
    let cho = offset / (21 * 28) in
    let jung = (offset / 28) mod 21 in
    let jong = offset mod 28 in
    cho_keys.(cho) @ jung_keys.(jung)
    @ if jong = 0 then [] else jong_keys.(jong - 1)

  let scalar_code name =
    if String.length name = 0 || not (String.is_valid_utf_8 name) then None
    else
      let d = String.get_utf_8_uchar name 0 in
      if Uchar.utf_decode_is_valid d && Uchar.utf_decode_length d = String.length name
      then Some (Uchar.to_int (Uchar.utf_decode_uchar d))
      else None

  let latin_keys name =
    match scalar_code name with
    | None -> None
    | Some cp when cp >= syllable_first && cp <= syllable_last ->
        Some (syllable_keys cp)
    | Some cp when cp >= compatibility_first && cp <= compatibility_last ->
        Some compat_keys.(cp - compatibility_first)
    | Some cp when cp >= choseong_first && cp <= choseong_last ->
        Some cho_keys.(cp - choseong_first)
    | Some cp when cp >= jungseong_first && cp <= jungseong_last ->
        Some jung_keys.(cp - jungseong_first)
    | Some cp when cp >= jongseong_first && cp <= jongseong_last ->
        Some jong_keys.(cp - jongseong_first)
    | Some _ -> None

  let single_latin_key name =
    match latin_keys name with
    | Some [ k ] -> Some k
    | Some ([] | _ :: _ :: _) | None -> None

  let latin_text name =
    match latin_keys name with
    | Some keys -> String.concat "" keys
    | None -> name
end

(* ---- Bracketed paste decoder ---- *)
let paste_end_marker = "\x1b[201~"
let paste_max_bytes = 1_048_576

type paste_decoder = {
  buf : Buffer.t;
  mutable dropped : int;
  mutable matched : int;
}

let create_paste_decoder () =
  { buf = Buffer.create 4096; dropped = 0; matched = 0 }

let normalize_paste_newlines text =
  let len = String.length text in
  let out = Buffer.create len in
  let rec loop i =
    if i < len then
      match text.[i] with
      | '\r' ->
          Buffer.add_char out '\n';
          if i + 1 < len && text.[i + 1] = '\n' then loop (i + 2)
          else loop (i + 1)
      | ch ->
          Buffer.add_char out ch;
          loop (i + 1)
  in
  loop 0;
  Buffer.contents out

let paste_keep pd s =
  let room = Int.max 0 (paste_max_bytes - Buffer.length pd.buf) in
  let len = String.length s in
  if len <= room then Buffer.add_string pd.buf s
  else begin
    if room > 0 then Buffer.add_string pd.buf (String.sub s 0 room);
    pd.dropped <- pd.dropped + (len - room)
  end

let paste_snapshot pd =
  { text = normalize_paste_newlines (Buffer.contents pd.buf); dropped_bytes = pd.dropped }

let paste_feed pd byte =
  let mlen = String.length paste_end_marker in
  if byte = paste_end_marker.[pd.matched] then begin
    pd.matched <- pd.matched + 1;
    if pd.matched = mlen then Some (paste_snapshot pd) else None
  end
  else begin
    if pd.matched > 0 then
      paste_keep pd (String.sub paste_end_marker 0 pd.matched);
    pd.matched <- 0;
    if byte = paste_end_marker.[0] then pd.matched <- 1
    else paste_keep pd (String.make 1 byte);
    None
  end

let shell_escapable_character = function
  | ' ' | '\t' | '\\' | '\'' | '"' | '(' | ')' | '[' | ']' | '{' | '}' | '&'
  | ';' | '<' | '>' | '|' | '*' | '?' | '$' | '`' | '!' | '#' | '~' ->
      true
  | _ -> false

let unescaped_path text =
  let trimmed = String.trim text in
  let len = String.length trimmed in
  if not (len > 1 && trimmed.[0] = '/' && not (String.contains trimmed '\n')) then
    None
  else
    let out = Buffer.create len in
    let rec walk i =
      if i >= len then Some (Buffer.contents out)
      else
        match trimmed.[i] with
        | '\\' when i + 1 < len ->
            let escaped = trimmed.[i + 1] in
            if shell_escapable_character escaped then begin
              Buffer.add_char out escaped;
              walk (i + 2)
            end
            else None
        | '\\' -> None
        | ch ->
            Buffer.add_char out ch;
            walk (i + 1)
    in
    match walk 0 with
    | Some p when String.length p > 1 -> Some p
    | Some _ | None -> None

(* ---- SGR and X10 Mouse protocol ---- *)
let parse_sgr_mouse parameters final =
  match String.split_on_char ';' parameters with
  | [ btn; col_s; row_s ] -> (
      match int_of_string_opt col_s, int_of_string_opt row_s with
      | Some col, Some row when col > 0 && row > 0 ->
          if final = 'M' then
            if String.equal btn "<64" then Some (Wheel { dir = Wheel_up; col; row })
            else if String.equal btn "<65" then Some (Wheel { dir = Wheel_down; col; row })
            else if String.equal btn "<0" then Some (Left_press { col; row })
            else if String.equal btn "<32" then Some (Left_drag { col; row })
            else None
          else if final = 'm' && String.equal btn "<0" then
            Some (Left_release { col; row })
          else None
      | _, _ -> None)
  | _ -> None

type x10_mouse =
  | X10_wheel of wheel_direction * int * int
  | X10_left_press of int * int
  | X10_left_drag of int * int
  | X10_other_press
  | X10_release of int * int

let parse_x10_mouse ~button ~column ~row =
  let col = Char.code column - 32 in
  let r = Char.code row - 32 in
  let code = Char.code button - 32 in
  if col <= 0 || r <= 0 then None
  else if code = 32 then Some (X10_left_drag (col, r))
  else if code land 32 <> 0 then None
  else if code land 64 <> 0 then
    if code = 64 then Some (X10_wheel (Wheel_up, col, r))
    else if code = 65 then Some (X10_wheel (Wheel_down, col, r))
    else None
  else if code land 3 = 3 then Some (X10_release (col, r))
  else if code = 0 then Some (X10_left_press (col, r))
  else Some X10_other_press

(* ---- CSI / SS3 / Kitty CSI u decoding ---- *)
type mod_decode =
  | Mod_ok of modifiers
  | Mod_release
  | Mod_invalid

let decode_modifiers_field raw =
  let decode_mask mask_str =
    let s = String.trim mask_str in
    if String.equal s "" then Mod_ok no_mods
    else
      match int_of_string_opt s with
      | None -> Mod_invalid
      | Some v when v < 1 -> Mod_invalid
      | Some v ->
          let bits = v - 1 in
          let supported = 1 lor 2 lor 4 lor 64 lor 128 in
          if bits land lnot supported <> 0 then Mod_invalid
          else
            Mod_ok
              {
                shift = bits land 1 <> 0;
                alt = bits land 2 <> 0;
                ctrl = bits land 4 <> 0;
              }
  in
  match String.split_on_char ':' raw with
  | [ mask ] -> decode_mask mask
  | [ mask; event_s ] -> (
      match int_of_string_opt (String.trim event_s) with
      | Some (1 | 2) -> decode_mask mask
      | Some 3 -> Mod_release
      | Some _ | None -> Mod_invalid)
  | _ -> Mod_invalid

let utf8_of_codepoint cp =
  if not (Uchar.is_valid cp) then None
  else
    let buf = Buffer.create 4 in
    Buffer.add_utf_8_uchar buf (Uchar.of_int cp);
    Some (Buffer.contents buf)

let key_of_codepoint ~mods cp =
  match cp with
  | 9 -> Some Tab
  | 13 | 57414 -> Some Enter
  | 27 -> Some Escape
  | 127 | 8 -> Some Backspace
  | c when c >= 57364 && c <= 57375 -> Some (Function (c - 57364 + 1))
  (* Reject unrecognized Private Use Area functional/modifier keys (e.g.
     CapsLock 57358, F13..F35 57376..57398, Shift/Ctrl/Alt/Super 57441..57454)
     so they never leak invisible PUA characters into text composers. *)
  | c when (c >= 0xE000 && c <= 0xF8FF) || c >= 0xF0000 -> None
  | c when c >= 0x20 && c <= 0x7E ->
      let ch = Char.chr c in
      let norm =
        if mods.ctrl || mods.alt then Char.lowercase_ascii ch else ch
      in
      Some (Char (String.make 1 norm))
  | c when c >= 0xA0 -> Option.map (fun s -> Char s) (utf8_of_codepoint c)
  | _ -> None

let tilde_key = function
  | "1" | "7" -> Some Home
  | "2" -> Some Insert
  | "3" -> Some Delete
  | "4" | "8" -> Some End
  | "5" -> Some Page_up
  | "6" -> Some Page_down
  | "11" -> Some (Function 1)
  | "12" -> Some (Function 2)
  | "13" -> Some (Function 3)
  | "14" -> Some (Function 4)
  | "15" -> Some (Function 5)
  | "17" -> Some (Function 6)
  | "18" -> Some (Function 7)
  | "19" -> Some (Function 8)
  | "20" -> Some (Function 9)
  | "21" -> Some (Function 10)
  | "23" -> Some (Function 11)
  | "24" -> Some (Function 12)
  | _ -> None

let csi_final_key = function
  | 'A' -> Some Up
  | 'B' -> Some Down
  | 'C' -> Some Right
  | 'D' -> Some Left
  | 'H' -> Some Home
  | 'F' -> Some End
  | 'P' -> Some (Function 1)
  | 'Q' -> Some (Function 2)
  | 'R' -> Some (Function 3)
  | 'S' -> Some (Function 4)
  | _ -> None

type csi_u_codepoints = {
  codepoint : int;
  shifted : int option;
}

let parse_optional_codepoint s =
  let trimmed = String.trim s in
  if String.equal trimmed "" then Some None
  else
    match int_of_string_opt trimmed with
    | Some cp when Uchar.is_valid cp -> Some (Some cp)
    | Some _ | None -> None

let parse_csi_u_codepoints raw =
  match String.split_on_char ':' raw with
  | [ cp_s ] -> (
      match int_of_string_opt (String.trim cp_s) with
      | Some codepoint when Uchar.is_valid codepoint ->
          Some { codepoint; shifted = None }
      | Some _ | None -> None)
  | [ cp_s; shifted_s ] -> (
      match
        int_of_string_opt (String.trim cp_s), parse_optional_codepoint shifted_s
      with
      | Some codepoint, Some shifted when Uchar.is_valid codepoint ->
          Some { codepoint; shifted }
      | _, _ -> None)
  | [ cp_s; shifted_s; base_s ] -> (
      match
        ( int_of_string_opt (String.trim cp_s),
          parse_optional_codepoint shifted_s,
          parse_optional_codepoint base_s )
      with
      | Some codepoint, Some shifted, Some _ when Uchar.is_valid codepoint ->
          Some { codepoint; shifted }
      | _, _, _ -> None)
  | [] | _ :: _ :: _ :: _ :: _ -> None

let decode_csi_key ~parameters ~final =
  let parts = String.split_on_char ';' parameters in
  match final, parts with
  | 'Z', _ -> [ Key { key = Tab; mods = { no_mods with shift = true } } ]
  | 'u', first :: rest -> (
      let second = match rest with s :: _ -> s | [] -> "" in
      match decode_modifiers_field second with
      | Mod_release -> []
      | Mod_invalid -> [ Unknown_escape ]
      | Mod_ok mods -> (
          match parse_csi_u_codepoints first with
          | None -> [ Unknown_escape ]
          | Some { codepoint; shifted } -> (
              match shifted with
              | Some shifted_cp
                when mods.shift && (not mods.ctrl) && not mods.alt -> (
                  let unshifted_mods = { mods with shift = false } in
                  match key_of_codepoint ~mods:unshifted_mods shifted_cp with
                  | Some (Char _ as key) ->
                      [ Key { key; mods = unshifted_mods } ]
                  | Some
                      ( Enter | Tab | Backspace | Escape | Delete | Insert
                      | Up | Down | Left | Right | Home | End | Page_up
                      | Page_down | Function _ )
                  | None -> (
                      match key_of_codepoint ~mods codepoint with
                      | Some key -> [ Key { key; mods } ]
                      | None -> [ Unknown_escape ]))
              | Some _ | None -> (
                  match key_of_codepoint ~mods codepoint with
                  | Some key -> [ Key { key; mods } ]
                  | None -> [ Unknown_escape ]))))
  | '~', [ "27"; mod_s; cp_s ] -> (
      (* xterm modifyOtherKeys format: CSI 27 ; mod ; codepoint ~ *)
      match decode_modifiers_field mod_s, int_of_string_opt (String.trim cp_s) with
      | Mod_release, _ -> []
      | Mod_ok mods, Some cp -> (
          match key_of_codepoint ~mods cp with
          | Some key -> [ Key { key; mods } ]
          | None -> [ Unknown_escape ])
      | (Mod_ok _ | Mod_invalid), _ -> [ Unknown_escape ])
  | '~', first :: rest -> (
      let second = match rest with s :: _ -> s | [] -> "" in
      match decode_modifiers_field second with
      | Mod_release -> []
      | Mod_invalid -> [ Unknown_escape ]
      | Mod_ok mods -> (
          match tilde_key (String.trim first) with
          | Some key -> [ Key { key; mods } ]
          | None -> [ Unknown_escape ]))
  | _, _ -> (
      let valid_first, second =
        match parts with
        | [] | [ "" ] -> (true, "")
        | [ "1" ] -> (true, "")
        | [ "1"; s ] -> (true, s)
        | _ -> (false, "")
      in
      if not valid_first then [ Unknown_escape ]
      else
        match decode_modifiers_field second with
        | Mod_release -> []
        | Mod_invalid -> [ Unknown_escape ]
        | Mod_ok mods -> (
            match csi_final_key final with
            | Some key -> [ Key { key; mods } ]
            | None -> [ Unknown_escape ]))

let rxvt_ss3_arrow = function
  | 'a' -> Some Up
  | 'b' -> Some Down
  | 'c' -> Some Right
  | 'd' -> Some Left
  | _ -> None

let ss3_final_key = function
  | 'M' -> Some Enter
  | ch -> csi_final_key ch

let decode_ss3_key ~parameters ~final =
  if String.equal parameters "" then
    match rxvt_ss3_arrow final with
    | Some key -> [ Key { key; mods = { no_mods with ctrl = true } } ]
    | None -> (
        match ss3_final_key final with
        | Some key -> [ Key { key; mods = no_mods } ]
        | None -> [ Unknown_escape ])
  else
    let mod_field =
      match String.split_on_char ';' parameters with
      | [ mod_s ] -> Some mod_s
      | [ "1"; mod_s ] -> Some mod_s
      | _ -> None
    in
    match mod_field with
    | None -> [ Unknown_escape ]
    | Some mod_s -> (
        match decode_modifiers_field mod_s with
        | Mod_release -> []
        | Mod_invalid -> [ Unknown_escape ]
        | Mod_ok mods -> (
            match ss3_final_key final with
            | Some key -> [ Key { key; mods } ]
            | None -> [ Unknown_escape ]))

(* ---- Decoder state machine ---- *)
type body = {
  bytes : Buffer.t;
  mutable after_escape : bool;
  mutable overflowed : bool;
}

type held_button =
  | Held_left
  | Held_other

type state =
  | Ground
  | Escape_prefix
  | Csi of Buffer.t
  | Ss3 of Buffer.t
  | X10_awaiting_button
  | X10_awaiting_column of char
  | X10_awaiting_row of char * char
  | Osc of body
  | Apc_prefix
  | Apc of body
  | Utf8 of { buf : Buffer.t; expected_length : int }
  | In_paste of paste_decoder
  | Draining_paste of paste_decoder

type t = {
  mutable state : state;
  mutable x10_held : held_button list;
  mutable x10_ambiguous : bool;
}

let create () = { state = Ground; x10_held = []; x10_ambiguous = false }

let csi_parameters_max_bytes = 64
let ss3_parameters_max_bytes = 16
let body_max_bytes = 4096
let x10_buttons = 3
let escape_ch = '\x1b'
let bell_ch = '\x07'

let is_csi_final byte = byte >= '\x40' && byte <= '\x7e'

let new_body () =
  { bytes = Buffer.create 64; after_escape = false; overflowed = false }

let parse_cell_size parameters =
  match String.split_on_char ';' parameters with
  | [ "6"; height_s; width_s ] -> (
      match int_of_string_opt width_s, int_of_string_opt height_s with
      | Some width, Some height when width > 0 && height > 0 ->
          Some (width, height)
      | _, _ -> None)
  | _ -> None

let complete_csi t parameters final =
  t.state <- Ground;
  if String.equal parameters "200" && final = '~' then begin
    t.state <- In_paste (create_paste_decoder ());
    []
  end
  else if String.equal parameters "" && final = 'M' then begin
    t.state <- X10_awaiting_button;
    []
  end
  else if String.length parameters > 0 && parameters.[0] = '<' then
    match parse_sgr_mouse parameters final with
    | Some m -> [ Mouse m ]
    | None -> [ Unknown_escape ]
  else if final = 't' then
    match parse_cell_size parameters with
    | Some (width, height) -> [ Reply (Cell_pixels_reply { width; height }) ]
    | None -> decode_csi_key ~parameters ~final
  else decode_csi_key ~parameters ~final

let hold t button =
  (match t.x10_held with
   | [] -> ()
   | _ :: _ -> t.x10_ambiguous <- true);
  t.x10_held <-
    List.filteri (fun idx _ -> idx < x10_buttons) (button :: t.x10_held)

let x10_event t ~button ~column ~row =
  match parse_x10_mouse ~button ~column ~row with
  | Some (X10_wheel (dir, col, r)) -> [ Mouse (Wheel { dir; col; row = r }) ]
  | Some (X10_left_press (col, r)) ->
      hold t Held_left;
      [ Mouse (Left_press { col; row = r }) ]
  | Some (X10_left_drag (col, r)) -> [ Mouse (Left_drag { col; row = r }) ]
  | Some X10_other_press ->
      hold t Held_other;
      [ Unknown_escape ]
  | Some (X10_release (col, r)) -> (
      match t.x10_held with
      | [] -> [ Unknown_escape ]
      | [ Held_left ] when not t.x10_ambiguous ->
          t.x10_held <- [];
          [ Mouse (Left_release { col; row = r }) ]
      | (Held_left | Held_other) :: rest ->
          t.x10_held <- rest;
          (match rest with [] -> t.x10_ambiguous <- false | _ :: _ -> ());
          [ Unknown_escape ])
  | None -> [ Unknown_escape ]

let body_byte body ~bell_terminates byte =
  if body.after_escape then begin
    body.after_escape <- false;
    if byte = '\\' then Some body
    else begin
      if not body.overflowed then begin
        Buffer.add_char body.bytes escape_ch;
        Buffer.add_char body.bytes byte
      end;
      if byte = escape_ch then body.after_escape <- true;
      None
    end
  end
  else if byte = escape_ch then begin
    body.after_escape <- true;
    None
  end
  else if bell_terminates && byte = bell_ch then Some body
  else begin
    if not body.overflowed then Buffer.add_char body.bytes byte;
    if Buffer.length body.bytes > body_max_bytes then begin
      body.overflowed <- true;
      Buffer.clear body.bytes
    end;
    None
  end

let osc_event body =
  if body.overflowed then []
  else
    match Palette.parse_response (Buffer.contents body.bytes) with
    | Palette.Palette_response { slot; color } ->
        [ Reply (Palette_reply { slot; color }) ]
    | Palette.Not_palette_response -> []

let apc_event body =
  if body.overflowed then []
  else [ Reply (Graphics_reply (Buffer.contents body.bytes)) ]

let decode_single_ascii_byte byte =
  let code = Char.code byte in
  match code with
  | 0x0D -> Key { key = Enter; mods = no_mods }
  | 0x09 -> Key { key = Tab; mods = no_mods }
  | 0x7F | 0x08 -> Key { key = Backspace; mods = no_mods }
  | 0x00 -> Key { key = Char " "; mods = { no_mods with ctrl = true } }
  | c when c >= 0x01 && c <= 0x1A ->
      let letter = Char.chr (Char.code 'a' + c - 1) in
      Key { key = Char (String.make 1 letter); mods = { no_mods with ctrl = true } }
  | 0x1C -> Key { key = Char "\\"; mods = { no_mods with ctrl = true } }
  | 0x1D -> Key { key = Char "]"; mods = { no_mods with ctrl = true } }
  | 0x1E -> Key { key = Char "^"; mods = { no_mods with ctrl = true } }
  | 0x1F -> Key { key = Char "_"; mods = { no_mods with ctrl = true } }
  | c when c >= 0x20 && c <= 0x7E ->
      Key { key = Char (String.make 1 byte); mods = no_mods }
  | _ -> Invalid_utf8

let decode_alt_byte t byte =
  let code = Char.code byte in
  let alt_mods = { no_mods with alt = true } in
  match byte with
  | '\r' | '\n' -> [ Key { key = Enter; mods = alt_mods } ]
  | '\x7f' | '\x08' -> [ Key { key = Backspace; mods = alt_mods } ]
  | '\t' -> [ Key { key = Tab; mods = alt_mods } ]
  | '\x1b' ->
      t.state <- Escape_prefix;
      [ Key { key = Escape; mods = no_mods } ]
  | c when code >= 0x01 && code <= 0x1A ->
      let letter = Char.chr (Char.code 'a' + Char.code c - 1) in
      [ Key { key = Char (String.make 1 letter); mods = { alt_mods with ctrl = true } } ]
  | c when code >= 0x20 && code <= 0x7E ->
      let is_upper = c >= 'A' && c <= 'Z' in
      let norm = Char.lowercase_ascii c in
      [ Key { key = Char (String.make 1 norm); mods = { alt_mods with shift = is_upper } } ]
  | _ ->
      Key { key = Escape; mods = no_mods } :: []

let is_utf8_continuation byte =
  let code = Char.code byte in
  code >= 0x80 && code <= 0xBF

let rec feed t byte =
  match t.state with
  | Ground -> ground t byte
  | Escape_prefix -> (
      t.state <- Ground;
      match byte with
      | '[' ->
          t.state <- Csi (Buffer.create 8);
          []
      | 'O' ->
          t.state <- Ss3 (Buffer.create 4);
          []
      | '_' ->
          t.state <- Apc_prefix;
          []
      | ']' ->
          t.state <- Osc (new_body ());
          []
      | _ ->
          if Char.code byte < 0x80 then decode_alt_byte t byte
          else Key { key = Escape; mods = no_mods } :: feed t byte)
  | Csi params ->
      if is_csi_final byte then complete_csi t (Buffer.contents params) byte
      else if byte = escape_ch then begin
        t.state <- Escape_prefix;
        [ Unknown_escape ]
      end
      else if byte >= '\x20' && byte <= '\x3f' then begin
        Buffer.add_char params byte;
        if Buffer.length params > csi_parameters_max_bytes then begin
          t.state <- Ground;
          [ Unknown_escape ]
        end
        else []
      end
      else begin
        t.state <- Ground;
        [ Unknown_escape ]
      end
  | Ss3 params ->
      if byte = escape_ch then begin
        t.state <- Escape_prefix;
        [ Unknown_escape ]
      end
      else if (byte >= '0' && byte <= '9') || byte = ';' || byte = ':' then begin
        Buffer.add_char params byte;
        if Buffer.length params > ss3_parameters_max_bytes then begin
          t.state <- Ground;
          [ Unknown_escape ]
        end
        else []
      end
      else begin
        t.state <- Ground;
        decode_ss3_key ~parameters:(Buffer.contents params) ~final:byte
      end
  | X10_awaiting_button ->
      t.state <- X10_awaiting_column byte;
      []
  | X10_awaiting_column button ->
      t.state <- X10_awaiting_row (button, byte);
      []
  | X10_awaiting_row (button, column) ->
      t.state <- Ground;
      x10_event t ~button ~column ~row:byte
  | Osc body -> (
      match body_byte body ~bell_terminates:true byte with
      | Some body ->
          t.state <- Ground;
          osc_event body
      | None -> [])
  | Apc_prefix ->
      t.state <- Ground;
      if byte = 'G' then begin
        t.state <- Apc (new_body ());
        []
      end
      else [ Unknown_escape ]
  | Apc body -> (
      match body_byte body ~bell_terminates:false byte with
      | Some body ->
          t.state <- Ground;
          apc_event body
      | None -> [])
  | Utf8 { buf; expected_length } ->
      if is_utf8_continuation byte then begin
        Buffer.add_char buf byte;
        if Buffer.length buf >= expected_length then begin
          t.state <- Ground;
          let scalar = Buffer.contents buf in
          if String.is_valid_utf_8 scalar then
            [ Key { key = Char scalar; mods = no_mods } ]
          else [ Invalid_utf8 ]
        end
        else []
      end
      else begin
        t.state <- Ground;
        Invalid_utf8 :: feed t byte
      end
  | In_paste pd -> (
      match paste_feed pd byte with
      | Some paste ->
          t.state <- Ground;
          [ Paste paste ]
      | None -> [])
  | Draining_paste pd -> (
      match paste_feed pd byte with
      | Some _ ->
          t.state <- Ground;
          []
      | None -> [])

and ground t byte =
  if byte = escape_ch then begin
    t.state <- Escape_prefix;
    []
  end
  else
    match Grapheme.utf8_scalar_byte_length byte with
    | Some 1 -> [ decode_single_ascii_byte byte ]
    | Some expected_length ->
        let buf = Buffer.create expected_length in
        Buffer.add_char buf byte;
        t.state <- Utf8 { buf; expected_length };
        []
    | None -> [ Invalid_utf8 ]

let feed_string t text =
  let acc = ref [] in
  String.iter (fun ch -> acc := List.rev_append (feed t ch) !acc) text;
  List.rev !acc

let idle t =
  match t.state with
  | Ground -> []
  | Escape_prefix | Apc_prefix ->
      t.state <- Ground;
      [ Key { key = Escape; mods = no_mods } ]
  | Ss3 params ->
      t.state <- Ground;
      if Buffer.length params = 0 then
        [ Key { key = Escape; mods = no_mods } ]
      else [ Unknown_escape ]
  | Csi _ | X10_awaiting_button | X10_awaiting_column _ | X10_awaiting_row _ ->
      t.state <- Ground;
      [ Unknown_escape ]
  | Osc body | Apc body ->
      t.state <- Ground;
      if Buffer.length body.bytes = 0 && not body.overflowed then
        [ Key { key = Escape; mods = no_mods } ]
      else []
  | Utf8 _ ->
      t.state <- Ground;
      [ Invalid_utf8 ]
  | In_paste pd ->
      t.state <- Ground;
      if Buffer.length pd.buf = 0 && pd.dropped = 0 then []
      else [ Paste (paste_snapshot pd) ]
  | Draining_paste _ ->
      t.state <- Ground;
      []

let pending t =
  match t.state with
  | Ground -> None
  | Escape_prefix
  | X10_awaiting_button
  | X10_awaiting_column _
  | X10_awaiting_row _
  | Apc_prefix ->
      Some Prefix
  | Osc body | Apc body ->
      if Buffer.length body.bytes = 0 && not body.overflowed then Some Prefix
      else Some Sequence
  | Ss3 params ->
      if Buffer.length params = 0 then Some Prefix else Some Sequence
  | Csi _ -> Some Sequence
  | Utf8 _ -> Some Character
  | In_paste _ -> Some Pasting
  | Draining_paste _ -> Some Draining

let has_pending t = Option.is_some (pending t)

let idle_timeout_s = function
  | Prefix -> 0.025
  | Sequence -> 0.100
  | Character -> 0.100
  | Pasting -> 5.0
  | Draining -> 0.200

let cancel_pending t =
  match t.state with
  | Escape_prefix
  | Csi _
  | Ss3 _
  | X10_awaiting_button
  | X10_awaiting_column _
  | X10_awaiting_row _
  | Osc _
  | Apc_prefix
  | Apc _
  | Utf8 _ ->
      t.state <- Ground
  | Ground | In_paste _ | Draining_paste _ -> ()

let recover_paste t =
  match t.state with
  | In_paste pd ->
      t.state <- Draining_paste pd;
      Some (paste_snapshot pd)
  | Ground
  | Escape_prefix
  | Csi _
  | Ss3 _
  | X10_awaiting_button
  | X10_awaiting_column _
  | X10_awaiting_row _
  | Osc _
  | Apc_prefix
  | Apc _
  | Utf8 _
  | Draining_paste _ ->
      None

let abandon_draining t =
  match t.state with
  | Draining_paste _ -> t.state <- Ground
  | Ground
  | Escape_prefix
  | Csi _
  | Ss3 _
  | X10_awaiting_button
  | X10_awaiting_column _
  | X10_awaiting_row _
  | Osc _
  | Apc_prefix
  | Apc _
  | Utf8 _
  | In_paste _ ->
      ()
