(** Shared HTTP response payload handling.

    Keep Accept-Encoding parsing, compression choice, and response headers in
    one place so H1, H2, and gateway routes do not drift as endpoint count
    grows. *)

let vary_accept_encoding = ("vary", "Accept-Encoding")

let lower_trim s = String.trim s |> String.lowercase_ascii

let q_value params =
  let parse_q param =
    let param = lower_trim param in
    if String.starts_with ~prefix:"q=" param then
      match float_of_string_opt (String.sub param 2 (String.length param - 2)) with
      | Some q -> Some q
      | None -> Some 0.0
    else
      None
  in
  Option.value ~default:1.0 (List.find_map parse_q params)

let encoding_matches accepted token =
  match String.split_on_char ';' accepted with
  | [] -> false
  | raw_token :: params ->
      let raw_token = lower_trim raw_token in
      (String.equal raw_token token || String.equal raw_token "*") && q_value params > 0.0

let accepts_encoding_header ~token = function
  | None -> false
  | Some accept_encoding ->
      accept_encoding
      |> String.split_on_char ','
      |> List.exists (fun accepted -> encoding_matches accepted token)

let accepts_zstd_header header =
  accepts_encoding_header ~token:"zstd" header

let accepts_zstd_dict_header = function
  | None -> false
  | Some accept_encoding ->
      accept_encoding
      |> String.split_on_char ','
      |> List.exists (fun accepted ->
        match String.split_on_char ';' accepted with
        | [] -> false
        | raw_token :: params ->
            let raw_token = lower_trim raw_token in
            let params = List.map lower_trim params in
            q_value params > 0.0
            && (String.equal raw_token "zstd-dict"
                || (String.equal raw_token "zstd"
                    && List.exists (String.equal "dict=masc") params)))

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
