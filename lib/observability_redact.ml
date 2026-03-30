(** Observability_redact — redact sensitive data for observability fields.

    Truncation + pattern stripping + tool-level deny list.
    Uses [Re] (thread-safe) instead of [Str]. *)

let default_max_len = 200

(** Tools whose input/output must never be previewed. *)
let denied_tool_infixes =
  ["_auth"; "_encryption"; "_credential"; "_secret"]

let contains_substring ~sub s =
  let sub_len = String.length sub in
  let s_len = String.length s in
  if sub_len > s_len then false
  else
    let rec loop i =
      if i > s_len - sub_len then false
      else if String.sub s i sub_len = sub then true
      else loop (i + 1)
    in
    loop 0

let is_denied_tool ~tool_name =
  let lower = String.lowercase_ascii tool_name in
  List.exists (fun infix -> contains_substring ~sub:infix lower) denied_tool_infixes

(** Sensitive value patterns — matches API keys, tokens, long hex strings.
    24+ contiguous alphanumeric/base64 characters. *)
let sensitive_value_re =
  Re.compile (Re.repn (Re.alt [Re.alnum; Re.set "_/+=-"]) 24 None)

(** URL credential pattern — ://user:pass@ *)
let url_credential_re =
  Re.compile (Re.seq [Re.str "://"; Re.rep1 (Re.compl [Re.set "@ "]); Re.char '@'])

let redact_patterns (s : string) : string =
  let s = Re.replace_string url_credential_re ~by:"://[REDACTED]@" s in
  Re.replace_string sensitive_value_re ~by:"[REDACTED]" s

let truncate ?(max_len = default_max_len) (s : string) : string =
  let s = String.trim s in
  if String.length s <= max_len then s
  else String.sub s 0 max_len ^ "...(truncated)"

let redact_preview ?(max_len = default_max_len) (s : string) : string =
  s |> truncate ~max_len |> redact_patterns

let redact_tool_input ~tool_name (input : Yojson.Safe.t) : string option =
  if is_denied_tool ~tool_name then None
  else
    let raw = Yojson.Safe.to_string input in
    Some (redact_preview raw)

let redact_tool_output ~tool_name (output : string) : string option =
  if is_denied_tool ~tool_name then None
  else Some (redact_preview output)
