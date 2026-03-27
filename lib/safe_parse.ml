(** Safe parsing utilities with optional warning logs.

    These functions replace the pattern:
    {[
      try int_of_string s with _ -> default
    ]}

    with centralized, debuggable alternatives that log warnings
    when falling back to defaults. Enable logging with:
    {[
      MASC_PARSE_WARN=1
    ]}
*)

(** Whether to log parse warnings. Default: false to avoid noise. *)
let warn_enabled () = Env_config.Server.Runtime.parse_warn

(** Log a parse warning if enabled. *)
let warn ~context ~input ~fallback =
  if warn_enabled () then
    Log.Misc.error "%s: failed to parse '%s', using default '%s'"
      context
      (String.sub input 0 (min 50 (String.length input)))
      fallback

(** {1 Primitive Parsers} *)

(** Parse int with default value. Logs warning when fallback is used. *)
let int ~context ~default s =
  try int_of_string s
  with Failure _ ->
    warn ~context ~input:s ~fallback:(string_of_int default);
    default

(** Parse int, return None on failure (no warning). *)
let int_opt s =
  try Some (int_of_string s)
  with Failure _ -> None

(** Parse float with default value. Logs warning when fallback is used. *)
let float ~context ~default s =
  try float_of_string s
  with Failure _ ->
    warn ~context ~input:s ~fallback:(Printf.sprintf "%.2f" default);
    default

(** Parse float, return None on failure (no warning). *)
let float_opt s =
  try Some (float_of_string s)
  with Failure _ -> None

(** Parse bool with default value. Accepts: "true", "false", "1", "0", "yes", "no" *)
let bool ~context ~default s =
  match String.lowercase_ascii s with
  | "true" | "1" | "yes" -> true
  | "false" | "0" | "no" -> false
  | _ ->
      warn ~context ~input:s ~fallback:(string_of_bool default);
      default

(** {1 Environment Variable Parsers} *)

(** Get env var as int with default. *)
let env_int ~var ~default =
  match Sys.getenv_opt var with
  | None -> default
  | Some v -> int ~context:(Printf.sprintf "env:%s" var) ~default v

(** Get env var as float with default. *)
let env_float ~var ~default =
  match Sys.getenv_opt var with
  | None -> default
  | Some v -> float ~context:(Printf.sprintf "env:%s" var) ~default v

(** Get env var as bool with default. *)
let env_bool ~var ~default =
  match Sys.getenv_opt var with
  | None -> default
  | Some v -> bool ~context:(Printf.sprintf "env:%s" var) ~default v

(** {1 JSON Parsing} *)

(** Parse JSON string, return None on failure. *)
let json_of_string_opt s =
  try Some (Yojson.Safe.from_string s)
  with Yojson.Json_error _ -> None

(** Parse JSON string with default fallback. *)
let json_of_string ~context ~default s =
  try Yojson.Safe.from_string s
  with Yojson.Json_error msg ->
    warn ~context ~input:s ~fallback:"(default json)";
    if warn_enabled () then
      Log.Misc.error "JSON error: %s" msg;
    default

(** {1 Exception-Safe Execution} *)

(** Try operation, use fallback on any exception. Logs exception when warn enabled.
    Use for encoding/compression where fallback is always safe. *)
let try_or ~context ~fallback f =
  try f ()
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    if warn_enabled () then
      Log.Misc.error "%s failed: %s, using fallback" context (Printexc.to_string exn);
    fallback ()

(** Try operation, return None on any exception. Logs when warn enabled. *)
let try_opt ~context f =
  try Some (f ())
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    if warn_enabled () then
      Log.Misc.error "%s failed: %s" context (Printexc.to_string exn);
    None
