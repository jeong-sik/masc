(** Observability_redact — redact sensitive data for observability fields.

    Truncation plus structural secret redaction. Every tool call remains
    observable; tool names never decide whether evidence exists.
    Uses [Re] (thread-safe) instead of [Str]. *)

let default_max_len = 200

let sensitive_keys =
  [ "access_token"
  ; "api_key"
  ; "api_token"
  ; "apikey"
  ; "authorization"
  ; "client_secret"
  ; "credential"
  ; "credentials"
  ; "password"
  ; "passwd"
  ; "private_key"
  ; "refresh_token"
  ; "secret"
  ; "token"
  ]

let is_sensitive_key key =
  let lower = String.lowercase_ascii key in
  List.exists (String.equal lower) sensitive_keys

(** URL credential pattern — ://user:pass@ *)
let url_credential_re =
  Re.compile (Re.seq [Re.str "://"; Re.rep1 (Re.compl [Re.set "@ "]); Re.char '@'])

(** Common secret-bearing value patterns — structural prefixes only.

    Each pattern identifies a secret by its *structure* (a known prefix family
    or the [://user:pass@] URL shape), not by a length heuristic. The former
    generic "20+ alphanumeric run" matcher was removed: it classified ordinary
    identifiers (keeper names, commit hashes, task ids) as secrets by length
    alone, erasing them from observability fields, while every real prefix it
    caught is already matched here in one shot (e.g. [sk-proj-...] via the
    [sk-] body below). Known secret *values* loaded from the environment remain
    redacted exactly by {!Keeper_secret_redaction}, which does not rely on this
    heuristic.

    Specific prefix regexes are hoisted to module level so they are compiled
    once at init, not rebuilt on every [redact_text] call. [Re] is thread-safe
    (see file header), so sharing compiled regexes across fibers/domains is
    safe — [url_credential_re] already does this. *)
let bearer_re =
  Re.compile (Re.seq [Re.str "Bearer "; Re.rep1 (Re.compl [Re.set " \t\r\n"])])

let sk_re =
  Re.compile (Re.seq [Re.bow; Re.str "sk-"; Re.rep1 (Re.alt [Re.alnum; Re.char '-'])])

let awsakia_re =
  Re.compile (Re.seq [Re.bow; Re.str "AKIA"; Re.repn Re.alnum 16 (Some 16); Re.eow])

let pem_marker_pairs =
  [ "-----BEGIN PRIVATE KEY-----", "-----END PRIVATE KEY-----"
  ; "-----BEGIN RSA PRIVATE KEY-----", "-----END RSA PRIVATE KEY-----"
  ]

let find_substring_from haystack needle start =
  let needle_len = String.length needle in
  if needle_len = 0
  then Some start
  else (
    let haystack_len = String.length haystack in
    let max_start = haystack_len - needle_len in
    let rec loop idx =
      if idx > max_start
      then None
      else if String.sub haystack idx needle_len = needle
      then Some idx
      else loop (idx + 1)
    in
    if start > max_start then None else loop start)

let redact_between_markers ~begin_marker ~end_marker s =
  let begin_len = String.length begin_marker in
  let end_len = String.length end_marker in
  let s_len = String.length s in
  let buf = Buffer.create s_len in
  let rec loop pos =
    match find_substring_from s begin_marker pos with
    | None ->
        Buffer.add_substring buf s pos (s_len - pos);
        Buffer.contents buf
    | Some start ->
        Buffer.add_substring buf s pos (start - pos);
        Buffer.add_string buf "[REDACTED]";
        let after_begin = start + begin_len in
        (match find_substring_from s end_marker after_begin with
         | None -> Buffer.contents buf
         | Some stop -> loop (stop + end_len))
  in
  loop 0

let redact_pem_blocks s =
  List.fold_left
    (fun acc (begin_marker, end_marker) ->
       redact_between_markers ~begin_marker ~end_marker acc)
    s
    pem_marker_pairs

(** Common secret-bearing value patterns. Specific prefixes are listed before
    any generic matcher so short, well-known tokens are not missed when they
    are embedded inside larger strings.

    Each prefix literal is anchored at a word boundary ([Re.bow]) so a
    word-internal substring is not mistaken for a key. Without the anchor, the
    [sk-] pattern matched the substring [sk-1234] inside the task id
    [task-1234] and redacted it to [ta\[REDACTED\]], destroying diagnostic
    identifiers in error previews (and any other observability field carrying a
    [task-XXXX] reference). [bow] rejects that match because [sk-] is preceded
    by the identifier char 'a'. [Re.bow]/[eow] are zero-width assertions, so
    [Re.replace_string] preserves the boundary character (=, space, quote)
    automatically. The [sk-] body allows [-] so modern [sk-proj-...] keys are
    matched in one shot instead of leaving a [-abc...] tail. [AKIA] is anchored
    at both ends so a 17-char run is not truncated to its first 16 chars. *)
let secret_res () =
  [ url_credential_re
  ; bearer_re
  ; sk_re
  ; awsakia_re
  ]

let redact_patterns (s : string) : string =
  List.fold_left
    (fun acc re -> Re.replace_string re ~by:"[REDACTED]" acc)
    (redact_pem_blocks s)
    (secret_res ())

let redact_text (s : string) : string =
  redact_patterns s

let truncate ?(max_len = default_max_len) (s : string) : string =
  let s = String.trim s in
  if String.length s <= max_len then s
  else String.sub s 0 max_len ^ "...(truncated)"

(* Blob markers (see [Tool_output.encode_for_oas]) carry structural fields
   (sha256/bytes/mime) the dashboard needs to render the marker as a "Stored
   blob" preview. Decode, redact only the user-visible preview body, then
   re-encode so those fields survive intact. The prefix matchers do not match a
   64-hex sha256, but scoping redaction to the preview body keeps the marker
   structure correct regardless of which patterns run. *)
let redact_preview ?(max_len = default_max_len) (s : string) : string =
  if Tool_output.is_marker s then
    match Tool_output.decode_from_oas s with
    | Tool_output.Stored { sha256; bytes; preview; mime } ->
        let preview = preview |> truncate ~max_len |> redact_patterns in
        Tool_output.encode_for_oas
          (Tool_output.Stored { sha256; bytes; preview; mime })
    | Tool_output.Inline _ ->
        s |> truncate ~max_len |> redact_patterns
  else s |> truncate ~max_len |> redact_patterns

let rec preview_json_strings ?(max_len = default_max_len) (json : Yojson.Safe.t)
    : Yojson.Safe.t =
  match json with
  | `String s -> `String (redact_preview ~max_len s)
  | `Assoc fields ->
      `Assoc
        (List.map (fun (k, v) -> (k, preview_json_strings ~max_len v)) fields)
  | `List items -> `List (List.map (preview_json_strings ~max_len) items)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _) as j -> j

let rec redact_json_strings = function
  | `String s -> `String (redact_text s)
  | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
             if is_sensitive_key key then (key, `String "[REDACTED]")
             else (key, redact_json_strings value))
           fields)
  | `List items -> `List (List.map redact_json_strings items)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _) as json -> json

let rec redact_json_value = function
  | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
             if is_sensitive_key key then (key, `String "[REDACTED]")
             else (key, redact_json_value value))
           fields)
  | `List items -> `List (List.map redact_json_value items)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as json ->
      json

let preview_of_json ?(max_len = default_max_len) (json : Yojson.Safe.t) =
  Yojson.Safe.to_string (redact_json_value json) |> redact_preview ~max_len

let redact_tool_input ~tool_name:_ (input : Yojson.Safe.t) : string option =
  Some (preview_of_json input)

let redact_tool_output ~tool_name:_ (output : string) : string option =
  Some (redact_preview output)

let redacted_tool_input_json ~tool_name:_ input =
  Some (input |> redact_json_value |> preview_json_strings)

let redacted_tool_output_json ~tool_name:_ output =
  let redacted =
    try Yojson.Safe.from_string output |> redact_json_value |> preview_json_strings
    with
    | Yojson.Json_error _ -> `String (redact_preview output)
  in
  Some redacted

let build_tool_call_trace_json ?tool_use_id ~tool_name ~input
    ~(output : string option) ~(is_error : bool option) () : Yojson.Safe.t =
  let input_preview = redact_tool_input ~tool_name input in
  let output_preview =
    match output with
    | Some o -> redact_tool_output ~tool_name o
    | None -> None
  in
  let base =
    [
      ("tool_name", `String tool_name);
      ("kind", `String "tool_use");
      ("tool_input_preview", Json_util.string_opt_to_json input_preview);
      ("tool_args_preview", Json_util.string_opt_to_json input_preview);
      ("tool_output_preview", Json_util.string_opt_to_json output_preview);
      ("is_error", Json_util.bool_opt_to_json is_error);
    ]
  in
  let with_id =
    match tool_use_id with
    | Some id -> ("tool_use_id", `String id) :: base
    | None -> base
  in
  `Assoc with_id

let summarize_tool_call_traces (traces : Yojson.Safe.t list) :
    string option * string option * string option =
  let first_non_null key =
    List.find_map
      (fun json ->
        match Json_util.assoc_member_opt key json with
        | Some (`String s) ->
            let trimmed = String.trim s in
            if trimmed <> "" then Some trimmed else None
        | _ -> None)
      traces
  in
  let tool_input_preview = first_non_null "tool_input_preview" in
  let tool_args_preview = first_non_null "tool_args_preview" in
  let tool_output_preview =
    List.rev traces
    |> List.find_map
         (fun json ->
           match Json_util.assoc_member_opt "tool_output_preview" json with
           | Some (`String s) ->
               let trimmed = String.trim s in
               if trimmed <> "" then Some trimmed else None
           | _ -> None)
  in
  (tool_input_preview, tool_args_preview, tool_output_preview)
