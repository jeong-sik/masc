(** Observability_redact — redact sensitive data for observability fields.

    Truncation + pattern stripping + tool-level deny list.
    Uses [Re] (thread-safe) instead of [Str]. *)

let default_max_len = 200

(** Tools whose input/output must never be previewed.

    This uses substring (infix) matching, not [Tool_access_policy] exact-name
    matching, because redaction must catch tool name variants and prefixed
    aliases (e.g. [mcp__foo_auth_bar]) without enumerating every name. *)
let denied_tool_infixes =
  ["_auth"; "_encryption"; "_credential"; "_secret"]


let sensitive_key_markers =
  [ "token"; "secret"; "password"; "passwd"; "api_key"; "apikey"; "key" ]

let is_sensitive_key key =
  let lower = String.lowercase_ascii key in
  List.exists (fun marker -> String_util.contains_substring lower marker)
    sensitive_key_markers

let is_denied_tool ~tool_name =
  let lower = String.lowercase_ascii tool_name in
  List.exists (fun infix -> String_util.contains_substring lower infix) denied_tool_infixes

(** Minimum length for the generic high-entropy token pattern. *)
let default_min_secret_len = 20

(** Generic high-entropy token pattern — alphanumeric/base64 characters.

    A length gate alone (the previous form) redacts any 20+ char run, including
    ordinary identifiers (keeper names like [keeper-issue_king-agent], task ids,
    commit hashes). The match is therefore re-verified by Shannon entropy in
    {!redact_patterns}: real secrets (API keys, base64 tokens) score
    [>= generic_entropy_threshold]; English-word identifiers score lower and are
    preserved. This is the gitleaks-standard "regex candidate, then entropy
    verification" approach. *)
let generic_secret_re min_len =
  Re.compile (Re.repn (Re.alt [Re.alnum; Re.set "_/+=-"]) min_len None)

(** Shannon entropy in bits/char over a substring. *)
let shannon_entropy (s : string) : float =
  let len = String.length s in
  if len = 0 then 0.0
  else
    let counts = Array.make 256 0 in
    for i = 0 to len - 1 do
      let c = Char.code s.[i] in
      counts.(c) <- counts.(c) + 1
    done;
    let log2 = Stdlib.log 2.0 in
    let flen = float_of_int len in
    Array.fold_left
      (fun acc n ->
        if n = 0 then acc
        else
          let p = float_of_int n /. flen in
          acc -. p *. (Stdlib.log p /. log2))
      0.0 counts

(** Entropy threshold separating real secrets from ordinary identifiers.

    Measured (bits/char): keeper identities score [<= 3.85]
    (e.g. [keeper-issue_king-agent]=3.50, [task-claim-bot-9a8b7c6d]=3.85),
    real secret forms score [>= 4.08] (AWS key=4.08, sk-proj token=4.83,
    github PAT=5.32). [4.0] sits in the clean separation gap. *)
let generic_entropy_threshold = 4.0

(** URL credential pattern — ://user:pass@ *)
let url_credential_re =
  Re.compile (Re.seq [Re.str "://"; Re.rep1 (Re.compl [Re.set "@ "]); Re.char '@'])

(** Prefix-anchored secret patterns. Entropy is irrelevant here — the prefix
    itself identifies the secret family — so these are applied with plain
    [Re.replace_string]. Each prefix literal is anchored at a word boundary
    ([Re.bow]) so a word-internal substring is not mistaken for a key: without
    the anchor, [sk-] matched the substring [sk-1234] inside the task id
    [task-1234] and redacted it to [ta\[REDACTED\]]. [Re.bow]/[eow] are
    zero-width, so [Re.replace_string] preserves the boundary character
    (=, space, quote) automatically. The [sk-] body allows [-] so modern
    [sk-proj-...] keys match in one shot. [AKIA] is anchored at both ends so a
    17-char run is not truncated to its first 16 chars. The generic
    high-entropy matcher is applied separately with entropy gating in
    {!redact_patterns}. *)
let prefix_secret_res () =
  let open Re in
  [ url_credential_re
  ; compile (seq [str "Bearer "; rep1 (compl [set " \t\r\n"])])
  ; compile (seq [bow; str "ghp_"; rep1 alnum])
  ; compile (seq [bow; str "github_pat_"; rep1 (alt [alnum; char '_'])])
  ; compile (seq [bow; str "sk-"; rep1 (alt [alnum; char '-'])])
  ; compile (seq [bow; str "AKIA"; repn alnum 16 (Some 16); eow])
  ]

let redact_patterns ?min_len (s : string) : string =
  let min_len = Option.value min_len ~default:default_min_secret_len in
  let s =
    List.fold_left
      (fun acc re -> Re.replace_string re ~by:"[REDACTED]" acc)
      s (prefix_secret_res ())
  in
  (* Generic high-entropy matcher: redact the run only if it also clears the
     entropy threshold, so ordinary identifiers (keeper names, task ids, commit
     hashes) pass through while real secrets (API keys, base64 tokens) are
     still redacted. *)
  Re.replace (generic_secret_re min_len) s
    ~f:(fun group ->
      let token = Re.Group.get group 0 in
      if shannon_entropy token >= generic_entropy_threshold then "[REDACTED]"
      else token)

let redact_text (s : string) : string =
  redact_patterns s

let truncate ?(max_len = default_max_len) (s : string) : string =
  let s = String.trim s in
  if String.length s <= max_len then s
  else String.sub s 0 max_len ^ "...(truncated)"

(* Blob markers (see [Tool_output.encode_for_oas]) embed a 64-hex sha256
   that the 24+ alnum pattern would otherwise overwrite with [REDACTED],
   destroying the structural fields the dashboard needs to render the marker
   as a "Stored blob" preview. Decode, redact only the user-visible preview
   body, then re-encode so sha256/bytes/mime survive intact. *)
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

let redact_tool_input ~tool_name (input : Yojson.Safe.t) : string option =
  if is_denied_tool ~tool_name then None
  else Some (preview_of_json input)

let redact_tool_output ~tool_name (output : string) : string option =
  if is_denied_tool ~tool_name then None
  else Some (redact_preview output)

let redacted_tool_input_json ~tool_name input =
  if is_denied_tool ~tool_name then None
  else Some (input |> redact_json_value |> preview_json_strings)

let redacted_tool_output_json ~tool_name output =
  if is_denied_tool ~tool_name then None
  else
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
