(** Keeper_prompt_token_integrity — scan the instruction-owned system prompt
    for keeper_*/masc_* tokens and verify each one resolves through the policy
    tool-name chain.

    P0-3: Rendered Prompt Token Scanner. Emits the
    [masc_keeper_prompt_unknown_tool_tokens_total] CI metric for every token
    that does not resolve via [Keeper_tool_resolution.resolve]. *)

(* ── Types ────────────────────────────────────────────────────────── *)

type source = System_prompt

type token_kind =
  | Keeper
  | Masc

let source_to_string System_prompt = "system_prompt"

let kind_to_string = function
  | Keeper -> "keeper"
  | Masc -> "masc"

let keeper_prefix = "keeper_"
let masc_prefix = "masc_"
let keeper_prefix_len = String.length keeper_prefix
let masc_prefix_len = String.length masc_prefix

(* ── Token extraction ─────────────────────────────────────────────── *)

let is_tool_token_char = function
  | 'A' .. 'Z'
  | 'a' .. 'z'
  | '0' .. '9'
  | '_'
  | '-'
  | '*' -> true
  | _ -> false

let token_kind_at pos text len :
    token_kind option =
  let lc offset = Char.lowercase_ascii text.[pos + offset] in
  if pos + keeper_prefix_len <= len
     && lc 0 = 'k'
     && lc 1 = 'e'
     && lc 2 = 'e'
     && lc 3 = 'p'
     && lc 4 = 'e'
     && lc 5 = 'r'
     && lc 6 = '_'
  then Some Keeper
  else if
    pos + masc_prefix_len <= len
    && lc 0 = 'm'
    && lc 1 = 'a'
    && lc 2 = 's'
    && lc 3 = 'c'
    && lc 4 = '_'
  then Some Masc
  else None

let is_token_start pos text = pos = 0 || not (is_tool_token_char text.[pos - 1])

(* 도구 토큰은 소문자(masc_board_list, keeper_memory_search)이고 환경변수는
   대문자(MASC_BASE_PATH)다. 알파벳이 하나도 소문자가 아니면 env 변수로 보고
   도구 토큰 판정에서 제외한다 — masc_/keeper_ 접두 휴리스틱이 도구가 아닌
   식별자를 오탐하지 않게 한다. *)
let is_env_var_shaped name =
  let has_lower = ref false in
  String.iter (fun c -> if c >= 'a' && c <= 'z' then has_lower := true) name;
  not !has_lower

let is_wildcard_reference name =
  String.contains name '*'

(** Find all keeper_*/masc_* tokens in [text]. Each token is returned as
    [(kind, raw_name, start, end_excl)]. The scan is linear in the length of
    the input and is shared by both verification and sanitization so the two
    passes cannot drift on prefix/boundary semantics. *)
let find_tokens text : (token_kind * string * int * int) list =
  let len = String.length text in
  let tokens = ref [] in
  let i = ref 0 in
  while !i < len do
    match token_kind_at !i text len with
    | Some kind when is_token_start !i text ->
        let prefix_len =
          match kind with
          | Keeper -> keeper_prefix_len
          | Masc -> masc_prefix_len
        in
        let j = ref (!i + prefix_len) in
        while !j < len && is_tool_token_char text.[!j] do
          incr j
        done;
        let name = String.sub text !i (!j - !i) in
        tokens := (kind, name, !i, !j) :: !tokens;
        i := !j
    | _ -> incr i
  done;
  List.rev !tokens

let dedup_strings xs = List.sort_uniq String.compare xs

(** Deduplicate tokens by [(kind, normalized name)], preserving the first
    occurrence's original spelling for logging. *)
let dedup_tokens tokens =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun (kind, name) ->
       let key = (kind, String.lowercase_ascii name) in
       if Hashtbl.mem seen key then false
       else (Hashtbl.add seen key (); true))
    tokens

(* ── Verification ─────────────────────────────────────────────────── *)

let verify_token ~keeper_name ~source (kind, name) : string option =
  (* All-uppercase masc_/keeper_ tokens are env vars (MASC_BASE_PATH, etc.),
     not tool names. Names with wildcard suffixes describe a category in prose,
     not a concrete callable tool. *)
  if is_env_var_shaped name || is_wildcard_reference name then None
  else
    let normalized = String.lowercase_ascii name in
    match Keeper_tool_resolution.resolve normalized with
  | Keeper_tool_resolution.Resolved _ | Keeper_tool_resolution.Alias_to _ ->
      None
  | Keeper_tool_resolution.Unknown _ ->
      Otel_metric_store.inc_counter
        (Keeper_metrics.to_string PromptUnknownToolTokens)
        ~labels:
          [ ("keeper", keeper_name)
          ; ("source", source_to_string source)
          ; ("kind", kind_to_string kind)
          ]
        ();
      Log.Keeper.warn
        "keeper_prompt_token_integrity: unknown %s token %S in %s for keeper %s"
        (kind_to_string kind)
        name
        (source_to_string source)
        keeper_name;
      Some normalized

let scan_text ~keeper_name ~source text : string list =
  find_tokens text
  |> List.map (fun (kind, name, _, _) -> kind, name)
  |> dedup_tokens
  |> List.filter_map (verify_token ~keeper_name ~source)
  |> dedup_strings

let scan_instruction_surfaces
      ~keeper_name
      ~system_prompt =
  scan_text ~keeper_name ~source:System_prompt system_prompt

(* ── Registry-driven sanitization ─────────────────────────────────── *)

let stale_tool_token_placeholder = "<stale_tool_token>"

(** Sanitize keeper_*/masc_* tokens that do not resolve to a live tool, driven
    by [Keeper_tool_resolution] (the same source of truth the scanner uses).

    This is a presentation-layer band-aid for stale tool names that have
    already leaked into instruction-owned prompt text. It is the SOLE prompt
    sanitization pass: the legacy hardcoded
    [Keeper_unified_prompt.sanitize_retired_tool_names] retired-prefix list
    (which also deleted standalone words like "Grep"/"Bash" and mangled
    prompt prose — 38-bug campaign #6) was removed. This pass asks the
    registry: any lowercase masc_/keeper_ token that resolves is kept; one
    that does not (a removed/renamed tool, or a hallucinated name frozen in
    prompt material) is replaced with [stale_tool_token_placeholder] so
    the model never sees it as a callable tool while the surrounding
    sentence stays grammatically intact. Plain capitalized words are never
    touched; hallucinated calls to non-existent tools are rejected at the
    tool-dispatch boundary with a typed error.

    Env-var-shaped tokens (all-uppercase, e.g. MASC_BASE_PATH) are kept —
    they are not tool invocations and stripping them would mangle legitimate
    configuration prose. A resolved alias is also kept.

    When [~keeper_name] is provided, every replacement emits a counter on
    [masc_keeper_prompt_token_stripped_total] and a warning log so the
    producer-side alarm is not lost. *)
let strip_unresolved_tool_tokens ?keeper_name text : string =
  let tokens = find_tokens text in
  let len = String.length text in
  let buf = Buffer.create len in
  let pos = ref 0 in
  List.iter
    (fun (kind, name, start, end_excl) ->
       Buffer.add_substring buf text !pos (start - !pos);
       let keep =
         is_env_var_shaped name
         || is_wildcard_reference name
         ||
         match Keeper_tool_resolution.resolve (String.lowercase_ascii name) with
         | Keeper_tool_resolution.Resolved _ | Keeper_tool_resolution.Alias_to _ ->
             true
         | Keeper_tool_resolution.Unknown _ -> false
       in
       if keep then
         Buffer.add_substring buf text start (end_excl - start)
       else (
         (match keeper_name with
          | Some keeper ->
              Otel_metric_store.inc_counter
                (Keeper_metrics.to_string PromptTokenStripped)
                ~labels:
                  [ ("keeper", keeper)
                  ; ("kind", kind_to_string kind)
                  ; ("tool", String.lowercase_ascii name)
                  ]
                ();
              Log.Keeper.warn
                "keeper_prompt_token_integrity: stripped %s token %S from prompt for keeper %s"
                (kind_to_string kind)
                name
                keeper
          | None -> ());
         Buffer.add_string buf stale_tool_token_placeholder);
       pos := end_excl)
    tokens;
  Buffer.add_substring buf text !pos (len - !pos);
  Buffer.contents buf
