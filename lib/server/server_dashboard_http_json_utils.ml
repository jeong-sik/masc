(** Small JSON / string utility helpers for the dashboard HTTP
    surface.

    Pure helpers used throughout [Server_dashboard_http]:

    [compact_preview ~max_chars text] — trims, then truncates with
    a [...] suffix iff over the budget. Returns (preview, truncated).

    JSON readers:
    - [json_member key json] — `Assoc field-by-key with [`Null] on
      miss / non-Assoc.
    - [json_number] — RFC-0142 PR-5 typed-failure variant via
      Json_field.float_opt (accepts both `Float and `Int). *)

(* [max_chars] is a byte budget for the kept text. The cut moves back to a
   UTF-8 character boundary: a receipt error message is often Korean model
   output, and a split syllable reached the dashboard as U+FFFD. *)
let compact_preview ~max_chars text =
  let text = String.trim text in
  if String.length text <= max_chars
  then text, false
  else String_util.utf8_prefix ~max_bytes:max_chars text ^ "...", true
;;

let json_member key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some v -> v
     | None -> `Null)
  | _ -> `Null
;;

let[@inline always] json_number key json =
  Json_field.float_opt json key
;;
