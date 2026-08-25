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

let validate_name = Safe_identifier.is_portable_name

let invalid_name_error name =
  Printf.sprintf
    "invalid keeper name %S: %s"
    name
    (Safe_identifier.portable_name_error ~field:"keeper name")
;;

(* ── Configuration constants ────────────────────────────────── *)

let default_proactive_enabled = true

(* Environment-configurable caps. Defaults were raised from 480/320 to 4096
   because silent truncation in the dashboard made operators think edits were
   not persisting. Operators can lower them via env vars if a deployment needs
   tighter prompt budgets. *)
let prompt_render_max_bytes =
  match Env_config_core.raw_value_opt "MASC_KEEPER_PROMPT_RENDER_MAX_BYTES" with
  | Some v ->
    (match int_of_string_opt (String.trim v) with
     | Some n when n > 0 -> n
     | _ -> 4096)
  | None -> 4096

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

(* ── Prompt text normalization ──────────────────────────────── *)

(* #10552: trim BOTH before and after [String_util.utf8_prefix].  The
   pre-fix sequence was [trim → prefix], but [String_util.utf8_prefix]
   can cut at a position that leaves trailing ASCII whitespace
   (e.g. a 322-byte live desires field ends with [...는 것.] —
   the prefix at max_bytes=320 backs up to byte 318, ending at the
   space before [것]). That made the previous normalizer
   non-idempotent: applying it once produces a 318-byte string ending
   in a space; applying it AGAIN trims the space to 317 bytes.
   instruction comparison then sees [normalize meta_318 = 317] and
   [normalize raw_322 = 318] — unequal — and re-sync fires every
   reconcile tick.  Trimming after prefix makes the function
   idempotent: [normalize(normalize(x)) = normalize(x)]. *)
let normalize_prompt_text ~(max_bytes : int) (raw : string) : string =
  let s = String.trim raw in
  if s = "" then ""
  else
    let cut = String_util.utf8_prefix ~max_bytes s in
    String.trim cut
