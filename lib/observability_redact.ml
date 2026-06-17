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

(** Tunable configuration for the generic secret matcher. *)
type redact_config =
  { generic_min_len : int
  ; generic_max_token_len : int
  ; generic_entropy_threshold : float
  ; generic_lower_entropy_threshold : float
  ; generic_longer_min_len : int
  ; generic_min_classes_for_low_entropy : int
  ; max_input_len : int
  }

let default_min_secret_len = 20
let default_max_generic_token_len = 1024
let default_max_redact_text_len = 100_000

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
    github PAT=5.32). [4.0] sits in the clean separation gap.

    The sample size is small, so these values are configurable via
    {!redact_config}; the defaults are deliberately conservative. *)
let default_entropy_threshold = 4.0

(** Lower entropy floor for the secondary multi-signal gate.

    A token whose entropy falls between [generic_lower_entropy_threshold] and
    [generic_entropy_threshold] is still considered secret IF it is long
    enough and diverse enough in character classes. This catches secrets whose
    entropy is depressed by a skewed symbol distribution while keeping ordinary
    identifiers (UUIDs, commit hashes, keeper names) on the safe side of the
    gate.

    The default 3.5 bits/char is 0.5 bits/char below the primary threshold —
    below every measured keeper/task identity in the regression suite. It is
    paired with [generic_longer_min_len=30] and
    [generic_min_classes_for_low_entropy=3] so a token needs additional
    fundamental signals, not just entropy near the gap, to cross into
    redaction. *)
let default_lower_entropy_threshold = 3.5

let default_redact_config =
  { generic_min_len = default_min_secret_len
  ; generic_max_token_len = default_max_generic_token_len
  ; generic_entropy_threshold = default_entropy_threshold
  ; generic_lower_entropy_threshold = default_lower_entropy_threshold
  ; generic_longer_min_len = 30
  ; generic_min_classes_for_low_entropy = 3
  ; max_input_len = default_max_redact_text_len
  }

(** Generic high-entropy token pattern — alphanumeric/base64 characters.

    A length gate alone (the previous form) redacts any 20+ char run, including
    ordinary identifiers (keeper names like [keeper-issue_king-agent], task ids,
    commit hashes). The match is therefore re-verified by a multi-signal scorer
    in {!redact_patterns}: real secrets (API keys, base64 tokens) score high on
    entropy, length, and character-class diversity; English-word identifiers
    and structured ids are rejected by the same signals plus a small dictionary
    blocklist. This is the gitleaks-standard "regex candidate, then entropy
    verification" approach, hardened with extra signals to reduce false
    negatives. *)
let generic_secret_re min_len =
  Re.compile (Re.repn (Re.alt [Re.alnum; Re.set "_/+=-"]) min_len None)

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
    high-entropy matcher is applied separately with multi-signal gating in
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

(** Common English/identifier words that appear in keeper names, task ids, and
    diagnostics but are not themselves secrets. Used only on whole alpha
    segments of a candidate token so a secret that merely contains one of these
    words is not accidentally preserved. *)
let dictionary_blocklist =
  [ "keeper"; "task"; "agent"; "bot"; "heartbeat"; "issue"; "claim"
  ; "diagnostic"; "judge"; "review"; "worker"; "lifecycle"; "fast"
  ; "test"; "debug"; "log"; "tmp"; "temp"; "user"; "admin"; "root"
  ; "data"; "file"; "path"; "config"; "service"; "app"; "prod"; "dev"
  ; "staging"; "local"; "server"; "client"; "master"; "main"; "branch"
  ; "build"; "run"; "unit"; "integration"; "error"; "warn"; "info"
  ; "trace"; "system"; "process"; "thread"; "queue"; "event"; "metric"
  ; "dashboard"; "workspace"; "project"; "org"; "group"; "team"
  ]

let lower_blocklist = List.map String.lowercase_ascii dictionary_blocklist

let is_blocklisted_word w = List.mem (String.lowercase_ascii w) lower_blocklist

(** Extract contiguous alphabetic segments from a token. *)
let alpha_segments (s : string) : string list =
  let len = String.length s in
  let rec flush i start acc =
    if start < i then String.sub s start (i - start) :: acc else acc
  in
  let rec aux i start acc =
    if i = len then List.rev (flush i start acc)
    else
      let c = s.[i] in
      if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') then
        aux (i + 1) start acc
      else
        aux (i + 1) (i + 1) (flush i start acc)
  in
  aux 0 0 []

(** A token is "dictionary-like" when every alphabetic segment in it is a
    common word. This preserves identifiers such as
    [task_claim_bot_heartbeat_keeper_agent_12345] even if their entropy is
    above the primary threshold. *)
let is_dictionary_like (token : string) : bool =
  match alpha_segments token with
  | [] -> false
  | segments -> List.for_all is_blocklisted_word segments

let uuid_like_re =
  Re.compile
    (Re.seq
       [ Re.repn Re.xdigit 8 (Some 8)
       ; Re.char '-'
       ; Re.repn Re.xdigit 4 (Some 4)
       ; Re.char '-'
       ; Re.repn Re.xdigit 4 (Some 4)
       ; Re.char '-'
       ; Re.repn Re.xdigit 4 (Some 4)
       ; Re.char '-'
       ; Re.repn Re.xdigit 12 (Some 12)
       ])

let is_uuid_like (token : string) : bool = Re.execp uuid_like_re token

let is_hex_string (s : string) : bool =
  String.for_all
    (fun c ->
       (c >= '0' && c <= '9')
       || (c >= 'a' && c <= 'f')
       || (c >= 'A' && c <= 'F'))
    s

(** A token is treated as an obvious non-secret identifier if it is a UUID,
    a commit-hash-like hex run, or a concatenation of common dictionary words.
    These patterns dominate the false-positive cases without relying on a
    single entropy number. *)
let is_obvious_identifier (token : string) : bool =
  if is_dictionary_like token then true
  else if is_uuid_like token then true
  else
    let stripped =
      String.fold_left
        (fun acc c -> if c = '-' || c = '_' then acc else acc ^ String.make 1 c)
        "" token
    in
    String.length stripped > 0
    && is_hex_string stripped
    && (String.length stripped = 32 || String.length stripped = 40)

let char_class_count (s : string) : int =
  let lower = ref false in
  let upper = ref false in
  let digit = ref false in
  let other = ref false in
  String.iter
    (fun c ->
       if c >= 'a' && c <= 'z' then lower := true
       else if c >= 'A' && c <= 'Z' then upper := true
       else if c >= '0' && c <= '9' then digit := true
       else other := true)
    s;
  (if !lower then 1 else 0)
  + (if !upper then 1 else 0)
  + (if !digit then 1 else 0)
  + (if !other then 1 else 0)

(** Multi-signal secret scorer.

    A candidate token is redacted only when several independent signals agree:
    - minimum length ([generic_min_len])
    - either entropy above the primary threshold, OR entropy in the fuzzy band
      below the threshold but with compensating length and character-class
      diversity
    - not an obvious identifier (UUID, commit hash, dictionary-like run)

    The entropy threshold is the headline separator, while length and diversity
    act as a safety net for secrets whose entropy is artificially low because
    of a skewed character distribution. The blocklist/identifier checks prevent
    that safety net from re-introducing false positives on keeper names and
    diagnostic ids. *)
let is_secret_token config (token : string) : bool =
  let len = String.length token in
  if len < config.generic_min_len then false
  else if is_obvious_identifier token then false
  else
    let sample =
      if len > config.generic_max_token_len then
        String.sub token 0 config.generic_max_token_len
      else token
    in
    let entropy = shannon_entropy sample in
    entropy >= config.generic_entropy_threshold
    || (entropy >= config.generic_lower_entropy_threshold
        && len >= config.generic_longer_min_len
        && char_class_count token >= config.generic_min_classes_for_low_entropy)

let redact_patterns ?config (s : string) : string =
  let config = Option.value config ~default:default_redact_config in
  let s =
    List.fold_left
      (fun acc re -> Re.replace_string re ~by:"[REDACTED]" acc)
      s (prefix_secret_res ())
  in
  (* Generic high-entropy matcher: redact the run only if the multi-signal
     scorer classifies it as a secret, so ordinary identifiers (keeper names,
     task ids, commit hashes, UUIDs) pass through while real secrets (API keys,
     base64 tokens) are still redacted. *)
  Re.replace (generic_secret_re config.generic_min_len) s
    ~f:(fun group ->
      let token = Re.Group.get group 0 in
      if is_secret_token config token then "[REDACTED]" else token)

(** [redact_text] bounds computation: inputs longer than
    [config.max_input_len] are redacted only on the prefix and the remainder
    is replaced with [...(truncated)]. This prevents runaway regex/entropy work
    on unexpectedly large payloads while still redacting the visible head. *)
let redact_text ?config (s : string) : string =
  let config = Option.value config ~default:default_redact_config in
  let len = String.length s in
  if len <= config.max_input_len then redact_patterns ~config s
  else
    let prefix = String.sub s 0 config.max_input_len in
    redact_patterns ~config prefix ^ "...(truncated)"

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
