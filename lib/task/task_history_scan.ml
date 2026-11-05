open Task_history_types
open Task_history_row

(* Zero-AST single-pass RFC 8259 scanner over a slice [pos, pos + len) in [s].
   Handles standard rows with unescaped ASCII keys and task IDs without
   allocating a Yojson.Safe.t AST or lexer buffer. Any escape in a key/ID,
   non-integer seq/ts_ms, >64 keys in an object, nesting >32, or malformed
   input falls back to [classify_row] so Yojson parity is exact. *)
let max_fast_depth = 32
let max_fast_keys = 64
let key_stride = max_fast_keys

let rec skip_ws s stop i =
  if i >= stop then i
  else
    match String.unsafe_get s i with
    | ' ' | '\t' | '\n' | '\r' -> skip_ws s stop (i + 1)
    | '\x0c' -> -1
    | _ -> i

let is_hex_digit = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false

let is_utf8_cont c =
  let code = Char.code c in
  code >= 0x80 && code <= 0xbf

let rec skip_valid_string s stop i =
  if i >= stop then -1
  else
    let c = String.unsafe_get s i in
    match c with
    | '"' -> i + 1
    | '\\' ->
      if i + 1 >= stop then -1
      else (
        match String.unsafe_get s (i + 1) with
        | '"' | '\\' | '/' | 'b' | 'f' | 'n' | 'r' | 't' ->
          skip_valid_string s stop (i + 2)
        | 'u' ->
          if i + 5 >= stop then -1
          else
            let h0 = String.unsafe_get s (i + 2) in
            let h1 = String.unsafe_get s (i + 3) in
            let h2 = String.unsafe_get s (i + 4) in
            let h3 = String.unsafe_get s (i + 5) in
            if not (is_hex_digit h0 && is_hex_digit h1 && is_hex_digit h2 && is_hex_digit h3) then -1
            else if (h0 = 'd' || h0 = 'D')
                    && (match h1 with '8' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true | _ -> false)
            then -1
            else skip_valid_string s stop (i + 6)
        | _ -> -1)
    | '\x00' .. '\x1f' -> -1
    | '\x20' .. '\x7f' -> skip_valid_string s stop (i + 1)
    | '\xc2' .. '\xdf' ->
      if i + 1 < stop && is_utf8_cont (String.unsafe_get s (i + 1)) then
        skip_valid_string s stop (i + 2)
      else -1
    | '\xe0' ->
      if i + 2 < stop
         && (let b1 = Char.code (String.unsafe_get s (i + 1)) in b1 >= 0xa0 && b1 <= 0xbf)
         && is_utf8_cont (String.unsafe_get s (i + 2))
      then skip_valid_string s stop (i + 3)
      else -1
    | '\xe1' .. '\xec' | '\xee' .. '\xef' ->
      if i + 2 < stop
         && is_utf8_cont (String.unsafe_get s (i + 1))
         && is_utf8_cont (String.unsafe_get s (i + 2))
      then skip_valid_string s stop (i + 3)
      else -1
    | '\xed' ->
      if i + 2 < stop
         && (let b1 = Char.code (String.unsafe_get s (i + 1)) in b1 >= 0x80 && b1 <= 0x9f)
         && is_utf8_cont (String.unsafe_get s (i + 2))
      then skip_valid_string s stop (i + 3)
      else -1
    | '\xf0' ->
      if i + 3 < stop
         && (let b1 = Char.code (String.unsafe_get s (i + 1)) in b1 >= 0x90 && b1 <= 0xbf)
         && is_utf8_cont (String.unsafe_get s (i + 2))
         && is_utf8_cont (String.unsafe_get s (i + 3))
      then skip_valid_string s stop (i + 4)
      else -1
    | '\xf1' .. '\xf3' ->
      if i + 3 < stop
         && is_utf8_cont (String.unsafe_get s (i + 1))
         && is_utf8_cont (String.unsafe_get s (i + 2))
         && is_utf8_cont (String.unsafe_get s (i + 3))
      then skip_valid_string s stop (i + 4)
      else -1
    | '\xf4' ->
      if i + 3 < stop
         && (let b1 = Char.code (String.unsafe_get s (i + 1)) in b1 >= 0x80 && b1 <= 0x8f)
         && is_utf8_cont (String.unsafe_get s (i + 2))
         && is_utf8_cont (String.unsafe_get s (i + 3))
      then skip_valid_string s stop (i + 4)
      else -1
    | _ -> -1

let rec find_unescaped_ascii_end s stop i =
  if i >= stop then -1
  else
    match String.unsafe_get s i with
    | '"' -> i
    | '\\' | '\x00' .. '\x1f' | '\x7f' .. '\xff' -> -1
    | _ -> find_unescaped_ascii_end s stop (i + 1)

let slice_is_nonempty_trimmed s off len =
  len > 0
  && not (is_whitespace (String.unsafe_get s off))
  && not (is_whitespace (String.unsafe_get s (off + len - 1)))

let rec slice_eq_lit_loop s off lit len k =
  if k = len then true
  else if String.unsafe_get s (off + k) <> String.unsafe_get lit k then false
  else slice_eq_lit_loop s off lit len (k + 1)

let slice_eq_lit s off len lit =
  len = String.length lit && slice_eq_lit_loop s off lit len 0

let rec slice_eq_slice_loop s off1 off2 len k =
  if k = len then true
  else if String.unsafe_get s (off1 + k) <> String.unsafe_get s (off2 + k) then false
  else slice_eq_slice_loop s off1 off2 len (k + 1)

let slice_eq_slice s off1 len1 off2 len2 =
  len1 = len2 && slice_eq_slice_loop s off1 off2 len1 0

let pack_key_fingerprint s k_off k_len =
  let first_char = if k_len > 0 then Char.code (String.unsafe_get s k_off) else 0 in
  (k_len lsl 40) lor (first_char lsl 32) lor k_off

let rec register_unique_key_loop s (key_buf : int array) base count k_off k_len fp fp_tag j =
  if j = count then (
    Array.unsafe_set key_buf (base + count) fp;
    true)
  else
    let prev_fp = Array.unsafe_get key_buf (base + j) in
    if (prev_fp lsr 32) = fp_tag
       && slice_eq_slice_loop s k_off (prev_fp land 0xffffffff) k_len 0
    then false
    else register_unique_key_loop s key_buf base count k_off k_len fp fp_tag (j + 1)

let register_unique_key s (key_buf : int array) base count k_off k_len =
  count < max_fast_keys
  && k_len <= 0xffff
  && k_off <= 0x7fffffff
  && (
    let fp = pack_key_fingerprint s k_off k_len in
    let fp_tag = fp lsr 32 in
    register_unique_key_loop s key_buf base count k_off k_len fp fp_tag 0)

let rec count_digits s stop i =
  if i < stop then
    match String.unsafe_get s i with
    | '0' .. '9' -> count_digits s stop (i + 1)
    | _ -> i
  else i

let scan_int_field s stop i =
  if i >= stop then -1
  else
    let i = if String.unsafe_get s i = '-' then i + 1 else i in
    if i >= stop then -1
    else
      match String.unsafe_get s i with
      | '0' ->
        let next = i + 1 in
        if next < stop
           && (match String.unsafe_get s next with '0' .. '9' | '.' | 'e' | 'E' -> true | _ -> false)
        then -1
        else next
      | '1' .. '9' ->
        let next = count_digits s stop (i + 1) in
        let digits = next - i in
        if digits > 18 then -1
        else if next < stop
                && (match String.unsafe_get s next with '.' | 'e' | 'E' -> true | _ -> false)
        then -1
        else next
      | _ -> -1

let skip_exponent s stop i =
  if i >= stop then i
  else
    match String.unsafe_get s i with
    | 'e' | 'E' ->
      let i = i + 1 in
      if i >= stop then -1
      else
        let i =
          match String.unsafe_get s i with
          | '+' | '-' -> i + 1
          | _ -> i
        in
        if i >= stop then -1
        else
          let exp_end = count_digits s stop i in
          let exp_digits = exp_end - i in
          if exp_digits < 1 || exp_digits > 2 then -1
          else exp_end
    | _ -> i

let skip_valid_number s stop i =
  if i >= stop then -1
  else
    let i = if String.unsafe_get s i = '-' then i + 1 else i in
    if i >= stop then -1
    else
      let int_end =
        match String.unsafe_get s i with
        | '0' ->
          let next = i + 1 in
          if next < stop && (match String.unsafe_get s next with '0' .. '9' -> true | _ -> false)
          then -1
          else next
        | '1' .. '9' ->
          let next = count_digits s stop (i + 1) in
          if next - i > 18 then -1 else next
        | _ -> -1
      in
      if int_end < 0 then -1
      else if int_end < stop && String.unsafe_get s int_end = '.' then
        let frac_start = int_end + 1 in
        let frac_end = count_digits s stop frac_start in
        let frac_digits = frac_end - frac_start in
        if frac_digits < 1 || frac_digits > 64 then -1
        else skip_exponent s stop frac_end
      else skip_exponent s stop int_end

let rec skip_valid_value s stop key_buf depth i =
  if depth >= max_fast_depth then -1
  else
    let i = skip_ws s stop i in
    if i < 0 || i >= stop then -1
    else
      match String.unsafe_get s i with
      | '"' -> skip_valid_string s stop (i + 1)
      | '-' | '0' .. '9' -> skip_valid_number s stop i
      | 't' ->
        if i + 4 <= stop
           && String.unsafe_get s (i + 1) = 'r'
           && String.unsafe_get s (i + 2) = 'u'
           && String.unsafe_get s (i + 3) = 'e'
        then i + 4
        else -1
      | 'f' ->
        if i + 5 <= stop
           && String.unsafe_get s (i + 1) = 'a'
           && String.unsafe_get s (i + 2) = 'l'
           && String.unsafe_get s (i + 3) = 's'
           && String.unsafe_get s (i + 4) = 'e'
        then i + 5
        else -1
      | 'n' ->
        if i + 4 <= stop
           && String.unsafe_get s (i + 1) = 'u'
           && String.unsafe_get s (i + 2) = 'l'
           && String.unsafe_get s (i + 3) = 'l'
        then i + 4
        else -1
      | '[' ->
        let i = skip_ws s stop (i + 1) in
        if i < 0 || i >= stop then -1
        else if String.unsafe_get s i = ']' then i + 1
        else skip_valid_array s stop key_buf (depth + 1) i
      | '{' ->
        let i = skip_ws s stop (i + 1) in
        if i < 0 || i >= stop then -1
        else if String.unsafe_get s i = '}' then i + 1
        else skip_valid_object s stop key_buf depth 0 i
      | _ -> -1

and skip_valid_array s stop key_buf depth i =
  let i = skip_valid_value s stop key_buf depth i in
  if i < 0 then -1
  else
    let i = skip_ws s stop i in
    if i < 0 || i >= stop then -1
    else
      match String.unsafe_get s i with
      | ']' -> i + 1
      | ',' -> skip_valid_array s stop key_buf depth (i + 1)
      | _ -> -1

and skip_valid_object s stop key_buf depth count i =
  let i = skip_ws s stop i in
  if i < 0 || i >= stop || String.unsafe_get s i <> '"' then -1
  else
    let k_off = i + 1 in
    let k_end = find_unescaped_ascii_end s stop k_off in
    if k_end < 0 then -1
    else
      let k_len = k_end - k_off in
      let base = depth * key_stride in
      if not (register_unique_key s key_buf base count k_off k_len) then -1
      else
        let i = skip_ws s stop (k_end + 1) in
        if i < 0 || i >= stop || String.unsafe_get s i <> ':' then -1
        else
          let i = skip_valid_value s stop key_buf (depth + 1) (i + 1) in
          if i < 0 then -1
          else
            let i = skip_ws s stop i in
            if i < 0 || i >= stop then -1
            else
              match String.unsafe_get s i with
              | '}' -> i + 1
              | ',' -> skip_valid_object s stop key_buf depth (count + 1) (i + 1)
              | _ -> -1

(* Pre-allocated [state : int array] layout (13 ints, zero heap allocation):
   - Slot 0 (subject / audit task):   state[0] = 0(absent)|1(null)|2(slice), state[1]=off, state[2]=len
   - Slot 3 (payload / audit task_id): state[3] = 0|1|2, state[4]=off, state[5]=len
   - Slot 6 (context):                 state[6] = 0|1|2, state[7]=off, state[8]=len
   - Entity scratch:                   state[9]=kind_off, state[10]=kind_len, state[11]=id_off, state[12]=id_len
   Return code of [scan_row_slice_fast]:
   - 0  = Fast_unrelated
   - 1  = Fast_task (matched slice offset in state[1], length in state[2])
   - -1 = Fast_fallback *)

let scan_entity_field s stop (state : int array) ~is_subject i =
  let i = skip_ws s stop i in
  if i < 0 || i >= stop then -1
  else
    match String.unsafe_get s i with
    | 'n' ->
      if i + 4 <= stop
         && String.unsafe_get s (i + 1) = 'u'
         && String.unsafe_get s (i + 2) = 'l'
         && String.unsafe_get s (i + 3) = 'l'
      then i + 4
      else -1
    | '{' ->
      let i1 = skip_ws s stop (i + 1) in
      if i1 < 0 || i1 >= stop || String.unsafe_get s i1 <> '"' then -1
      else
        let k1_off = i1 + 1 in
        let k1_end = find_unescaped_ascii_end s stop k1_off in
        if k1_end < 0 then -1
        else
          let k1_len = k1_end - k1_off in
          let c1 = skip_ws s stop (k1_end + 1) in
          if c1 < 0 || c1 >= stop || String.unsafe_get s c1 <> ':' then -1
          else
            let v1 = skip_ws s stop (c1 + 1) in
            if v1 < 0 || v1 >= stop || String.unsafe_get s v1 <> '"' then -1
            else
              let v1_off = v1 + 1 in
              let v1_end = find_unescaped_ascii_end s stop v1_off in
              if v1_end < 0 then -1
              else
                let v1_len = v1_end - v1_off in
                if not (slice_is_nonempty_trimmed s v1_off v1_len) then -1
                else
                  let sep = skip_ws s stop (v1_end + 1) in
                  if sep < 0 || sep >= stop || String.unsafe_get s sep <> ',' then -1
                  else
                    let i2 = skip_ws s stop (sep + 1) in
                    if i2 < 0 || i2 >= stop || String.unsafe_get s i2 <> '"' then -1
                    else
                      let k2_off = i2 + 1 in
                      let k2_end = find_unescaped_ascii_end s stop k2_off in
                      if k2_end < 0 then -1
                      else
                        let k2_len = k2_end - k2_off in
                        let c2 = skip_ws s stop (k2_end + 1) in
                        if c2 < 0 || c2 >= stop || String.unsafe_get s c2 <> ':' then -1
                        else
                          let v2 = skip_ws s stop (c2 + 1) in
                          if v2 < 0 || v2 >= stop || String.unsafe_get s v2 <> '"' then -1
                          else
                            let v2_off = v2 + 1 in
                            let v2_end = find_unescaped_ascii_end s stop v2_off in
                            if v2_end < 0 then -1
                            else
                              let v2_len = v2_end - v2_off in
                              if not (slice_is_nonempty_trimmed s v2_off v2_len) then -1
                              else
                                let close = skip_ws s stop (v2_end + 1) in
                                if close < 0 || close >= stop || String.unsafe_get s close <> '}' then
                                  -1
                                else if slice_eq_lit s k1_off k1_len "kind"
                                        && slice_eq_lit s k2_off k2_len "id"
                                then (
                                  if is_subject && slice_eq_lit s v1_off v1_len "task" then (
                                    Array.unsafe_set state 0 2;
                                    Array.unsafe_set state 1 v2_off;
                                    Array.unsafe_set state 2 v2_len);
                                  close + 1
                                ) else if slice_eq_lit s k1_off k1_len "id"
                                          && slice_eq_lit s k2_off k2_len "kind"
                                then (
                                  if is_subject && slice_eq_lit s v2_off v2_len "task" then (
                                    Array.unsafe_set state 0 2;
                                    Array.unsafe_set state 1 v1_off;
                                    Array.unsafe_set state 2 v1_len);
                                  close + 1
                                ) else -1
    | _ -> -1

let scan_id_value s stop (state : int array) slot_base i =
  let i = skip_ws s stop i in
  if i < 0 || i >= stop then -1
  else
    match String.unsafe_get s i with
    | 'n' ->
      if i + 4 <= stop
         && String.unsafe_get s (i + 1) = 'u'
         && String.unsafe_get s (i + 2) = 'l'
         && String.unsafe_get s (i + 3) = 'l'
      then (
        Array.unsafe_set state slot_base 1;
        i + 4)
      else -1
    | '"' ->
      let v_off = i + 1 in
      let v_end = find_unescaped_ascii_end s stop v_off in
      if v_end < 0 then -1
      else
        let v_len = v_end - v_off in
        if not (slice_is_nonempty_trimmed s v_off v_len) then -1
        else (
          Array.unsafe_set state slot_base 2;
          Array.unsafe_set state (slot_base + 1) v_off;
          Array.unsafe_set state (slot_base + 2) v_len;
          v_end + 1)
    | _ -> -1

let rec scan_assoc_loop s stop key_buf (state : int array) slot_base depth base count pos =
  let pos = skip_ws s stop pos in
  if pos < 0 || pos >= stop || String.unsafe_get s pos <> '"' then -1
  else
    let k_off = pos + 1 in
    let k_end = find_unescaped_ascii_end s stop k_off in
    if k_end < 0 then -1
    else
      let k_len = k_end - k_off in
      if not (register_unique_key s key_buf base count k_off k_len) then -1
      else
        let colon = skip_ws s stop (k_end + 1) in
        if colon < 0 || colon >= stop || String.unsafe_get s colon <> ':' then -1
        else
          let next_pos =
            if slice_eq_lit s k_off k_len "task_id" then
              scan_id_value s stop state slot_base (colon + 1)
            else
              skip_valid_value s stop key_buf (depth + 1) (colon + 1)
          in
          if next_pos < 0 then -1
          else
            let after = skip_ws s stop next_pos in
            if after < 0 || after >= stop then -1
            else
              match String.unsafe_get s after with
              | '}' -> after + 1
              | ',' ->
                scan_assoc_loop s stop key_buf state slot_base depth base (count + 1) (after + 1)
              | _ -> -1

let scan_assoc_extracting_task_id s stop key_buf (state : int array) slot_base depth i =
  let i = skip_ws s stop i in
  if i < 0 || i >= stop || String.unsafe_get s i <> '{' then -1
  else
    let i = skip_ws s stop (i + 1) in
    if i < 0 || i >= stop then -1
    else if String.unsafe_get s i = '}' then i + 1
    else scan_assoc_loop s stop key_buf state slot_base depth (depth * key_stride) 0 i

let rec skip_string_list s stop i =
  let i = skip_ws s stop i in
  if i < 0 || i >= stop || String.unsafe_get s i <> '"' then -1
  else
    let i = skip_valid_string s stop (i + 1) in
    if i < 0 then -1
    else
      let i = skip_ws s stop i in
      if i < 0 || i >= stop then -1
      else
        match String.unsafe_get s i with
        | ']' -> i + 1
        | ',' -> skip_string_list s stop (i + 1)
        | _ -> -1

let scan_tags_field s stop i =
  let i = skip_ws s stop i in
  if i < 0 || i >= stop || String.unsafe_get s i <> '[' then -1
  else
    let i = skip_ws s stop (i + 1) in
    if i < 0 || i >= stop then -1
    else if String.unsafe_get s i = ']' then i + 1
    else skip_string_list s stop i

let reconcile_fast_state s (state : int array) : int =
  let s0 = Array.unsafe_get state 0 in
  let s1 = Array.unsafe_get state 3 in
  let s2 = Array.unsafe_get state 6 in
  let has_null = s0 = 1 || s1 = 1 || s2 = 1 in
  let has_slice = s0 = 2 || s1 = 2 || s2 = 2 in
  if not has_slice then
    0 (* Fast_unrelated *)
  else if has_null then
    -1 (* Fast_fallback: mix of string task_id and explicit null *)
  else
    let base_off =
      if s0 = 2 then Array.unsafe_get state 1
      else if s1 = 2 then Array.unsafe_get state 4
      else Array.unsafe_get state 7
    in
    let base_len =
      if s0 = 2 then Array.unsafe_get state 2
      else if s1 = 2 then Array.unsafe_get state 5
      else Array.unsafe_get state 8
    in
    let ok1 =
      s1 <> 2
      || s0 <> 2
      || slice_eq_slice s base_off base_len (Array.unsafe_get state 4) (Array.unsafe_get state 5)
    in
    let ok2 =
      s2 <> 2
      || (s0 <> 2 && s1 <> 2)
      || slice_eq_slice s base_off base_len (Array.unsafe_get state 7) (Array.unsafe_get state 8)
    in
    if ok1 && ok2 then (
      Array.unsafe_set state 1 base_off;
      Array.unsafe_set state 2 base_len;
      1 (* Fast_task *))
    else -1 (* Fast_fallback *)

let rec scan_activity_loop s stop key_buf (state : int array) mask cur =
  let cur = skip_ws s stop cur in
  if cur < 0 || cur >= stop || String.unsafe_get s cur <> '"' then -1
  else
    let k_off = cur + 1 in
    let k_end = find_unescaped_ascii_end s stop k_off in
    if k_end < 0 then -1
    else
      let k_len = k_end - k_off in
      let colon = skip_ws s stop (k_end + 1) in
      if colon < 0 || colon >= stop || String.unsafe_get s colon <> ':' then -1
      else
        let v_start = colon + 1 in
        let bit =
          match k_len with
          | 3 -> if slice_eq_lit_loop s k_off "seq" 3 0 then 1 else 0
          | 4 ->
            if slice_eq_lit_loop s k_off "kind" 4 0 then 8
            else if slice_eq_lit_loop s k_off "tags" 4 0 then 128
            else 0
          | 5 ->
            if slice_eq_lit_loop s k_off "ts_ms" 5 0 then 2
            else if slice_eq_lit_loop s k_off "actor" 5 0 then 16
            else 0
          | 6 -> if slice_eq_lit_loop s k_off "ts_iso" 6 0 then 4 else 0
          | 7 ->
            if slice_eq_lit_loop s k_off "subject" 7 0 then 32
            else if slice_eq_lit_loop s k_off "payload" 7 0 then 64
            else if slice_eq_lit_loop s k_off "context" 7 0 then 256
            else 0
          | _ -> 0
        in
        if bit = 0 || (mask land bit) <> 0 then -1
        else
          let next_i =
            match bit with
            | 1 | 2 -> scan_int_field s stop v_start
            | 4 | 8 ->
              let v = skip_ws s stop v_start in
              if v >= 0 && v < stop && String.unsafe_get s v = '"' then
                skip_valid_string s stop (v + 1)
              else -1
            | 16 -> scan_entity_field s stop state ~is_subject:false v_start
            | 32 -> scan_entity_field s stop state ~is_subject:true v_start
            | 64 ->
              let v = skip_ws s stop v_start in
              if v < 0 || v >= stop then -1
              else if String.unsafe_get s v = '{' then
                scan_assoc_extracting_task_id s stop key_buf state 3 1 v
              else
                skip_valid_value s stop key_buf 1 v
            | 128 -> scan_tags_field s stop v_start
            | 256 -> scan_assoc_extracting_task_id s stop key_buf state 6 1 v_start
            | _ -> -1
          in
          if next_i < 0 then -1
          else
            let mask = mask lor bit in
            let after = skip_ws s stop next_i in
            if after < 0 || after >= stop then -1
            else
              match String.unsafe_get s after with
              | ',' -> scan_activity_loop s stop key_buf state mask (after + 1)
              | '}' ->
                let tail = skip_ws s stop (after + 1) in
                if tail <> stop || (mask land 0xff) <> 0xff then -1
                else reconcile_fast_state s state
              | _ -> -1

let scan_activity_slice_fast s ~pos ~len key_buf (state : int array) =
  let stop = pos + len in
  let i = skip_ws s stop pos in
  if i < 0 || i >= stop || String.unsafe_get s i <> '{' then -1
  else
    let i = skip_ws s stop (i + 1) in
    if i < 0 || i >= stop || String.unsafe_get s i = '}' then -1
    else (
      Array.unsafe_set state 0 0;
      Array.unsafe_set state 3 0;
      Array.unsafe_set state 6 0;
      scan_activity_loop s stop key_buf state 0 i)

let rec scan_audit_loop s stop key_buf (state : int array) count cur =
  let cur = skip_ws s stop cur in
  if cur < 0 || cur >= stop || String.unsafe_get s cur <> '"' then -1
  else
    let k_off = cur + 1 in
    let k_end = find_unescaped_ascii_end s stop k_off in
    if k_end < 0 then -1
    else
      let k_len = k_end - k_off in
      if not (register_unique_key s key_buf 0 count k_off k_len) then -1
      else
        let colon = skip_ws s stop (k_end + 1) in
        if colon < 0 || colon >= stop || String.unsafe_get s colon <> ':' then -1
        else
          let v_start = colon + 1 in
          let next_i =
            if slice_eq_lit s k_off k_len "task" then
              scan_id_value s stop state 0 v_start
            else if slice_eq_lit s k_off k_len "task_id" then
              scan_id_value s stop state 3 v_start
            else
              skip_valid_value s stop key_buf 1 v_start
          in
          if next_i < 0 then -1
          else
            let after = skip_ws s stop next_i in
            if after < 0 || after >= stop then -1
            else
              match String.unsafe_get s after with
              | ',' -> scan_audit_loop s stop key_buf state (count + 1) (after + 1)
              | '}' ->
                if skip_ws s stop (after + 1) <> stop then -1
                else reconcile_fast_state s state
              | _ -> -1

let scan_audit_slice_fast s ~pos ~len key_buf (state : int array) =
  let stop = pos + len in
  let i = skip_ws s stop pos in
  if i < 0 || i >= stop || String.unsafe_get s i <> '{' then -1
  else
    let i = skip_ws s stop (i + 1) in
    if i < 0 || i >= stop then -1
    else if String.unsafe_get s i = '}' then
      if skip_ws s stop (i + 1) = stop then 0 else -1
    else (
      Array.unsafe_set state 0 0;
      Array.unsafe_set state 3 0;
      Array.unsafe_set state 6 0;
      scan_audit_loop s stop key_buf state 0 i)

let scan_row_slice_fast ~source s ~pos ~len key_buf state =
  match source with
  | Activity -> scan_activity_slice_fast s ~pos ~len key_buf state
  | Audit -> scan_audit_slice_fast s ~pos ~len key_buf state
