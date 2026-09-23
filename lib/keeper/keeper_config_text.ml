(** Keeper_config_text — String/UTF-8 processing, bool parsing, input key
    validation, and prompt text normalization.

    Extracted from [keeper_config.ml] during godfile decomposition.
    These functions have no back-references to keeper_config itself —
    they depend only on external modules (Env_config_core, Re, Uchar,
    Tool_args, Yojson, Log).

    @since God file decomposition *)

open Tool_args

(* ── Bool / string parsing ──────────────────────────────────── *)

let bool_default_true_of_env name =
  match Env_config_core.raw_value_opt name with
  | None -> true
  | Some v ->
      let v = String.trim v |> String.lowercase_ascii in
      not (v = "0" || v = "false" || v = "no" || v = "n")

let bool_of_string raw =
  let v = String.trim raw |> String.lowercase_ascii in
  if v = "1" || v = "true" || v = "yes" || v = "y" || v = "on" then Some true
  else if v = "0" || v = "false" || v = "no" || v = "n" || v = "off" then Some false
  else None

let bool_of_env_default name ~(default : bool) =
  match Env_config_core.raw_value_opt name with
  | None -> default
  | Some raw -> Option.value (bool_of_string raw) ~default

let bool_of_env_opt name =
  match Env_config_core.raw_value_opt name with
  | None -> None
  | Some raw -> bool_of_string raw

(* ── Name validation ────────────────────────────────────────── *)

(* A keeper's directory is [keepers/<name>], beside the stores kept directly
   under [keepers/]; a keeper named like one of them would share its
   directory. [Keeper_id.Keeper_name.of_string] refuses the same names. *)
let is_keepers_root_store_name = Common.is_keepers_root_store_dirname

let validate_name name =
  Safe_identifier.is_portable_name name && not (is_keepers_root_store_name name)

let invalid_name_error name =
  if Safe_identifier.is_portable_name name && is_keepers_root_store_name name
  then
    Printf.sprintf
      "invalid keeper name %S: keepers/%s is a runtime store directory, not a keeper"
      name name
  else
    Printf.sprintf
      "invalid keeper name %S: %s"
      name
      (Safe_identifier.portable_name_error ~field:"keeper name")
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

