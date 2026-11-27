(** Keeper_config_text — String/UTF-8 processing, bool parsing, input key
    validation, and prompt text normalization.

    Extracted from [keeper_config.ml] during godfile decomposition.
    These functions have no back-references to keeper_config itself —
    they depend only on external modules (Env_config_core, Re, Uchar,
    Tool_args, Yojson, Log).

    @since God file decomposition *)

(* ── Bool / string parsing ──────────────────────────────────── *)

let bool_of_string raw =
  let v = String.trim raw |> String.lowercase_ascii in
  if v = "1" || v = "true" || v = "yes" || v = "y" || v = "on" then Some true
  else if v = "0" || v = "false" || v = "no" || v = "n" || v = "off" then Some false
  else None

let bool_of_env_default name ~(default : bool) =
  match Env_config_core.raw_value_opt name with
  | None -> default
  | Some raw -> Option.value (bool_of_string raw) ~default

(* ── Name validation ────────────────────────────────────────── *)

let validate_name name =
  Result.is_ok (Keeper_id.Keeper_name.of_string name)

(* The reason is the typed name's own, so a rule added there is explained here
   without a second copy of it. *)
let invalid_name_error name =
  let reason =
    match Keeper_id.Keeper_name.of_string name with
    | Error reason -> reason
    | Ok (_ : Keeper_id.Keeper_name.t) ->
      Safe_identifier.portable_name_error ~field:"keeper_name"
  in
  Printf.sprintf "invalid keeper name %S: %s" name reason
;;

(* ── UTF-8 string processing ────────────────────────────────── *)


let utf8_repair_string (s : string) : string =
  let len = String.length s in
  let buf = Buffer.create len in
  let rec loop i =
    if i >= len then ()
    else
      let dec = String.get_utf_8_uchar s i in
      let dlen = Uchar.utf_decode_length dec in
      if dlen > 0 && Uchar.utf_decode_is_valid dec then (
        Buffer.add_substring buf s i dlen;
        loop (i + dlen))
      else (
        Buffer.add_string buf "\xEF\xBF\xBD";
        loop (i + 1))
  in
  loop 0;
  Buffer.contents buf

