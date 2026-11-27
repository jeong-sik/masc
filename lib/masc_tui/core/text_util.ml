let clamp_index len idx =
  if len <= 0 then 0
  else if idx < 0 then 0
  else if idx >= len then len - 1
  else idx

let[@inline] lower_ascii_code c =
  let code = Char.code c in
  if code >= 65 && code <= 90 then code + 32 else code

let contains_ci ~needle haystack =
  let n_len = String.length needle in
  if n_len = 0 then true
  else
    let h_len = String.length haystack in
    if n_len > h_len then false
    else
      let limit = h_len - n_len in
      let first_n = lower_ascii_code (String.unsafe_get needle 0) in
      let rec match_at i j =
        if j >= n_len then true
        else if
          lower_ascii_code (String.unsafe_get haystack (i + j))
          = lower_ascii_code (String.unsafe_get needle j)
        then match_at i (j + 1)
        else false
      in
      let rec scan i =
        if i > limit then false
        else if
          lower_ascii_code (String.unsafe_get haystack i) = first_n
          && match_at i 1
        then true
        else scan (i + 1)
      in
      scan 0

let skip_ansi_escape s len i =
  (* Assumes [s.[i] = '\x1b']. Returns index of first byte after the escape sequence. *)
  if i + 1 >= len then len
  else
    match s.[i + 1] with
    | '[' ->
        (* CSI: ESC [ parameter/intermediate bytes until final byte 0x40..0x7E. *)
        let rec scan j =
          if j >= len then len
          else
            let code = Char.code s.[j] in
            if code >= 0x40 && code <= 0x7E then j + 1 else scan (j + 1)
        in
        scan (i + 2)
    | ']' | 'P' | '_' | '^' ->
        (* OSC / DCS / APC / PM: terminated by BEL (0x07) or ST (ESC \). *)
        let rec scan j =
          if j >= len then len
          else
            let c = s.[j] in
            if Char.equal c '\x07' then j + 1
            else if Char.equal c '\x1b' && j + 1 < len && Char.equal s.[j + 1] '\\'
            then j + 2
            else scan (j + 1)
        in
        scan (i + 2)
    | _ -> i + 2

let sanitize_single_line s =
  let len = String.length s in
  if len = 0 then ""
  else
    let rec is_clean i prev_space =
      if i >= len then true
      else
        let c = String.unsafe_get s i in
        let code = Char.code c in
        if code < 32 || code = 0x7F then false
        else if Char.equal c ' ' then
          if prev_space || i = 0 || i = len - 1 then false
          else is_clean (i + 1) true
        else is_clean (i + 1) false
    in
    if is_clean 0 false then s
    else begin
      let buf = Buffer.create len in
      let prev_space = ref false in
      let i = ref 0 in
      while !i < len do
        let c = String.unsafe_get s !i in
        let code = Char.code c in
        if code = 0x1B then i := skip_ansi_escape s len !i
        else begin
          if Char.equal c '\n' || Char.equal c '\r' || Char.equal c '\t' then begin
            if not !prev_space then begin
              Buffer.add_char buf ' ';
              prev_space := true
            end
          end
          else if code >= 32 && code <> 0x7F then begin
            let is_sp = Char.equal c ' ' in
            if not (is_sp && !prev_space) then Buffer.add_char buf c;
            prev_space := is_sp
          end;
          incr i
        end
      done;
      String.trim (Buffer.contents buf)
    end

let short_hash ?(len = 8) s =
  let trimmed = String.trim s in
  let cap = Int.max 0 len in
  if String.length trimmed <= cap then trimmed else String.sub trimmed 0 cap

let is_utf8_cont b = b land 0xC0 = 0x80

let clamp_utf8_cursor s idx =
  let len = String.length s in
  let c = Int.max 0 (Int.min len idx) in
  let rec align i =
    if i <= 0 || i >= len then i
    else if is_utf8_cont (Char.code s.[i]) then align (i - 1)
    else i
  in
  align c

let prev_utf8_boundary s idx =
  let i = clamp_utf8_cursor s idx in
  if i <= 0 then 0
  else
    let rec walk p =
      if p <= 0 then 0
      else if is_utf8_cont (Char.code s.[p]) then walk (p - 1)
      else p
    in
    walk (i - 1)

let next_utf8_boundary s idx =
  let len = String.length s in
  let i = clamp_utf8_cursor s idx in
  if i >= len then len
  else
    let rec walk p =
      if p >= len then len
      else if is_utf8_cont (Char.code s.[p]) then walk (p + 1)
      else p
    in
    walk (i + 1)

let drop_last_utf8 s =
  let len = String.length s in
  if len <= 0 then "" else String.sub s 0 (prev_utf8_boundary s len)
