(** Generic JSON extraction and normalization helpers for mission briefing. *)

let compact_text ?(max_len = 96) raw =
  let normalized =
    String.trim raw |> String.split_on_char '\n' |> String.concat " " |> String.trim
  in
  if normalized = "" then ""
  else String_util.utf8_safe ~max_bytes:((max_len - 1) + 3) ~suffix:"…" normalized |> String_util.to_string

let member_assoc = Dashboard_utils.member_assoc
let string_field = Dashboard_utils.string_field

let take = List.take
