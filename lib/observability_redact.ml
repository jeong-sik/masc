(** Observability_redact — redact sensitive data for observability fields.

    Truncation + pattern stripping + tool-level deny list.
    Uses [Re] (thread-safe) instead of [Str]. *)

let default_max_len = 200

(** Tools whose input/output must never be previewed.

    This uses substring (infix) matching, not [Tool_access_policy] exact-name
    matching, because redaction must catch tool name variants and prefixed
    aliases (e.g. [mcp__foo_auth_bar]) without enumerating every name. *)
let denied_tool_infixes = [ "_auth"; "_encryption"; "_credential"; "_secret" ]

let contains_substring ~sub s =
  let sub_len = String.length sub in
  let s_len = String.length s in
  if sub_len > s_len
  then false
  else (
    let rec loop i =
      if i > s_len - sub_len
      then false
      else if String.sub s i sub_len = sub
      then true
      else loop (i + 1)
    in
    loop 0)
;;

let sensitive_key_markers =
  [ "token"; "secret"; "password"; "passwd"; "api_key"; "apikey"; "key" ]
;;

let is_sensitive_key key =
  let lower = String.lowercase_ascii key in
  List.exists (fun marker -> contains_substring ~sub:marker lower) sensitive_key_markers
;;

let is_denied_tool ~tool_name =
  let lower = String.lowercase_ascii tool_name in
  List.exists (fun infix -> contains_substring ~sub:infix lower) denied_tool_infixes
;;

(** Sensitive value patterns — matches API keys, tokens, long hex strings.
    24+ contiguous alphanumeric/base64 characters. *)
let sensitive_value_re =
  Re.compile (Re.repn (Re.alt [ Re.alnum; Re.set "_/+=-" ]) 24 None)
;;

(** URL credential pattern — ://user:pass@ *)
let url_credential_re =
  Re.compile (Re.seq [ Re.str "://"; Re.rep1 (Re.compl [ Re.set "@ " ]); Re.char '@' ])
;;

let redact_patterns (s : string) : string =
  let s = Re.replace_string url_credential_re ~by:"://[REDACTED]@" s in
  Re.replace_string sensitive_value_re ~by:"[REDACTED]" s
;;

let truncate ?(max_len = default_max_len) (s : string) : string =
  let s = String.trim s in
  if String.length s <= max_len then s else String.sub s 0 max_len ^ "...(truncated)"
;;

(* Blob sentinels (see [Tool_output.encode_for_oas]) embed a 64-hex sha256
   that the 24+ alnum pattern would otherwise overwrite with [REDACTED],
   destroying the structural fields the dashboard needs to render the marker
   as a "Stored blob" preview. Decode, redact only the user-visible preview
   body, then re-encode so sha256/bytes/mime survive intact. *)
let redact_preview ?(max_len = default_max_len) (s : string) : string =
  if Tool_output.is_sentinel s
  then (
    match Tool_output.decode_from_oas s with
    | Tool_output.Stored { sha256; bytes; preview; mime } ->
      let preview = preview |> truncate ~max_len |> redact_patterns in
      Tool_output.encode_for_oas (Tool_output.Stored { sha256; bytes; preview; mime })
    | Tool_output.Inline _ -> s |> truncate ~max_len |> redact_patterns)
  else s |> truncate ~max_len |> redact_patterns
;;

let rec preview_json_strings ?(max_len = default_max_len) (json : Yojson.Safe.t)
  : Yojson.Safe.t
  =
  match json with
  | `String s -> `String (redact_preview ~max_len s)
  | `Assoc fields ->
    `Assoc (List.map (fun (k, v) -> k, preview_json_strings ~max_len v) fields)
  | `List items -> `List (List.map (preview_json_strings ~max_len) items)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _) as j -> j
;;

let rec redact_json_value = function
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (key, value) ->
            if is_sensitive_key key
            then key, `String "[REDACTED]"
            else key, redact_json_value value)
         fields)
  | `List items -> `List (List.map redact_json_value items)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as json -> json
;;

let preview_of_json ?(max_len = default_max_len) (json : Yojson.Safe.t) =
  Yojson.Safe.to_string (redact_json_value json) |> redact_preview ~max_len
;;

let redact_tool_input ~tool_name (input : Yojson.Safe.t) : string option =
  if is_denied_tool ~tool_name then None else Some (preview_of_json input)
;;

let redact_tool_output ~tool_name (output : string) : string option =
  if is_denied_tool ~tool_name then None else Some (redact_preview output)
;;

let build_tool_call_trace_json
      ?tool_use_id
      ~tool_name
      ~input
      ~(output : string option)
      ~(is_error : bool option)
      ()
  : Yojson.Safe.t
  =
  let input_preview = redact_tool_input ~tool_name input in
  let output_preview =
    match output with
    | Some o -> redact_tool_output ~tool_name o
    | None -> None
  in
  let base =
    [ "tool_name", `String tool_name
    ; "kind", `String "tool_use"
    ; "tool_input_preview", Json_util.string_opt_to_json input_preview
    ; "tool_args_preview", Json_util.string_opt_to_json input_preview
    ; "tool_output_preview", Json_util.string_opt_to_json output_preview
    ; "is_error", Json_util.bool_opt_to_json is_error
    ]
  in
  let with_id =
    match tool_use_id with
    | Some id -> ("tool_use_id", `String id) :: base
    | None -> base
  in
  `Assoc with_id
;;

let summarize_tool_call_traces (traces : Yojson.Safe.t list)
  : string option * string option * string option
  =
  let open Yojson.Safe.Util in
  let first_non_null key =
    List.find_map
      (fun json ->
         match member key json with
         | `String s when String.trim s <> "" -> Some (String.trim s)
         | _ -> None)
      traces
  in
  let tool_input_preview = first_non_null "tool_input_preview" in
  let tool_args_preview = first_non_null "tool_args_preview" in
  let tool_output_preview =
    List.rev traces
    |> List.find_map (fun json ->
      match member "tool_output_preview" json with
      | `String s when String.trim s <> "" -> Some (String.trim s)
      | _ -> None)
  in
  tool_input_preview, tool_args_preview, tool_output_preview
;;
