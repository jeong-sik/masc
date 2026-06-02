(** Shared HTTP response payload handling.

    Keep Accept-Encoding parsing, compression choice, and response headers in
    one place so H1, H2, and gateway routes do not drift as endpoint count
    grows. *)

let vary_accept_encoding = ("vary", "Accept-Encoding")

let is_ascii_space = function
  | ' ' | '\t' | '\n' | '\r' | '\012' -> true
  | _ -> false

let trim_span value start stop =
  let rec trim_left i =
    if i < stop && is_ascii_space value.[i] then
      trim_left (i + 1)
    else
      i
  in
  let start = trim_left start in
  let rec trim_right i =
    if i > start && is_ascii_space value.[i - 1] then
      trim_right (i - 1)
    else
      i
  in
  start, trim_right stop

let index_char value ch start stop =
  let rec loop i =
    if i >= stop then
      None
    else if Char.equal value.[i] ch then
      Some i
    else
      loop (i + 1)
  in
  loop start

let ascii_lower_char = function
  | 'A' .. 'Z' as ch -> Char.chr (Char.code ch + 32)
  | ch -> ch

let equal_ascii_ci_span value start stop token =
  let len = stop - start in
  len = String.length token
  &&
  let rec loop i =
    if i = len then
      true
    else
      Char.equal
        (ascii_lower_char value.[start + i])
        (ascii_lower_char token.[i])
      && loop (i + 1)
  in
  loop 0

let starts_with_ascii_ci_span value start stop prefix =
  let len = stop - start in
  let prefix_len = String.length prefix in
  len >= prefix_len
  &&
  let rec loop i =
    if i = prefix_len then
      true
    else
      Char.equal
        (ascii_lower_char value.[start + i])
        (ascii_lower_char prefix.[i])
      && loop (i + 1)
  in
  loop 0

let q_param_value value start stop =
  let start, stop = trim_span value start stop in
  if starts_with_ascii_ci_span value start stop "q=" then
    let value_start = start + 2 in
    match float_of_string_opt (String.sub value value_start (stop - value_start)) with
    | Some q -> Some q
    | None -> Some 0.0
  else
    None

let q_value_in_params value start stop =
  let rec loop start =
    if start >= stop then
      None
    else
      let next =
        match index_char value ';' start stop with
        | Some idx -> idx
        | None -> stop
      in
      match q_param_value value start next with
      | Some q -> Some q
      | None -> if next >= stop then None else loop (next + 1)
  in
  Option.value ~default:1.0 (loop start)

let param_exists value start stop target =
  let rec loop start =
    if start >= stop then
      false
    else
      let next =
        match index_char value ';' start stop with
        | Some idx -> idx
        | None -> stop
      in
      let param_start, param_stop = trim_span value start next in
      equal_ascii_ci_span value param_start param_stop target
      || (next < stop && loop (next + 1))
  in
  loop start

let encoding_matches_span value start stop token =
  let token_stop, params_start =
    match index_char value ';' start stop with
    | Some idx -> idx, idx + 1
    | None -> stop, stop
  in
  let token_start, token_stop = trim_span value start token_stop in
  (equal_ascii_ci_span value token_start token_stop token
   || equal_ascii_ci_span value token_start token_stop "*")
  && q_value_in_params value params_start stop > 0.0

let accepts_encoding_header ~token = function
  | None -> false
  | Some accept_encoding ->
      let stop = String.length accept_encoding in
      let rec loop start =
        if start >= stop then
          false
        else
          let next =
            match index_char accept_encoding ',' start stop with
            | Some idx -> idx
            | None -> stop
          in
          encoding_matches_span accept_encoding start next token
          || (next < stop && loop (next + 1))
      in
      loop 0

let accepts_zstd_header header =
  accepts_encoding_header ~token:"zstd" header

let accepts_zstd_dict_header = function
  | None -> false
  | Some accept_encoding ->
      let stop = String.length accept_encoding in
      let segment_matches start stop =
        let token_stop, params_start =
          match index_char accept_encoding ';' start stop with
          | Some idx -> idx, idx + 1
          | None -> stop, stop
        in
        let token_start, token_stop = trim_span accept_encoding start token_stop in
        q_value_in_params accept_encoding params_start stop > 0.0
        && (equal_ascii_ci_span accept_encoding token_start token_stop "zstd-dict"
            || (equal_ascii_ci_span accept_encoding token_start token_stop "zstd"
                && param_exists accept_encoding params_start stop "dict=masc"))
      in
      let rec loop start =
        if start >= stop then
          false
        else
          let next =
            match index_char accept_encoding ',' start stop with
            | Some idx -> idx
            | None -> stop
          in
          segment_matches start next || (next < stop && loop (next + 1))
      in
      loop 0

let compress_body ?(level = 3) ?(compress = true) ~accept_encoding body =
  if not compress then
    body, []
  else if not (accepts_zstd_header accept_encoding) then
    body, [ vary_accept_encoding ]
  else
    match Compression_codec.compress ~level body with
    | Compression_codec.Unchanged payload -> payload, [ vary_accept_encoding ]
    | Compression_codec.Compressed { payload; encoding } ->
        ( payload
        , [
            ("content-encoding", Compression_codec.content_encoding encoding);
            vary_accept_encoding;
          ] )
