let contains_substring s needle = String_util.contains_substring s needle

let redact_url_credentials token =
  let redact_after_scheme token scheme =
    if String.starts_with ~prefix:scheme token
    then (
      let scheme_len = String.length scheme in
      match String.index_from_opt token scheme_len '@' with
      | Some at_idx ->
        let slash_idx =
          match String.index_from_opt token scheme_len '/' with
          | Some idx -> idx
          | None -> String.length token
        in
        if at_idx < slash_idx
        then
          String.sub token 0 scheme_len
          ^ "[REDACTED]"
          ^ String.sub token at_idx (String.length token - at_idx)
        else token
      | None -> token)
    else token
  in
  token
  |> fun t -> redact_after_scheme t "https://"
  |> fun t -> redact_after_scheme t "http://"
;;

let redact_inline_secret_assignment token =
  let redact_after token marker =
    if contains_substring token marker
    then (
      let marker_len = String.length marker in
      let rec find i =
        if i + marker_len > String.length token
        then None
        else if String.sub token i marker_len = marker
        then Some i
        else find (i + 1)
      in
      match find 0 with
      | Some idx -> String.sub token 0 (idx + marker_len) ^ "[REDACTED]"
      | None -> token)
    else token
  in
  token
  |> fun t ->
  redact_after t ":_authToken="
  |> fun t ->
  redact_after t "_authToken="
  |> fun t ->
  redact_after t "token="
  |> fun t ->
  redact_after t "password="
  |> fun t -> redact_after t "passwd=" |> fun t -> redact_after t "api-key="
;;

let sanitize_command_for_log cmd =
  let sensitive_flags =
    [ "--token"; "--password"; "--passwd"; "--auth-token"; "--api-key" ]
  in
  let parts = String.split_on_char ' ' cmd in
  let rec redact prev_sensitive acc = function
    | [] -> String.concat " " (List.rev acc)
    | part :: rest ->
      let part =
        if prev_sensitive && part <> ""
        then "[REDACTED]"
        else part |> redact_url_credentials |> redact_inline_secret_assignment
      in
      let next_sensitive = List.mem (String.lowercase_ascii part) sensitive_flags in
      redact next_sensitive (part :: acc) rest
  in
  redact false [] parts
;;

let truncate_for_log ?(max_len = 240) s =
  String_util.utf8_safe ~max_bytes:(max_len + 3) ~suffix:"..." s |> String_util.to_string
;;
