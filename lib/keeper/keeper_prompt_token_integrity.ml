(** Keeper_prompt_token_integrity — scan rendered prompts and continuity
    summaries for keeper_*/masc_* tokens and verify each one resolves through
    the policy tool-name chain.

    P0-3: Rendered Prompt Token Scanner. Emits the
    [masc_keeper_prompt_unknown_tool_tokens_total] CI metric for every token
    that does not resolve via [Keeper_tool_resolution.resolve]. *)

(* ── Types ────────────────────────────────────────────────────────── *)

type source =
  | System_prompt
  | User_message
  | Continuity

type token_kind =
  | Keeper
  | Masc

let source_to_string = function
  | System_prompt -> "system_prompt"
  | User_message -> "user_message"
  | Continuity -> "continuity"

let kind_to_string = function
  | Keeper -> "keeper"
  | Masc -> "masc"

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
  if pos + 7 <= len
     && text.[pos] = 'k'
     && text.[pos + 1] = 'e'
     && text.[pos + 2] = 'e'
     && text.[pos + 3] = 'p'
     && text.[pos + 4] = 'e'
     && text.[pos + 5] = 'r'
     && text.[pos + 6] = '_'
  then Some Keeper
  else if
    pos + 5 <= len
    && text.[pos] = 'm'
    && text.[pos + 1] = 'a'
    && text.[pos + 2] = 's'
    && text.[pos + 3] = 'c'
    && text.[pos + 4] = '_'
  then Some Masc
  else None

let is_token_start pos text = pos = 0 || not (is_tool_token_char text.[pos - 1])

(** Find all keeper_*/masc_* tokens in [text]. Each token is returned as
    [(kind, raw_name, position)]. The scan is linear in the length of the
    input. *)
let find_tokens text : (token_kind * string) list =
  let len = String.length text in
  let tokens = ref [] in
  let i = ref 0 in
  while !i < len do
    match token_kind_at !i text len with
    | Some kind when is_token_start !i text ->
        let prefix_len =
          match kind with
          | Keeper -> 7
          | Masc -> 5
        in
        let j = ref (!i + prefix_len) in
        while !j < len && is_tool_token_char text.[!j] do
          incr j
        done;
        let name = String.sub text !i (!j - !i) in
        tokens := (kind, name) :: !tokens;
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
  |> dedup_tokens
  |> List.filter_map (verify_token ~keeper_name ~source)
  |> dedup_strings

let scan_rendered_prompt
      ~keeper_name
      ~system_prompt
      ~user_message
      ~continuity_summary =
  let system_unknowns = scan_text ~keeper_name ~source:System_prompt system_prompt in
  let user_unknowns = scan_text ~keeper_name ~source:User_message user_message in
  let continuity_unknowns =
    scan_text ~keeper_name ~source:Continuity continuity_summary
  in
  system_unknowns @ user_unknowns @ continuity_unknowns |> dedup_strings
