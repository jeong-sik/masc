let clamp_index len idx =
  if len <= 0 then 0
  else if idx < 0 then 0
  else if idx >= len then len - 1
  else idx

let contains_ci ~needle haystack =
  let n_len = String.length needle in
  if n_len = 0 then true
  else
    let h_len = String.length haystack in
    if n_len > h_len then false
    else
      let n_low = String.lowercase_ascii needle in
      let h_low = String.lowercase_ascii haystack in
      let limit = h_len - n_len in
      let rec scan i =
        if i > limit then false
        else if String.equal (String.sub h_low i n_len) n_low then true
        else scan (i + 1)
      in
      scan 0

let sanitize_single_line s =
  let len = String.length s in
  if len = 0 then ""
  else
    let buf = Buffer.create len in
    let prev_space = ref false in
    for i = 0 to len - 1 do
      let c = s.[i] in
      let code = Char.code c in
      if Char.equal c '\n' || Char.equal c '\r' || Char.equal c '\t' then begin
        if not !prev_space then begin
          Buffer.add_char buf ' ';
          prev_space := true
        end
      end
      else if code >= 32 then begin
        let is_sp = Char.equal c ' ' in
        if not (is_sp && !prev_space) then Buffer.add_char buf c;
        prev_space := is_sp
      end
    done;
    String.trim (Buffer.contents buf)

let short_hash ?(len = 8) s =
  let trimmed = String.trim s in
  let cap = Int.max 0 len in
  if String.length trimmed <= cap then trimmed else String.sub trimmed 0 cap
