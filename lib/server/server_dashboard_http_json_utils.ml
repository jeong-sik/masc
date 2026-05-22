(** Small JSON / string utility helpers for the dashboard HTTP
    surface.

    Nine pure helpers used throughout [Server_dashboard_http]:

    [compact_preview ~max_chars text] — trims, then truncates with
    a [...] suffix iff over the budget. Returns (preview, truncated).

    JSON readers:
    - [json_member key json] — `Assoc field-by-key with [`Null] on
      miss / non-Assoc.
    - [json_string / json_int / json_float / json_bool] — Json_util
      typed-getter aliases (key, json) order swap.
    - [json_number] — RFC-0142 PR-5 typed-failure variant via
      Json_field.float |> to_option (accepts both `Float and `Int).
    - [json_assoc] — Json_field.assoc adapter wrapping back to
      [`Assoc fields] option.

    [string_has_prefix ~prefix value] — explicit-length prefix
    equality without throwing on short input.

    Verbatim extract from [Server_dashboard_http]; the parent
    retains 9 single-line value aliases. *)

let compact_preview ~max_chars text =
  let text = String.trim text in
  if String.length text <= max_chars
  then text, false
  else String.sub text 0 max_chars ^ "...", true
;;

let json_member key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some v -> v
     | None -> `Null)
  | _ -> `Null
;;

let json_string key json = Json_util.get_string json key
let json_int key json = Json_util.get_int json key
let json_float key json = Json_util.get_float json key
let json_bool key json = Json_util.get_bool json key

let json_number key json =
  Json_field.float json key |> Json_field.to_option
;;

let json_assoc key json =
  Json_field.assoc json key
  |> Json_field.to_option
  |> Option.map (fun fields -> `Assoc fields)
;;

let string_has_prefix ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len
  && String.equal (String.sub value 0 prefix_len) prefix
;;
