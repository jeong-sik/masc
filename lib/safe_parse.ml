(** Safe parsing utilities with optional warning logs.

    These functions replace the pattern:
    {[
      try int_of_string s with _ -> default
    ]}

    with centralized, debuggable alternatives that log warnings
    when falling back to defaults. Enable logging with:
    {[
      LLM_MCP_PARSE_WARN=1
    ]}
*)

(** Whether to log parse warnings. Default: false to avoid noise. *)
let warn_enabled () =
  match Sys.getenv_opt "LLM_MCP_PARSE_WARN" with
  | Some "1" | Some "true" | Some "yes" -> true
  | _ -> false

(** Log a parse warning if enabled. *)
let warn ~context ~input ~fallback =
  if warn_enabled () then
    Printf.eprintf "[Parse] %s: failed to parse '%s', using default '%s'\n%!"
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

(** {1 JSON Parsers (Yojson.Safe)} *)

open Yojson.Safe.Util

(** Get JSON member as string with default. *)
let json_string ~context ~default json key =
  try json |> member key |> to_string
  with Type_error _ ->
    warn ~context:(Printf.sprintf "%s.%s" context key) ~input:"<non-string>" ~fallback:default;
    default

(** Get JSON member as string option (no warning). *)
let json_string_opt json key =
  try Some (json |> member key |> to_string)
  with Type_error _ -> None

(** Get JSON member as int with default. *)
let json_int ~context ~default json key =
  try json |> member key |> to_int
  with Type_error _ ->
    warn ~context:(Printf.sprintf "%s.%s" context key)
      ~input:"<non-int>" ~fallback:(string_of_int default);
    default

(** Get JSON member as int option (no warning). *)
let json_int_opt json key =
  try Some (json |> member key |> to_int)
  with Type_error _ -> None

(** Get JSON member as float with default. *)
let json_float ~context ~default json key =
  try json |> member key |> to_float
  with Type_error _ ->
    warn ~context:(Printf.sprintf "%s.%s" context key)
      ~input:"<non-float>" ~fallback:(Printf.sprintf "%.2f" default);
    default

(** Get JSON member as bool with default. *)
let json_bool ~context ~default json key =
  try json |> member key |> to_bool
  with Type_error _ ->
    warn ~context:(Printf.sprintf "%s.%s" context key)
      ~input:"<non-bool>" ~fallback:(string_of_bool default);
    default

(** Get JSON member as list with default empty list. *)
let json_list ~context json key =
  try json |> member key |> to_list
  with Type_error _ ->
    warn ~context:(Printf.sprintf "%s.%s" context key)
      ~input:"<non-list>" ~fallback:"[]";
    []

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
      Printf.eprintf "[Parse] JSON error: %s\n%!" msg;
    default

(** {1 Exception-Safe Execution} *)

(** Try operation, use fallback on any exception. Logs exception when warn enabled.
    Use for encoding/compression where fallback is always safe. *)
let try_or ~context ~fallback f =
  try f ()
  with exn ->
    if warn_enabled () then
      Printf.eprintf "[Safe] %s failed: %s, using fallback\n%!" context (Printexc.to_string exn);
    fallback ()

(** Try operation, return None on any exception. Logs when warn enabled. *)
let try_opt ~context f =
  try Some (f ())
  with exn ->
    if warn_enabled () then
      Printf.eprintf "[Safe] %s failed: %s\n%!" context (Printexc.to_string exn);
    None
