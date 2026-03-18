(** trpg_dm_intent.ml — DM Intent Extraction (keyword + LLM hybrid).

    Extracts DM's narrative intent from their action text.
    Supports three modes via MASC_TRPG_DM_INTENT_MODE:
    - keyword: Pure keyword matching, zero latency
    - llm: LLM structured classification via Llm_orchestration cascade
    - hybrid (default): LLM with keyword fallback on failure

    @since 2.70.0 *)

type intent_category =
  | Combat_setup
  | Social_encounter
  | Puzzle_challenge
  | Exploration
  | Rest_downtime
  | Plot_reveal
  | Tension_building
  | Unknown
[@@deriving show, eq]

type dm_intent = {
  primary : intent_category;
  secondary : intent_category option;
  confidence : float;
  keywords_matched : string list;
  mode : string;
  provenance : string;
}

(* ── Match Mode ─────────────────────────────────────────────────────── *)

type match_mode = Keyword | Llm | Hybrid

let get_match_mode () : match_mode =
  match Sys.getenv_opt "MASC_TRPG_DM_INTENT_MODE" with
  | Some "llm" -> Llm
  | Some "keyword" -> Keyword
  | _ -> Hybrid

let match_mode_to_string = function
  | Keyword -> "keyword"
  | Llm -> "llm"
  | Hybrid -> "hybrid"

type intent_provenance =
  | Judgment
  | Derived
  | Fallback

let intent_provenance_to_string = function
  | Judgment -> "judgment"
  | Derived -> "derived"
  | Fallback -> "fallback"

let make_intent ~mode ~provenance ~primary ~secondary ~confidence ~keywords_matched =
  {
    primary;
    secondary;
    confidence;
    keywords_matched;
    mode = match_mode_to_string mode;
    provenance = intent_provenance_to_string provenance;
  }

(* ── Keyword tables ─────────────────────────────────────────────────── *)

let keyword_table : (intent_category * string list) list =
  [
    ( Combat_setup,
      [
        "attack"; "sword"; "weapon"; "monster"; "creature"; "fight"; "battle";
        "initiative"; "charge"; "ambush"; "hostile"; "threat"; "claws"; "fangs";
        "slash"; "strike"; "arrows"; "shield"; "armor"; "danger";
      ] );
    ( Social_encounter,
      [
        "speak"; "says"; "ask"; "tell"; "merchant"; "innkeeper"; "villager";
        "negotiate"; "persuade"; "convince"; "greet"; "welcome"; "tavern";
        "conversation"; "offer"; "trade"; "npc"; "stranger"; "friend"; "ally";
      ] );
    ( Puzzle_challenge,
      [
        "puzzle"; "riddle"; "trap"; "mechanism"; "lock"; "door"; "investigate";
        "examine"; "clue"; "hidden"; "secret"; "inscription"; "rune"; "symbol";
        "decipher"; "solve";
      ] );
    ( Exploration,
      [
        "travel"; "path"; "road"; "forest"; "cave"; "mountain"; "river";
        "bridge"; "village"; "city"; "landscape"; "horizon"; "discover";
        "arrive"; "enter"; "explore"; "map";
      ] );
    ( Rest_downtime,
      [
        "rest"; "camp"; "sleep"; "heal"; "recover"; "shop"; "buy"; "sell";
        "craft"; "repair"; "inn"; "fire"; "tent"; "morning"; "dawn";
      ] );
    ( Plot_reveal,
      [
        "ancient"; "prophecy"; "legend"; "truth"; "reveal"; "secret"; "history";
        "destiny"; "chosen"; "curse"; "artifact"; "scroll"; "tome"; "knowledge";
        "lore";
      ] );
    ( Tension_building,
      [
        "shadow"; "darkness"; "ominous"; "rumble"; "whisper"; "distant"; "eerie";
        "silence"; "cold"; "fog"; "storm"; "howl"; "scream"; "fear"; "dread";
        "foreboding";
      ] );
  ]

(* ── Text tokenisation ──────────────────────────────────────────────── *)

(** Replace common punctuation with spaces, then split on whitespace.
    Avoids any dependency on [Str]. *)
let tokenize (text : string) : string list =
  let buf = Buffer.create (String.length text) in
  String.iter
    (fun c ->
      match c with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> Buffer.add_char buf c
      | _ -> Buffer.add_char buf ' ')
    text;
  let raw = Buffer.contents buf in
  let lowered = String.lowercase_ascii raw in
  (* split on spaces, drop empty strings *)
  String.split_on_char ' ' lowered
  |> List.filter (fun s -> String.length s > 0)

(* ── Keyword Scoring ────────────────────────────────────────────────── *)

type category_score = {
  category : intent_category;
  matched : string list;
  confidence : float;
}

let word_matches_keyword (word : string) (kw : string) : bool =
  String.length word >= String.length kw
  && String.sub word 0 (String.length kw) = kw

let score_category (words : string list) (cat : intent_category)
    (keywords : string list) : category_score =
  let total = List.length keywords in
  let matched =
    List.filter
      (fun kw -> List.exists (fun w -> word_matches_keyword w kw) words)
      keywords
  in
  let matched_count = List.length matched in
  let confidence =
    if total = 0 then 0.0
    else Float.min 1.0 (Float.of_int matched_count /. Float.of_int total)
  in
  { category = cat; matched; confidence }

let primary_threshold = 0.15
let secondary_threshold = 0.10

(** Keyword-based intent extraction (original algorithm). *)
let extract_keyword (text : string) : dm_intent =
  let words = tokenize text in
  let scores =
    List.map
      (fun (cat, keywords) -> score_category words cat keywords)
      keyword_table
  in
  let sorted =
    List.sort
      (fun a b -> Float.compare b.confidence a.confidence)
      scores
  in
  match sorted with
  | [] ->
      {
        primary = Unknown;
        secondary = None;
        confidence = 0.0;
        keywords_matched = [];
        mode = match_mode_to_string Keyword;
        provenance = intent_provenance_to_string Derived;
      }
  | best :: rest ->
      if best.confidence < primary_threshold then
        make_intent ~mode:Keyword ~provenance:Derived
          ~primary:Unknown ~secondary:None ~confidence:0.0
          ~keywords_matched:[]
      else
        let secondary =
          match rest with
          | second :: _ when
              second.confidence >= secondary_threshold
              && not (equal_intent_category second.category best.category) ->
              Some second.category
          | _ -> None
        in
        make_intent ~mode:Keyword ~provenance:Derived
          ~primary:best.category ~secondary ~confidence:best.confidence
          ~keywords_matched:best.matched

(* ── LLM Classification ────────────────────────────────────────────── *)

let category_of_string (s : string) : intent_category =
  match String.lowercase_ascii (String.trim s) with
  | "combat_setup" | "combat" -> Combat_setup
  | "social_encounter" | "social" -> Social_encounter
  | "puzzle_challenge" | "puzzle" -> Puzzle_challenge
  | "exploration" | "explore" -> Exploration
  | "rest_downtime" | "rest" -> Rest_downtime
  | "plot_reveal" | "plot" -> Plot_reveal
  | "tension_building" | "tension" -> Tension_building
  | _ -> Unknown

let build_classification_prompt (text : string) : string =
  Printf.sprintf
{|Classify this TRPG DM narration into exactly ONE primary category.

Categories:
- combat_setup: Monsters, weapons, battle, initiative, hostile encounters
- social_encounter: NPC dialogue, negotiation, persuasion, merchants, tavern
- puzzle_challenge: Riddles, traps, mechanisms, investigation, hidden clues
- exploration: Travel, discover environment, arrive at new location, landscape
- rest_downtime: Camp, heal, shop, craft, repair, rest
- plot_reveal: Lore, prophecy, ancient secrets, destiny, backstory revelation
- tension_building: Ominous signs, shadows, whispers, dread, foreboding atmosphere
- unknown: No clear intent detected

Reply with ONLY a JSON object (no markdown, no explanation):
{"primary":"<category>","secondary":"<category_or_null>","confidence":<0.0-1.0>,"keywords":["<matched_terms>"]}

DM text: %s|}
    (Yojson.Safe.to_string (`String text))

(** Parse dm_intent from a JSON object (Yojson). *)
let intent_of_json (json : Yojson.Safe.t) : (dm_intent, string) result =
  match json with
  | `Assoc fields ->
      let primary =
        match List.assoc_opt "primary" fields with
        | Some (`String s) -> category_of_string s
        | _ -> Unknown
      in
      let secondary =
        match List.assoc_opt "secondary" fields with
        | Some (`String s) ->
            let cat = category_of_string s in
            if equal_intent_category cat Unknown
               || equal_intent_category cat primary
            then None
            else Some cat
        | _ -> None
      in
      let confidence =
        match List.assoc_opt "confidence" fields with
        | Some (`Float f) -> Float.min 1.0 (Float.max 0.0 f)
        | Some (`Int i) -> Float.min 1.0 (Float.max 0.0 (Float.of_int i))
        | _ -> 0.5
      in
      let keywords_matched =
        match List.assoc_opt "keywords" fields with
        | Some (`List items) ->
            List.filter_map (function `String s -> Some s | _ -> None) items
        | _ -> []
      in
      Ok
        (make_intent ~mode:Llm ~provenance:Judgment
           ~primary ~secondary ~confidence ~keywords_matched)
  | _ -> Error "LLM response is not a JSON object"

(** Parse dm_intent from LLM text response.
    Handles both clean JSON and JSON embedded in prose. *)
let parse_llm_intent (text : string) : (dm_intent, string) result =
  let s = String.trim text in
  match intent_of_json (Yojson.Safe.from_string s) with
  | (Ok _) as ok -> ok
  | Error _ | (exception Yojson.Json_error _) ->
      (* Extract JSON substring between first { and last } *)
      let brace_start =
        try Some (String.index s '{') with Not_found -> None
      in
      let brace_end =
        try Some (String.rindex s '}') with Not_found -> None
      in
      (match (brace_start, brace_end) with
       | Some i, Some j when j > i ->
           let json_str = String.sub s i (j - i + 1) in
           (try intent_of_json (Yojson.Safe.from_string json_str)
            with Yojson.Json_error msg ->
              Error (Printf.sprintf "cannot parse extracted JSON: %s" msg))
       | _ ->
           Error (Printf.sprintf "no JSON found in LLM response: %s"
                    (String.sub s 0 (min 100 (String.length s)))))

(** Validate that an LLM response contains a parseable non-Unknown intent. *)
let llm_response_is_valid (resp : Llm_types.completion_response) : bool =
  match parse_llm_intent (Llm_types.text_of_response resp) with
  | Ok intent -> not (equal_intent_category intent.primary Unknown)
  | Error _ -> false

(** LLM-based intent extraction. Returns Error on failure.
    Catches exceptions (e.g. Llm_eio_env not initialized in test)
    so callers can fall back to keyword extraction. *)
let extract_with_llm (text : string) : (dm_intent, string) result =
  let prompt = build_classification_prompt text in
  try
    match
      Lodge_cascade.call ~cascade_name:"trpg_intent" ~prompt
        ~temperature:0.1 ~timeout_sec:15 ~max_tokens:200
        ~accept:llm_response_is_valid ()
    with
    | Ok r -> parse_llm_intent r.response
    | Error err -> Error err
  with exn ->
    Error (Printf.sprintf "extract_with_llm exception: %s" (Printexc.to_string exn))

(* ── Public API ─────────────────────────────────────────────────────── *)

let extract (text : string) : dm_intent =
  match get_match_mode () with
  | Keyword -> extract_keyword text
  | Llm ->
      (match extract_with_llm text with
       | Ok intent -> { intent with mode = match_mode_to_string Llm }
       | Error _ ->
           (* LLM-only mode still returns Unknown on failure *)
           make_intent ~mode:Llm ~provenance:Judgment
             ~primary:Unknown ~secondary:None ~confidence:0.0
             ~keywords_matched:[] )
  | Hybrid ->
      (match extract_with_llm text with
       | Ok intent -> { intent with mode = match_mode_to_string Hybrid }
       | Error _ ->
           let keyword_intent = extract_keyword text in
           { keyword_intent with
             mode = match_mode_to_string Hybrid;
             provenance = intent_provenance_to_string Fallback })

let string_of_category = function
  | Combat_setup -> "combat_setup"
  | Social_encounter -> "social_encounter"
  | Puzzle_challenge -> "puzzle_challenge"
  | Exploration -> "exploration"
  | Rest_downtime -> "rest_downtime"
  | Plot_reveal -> "plot_reveal"
  | Tension_building -> "tension_building"
  | Unknown -> "unknown"

let short_label = function
  | Combat_setup -> "Combat"
  | Social_encounter -> "Social"
  | Puzzle_challenge -> "Puzzle"
  | Exploration -> "Exploration"
  | Rest_downtime -> "Rest"
  | Plot_reveal -> "Plot"
  | Tension_building -> "Tension"
  | Unknown -> "Unknown"

let to_hint (intent : dm_intent) : string =
  match intent.primary with
  | Unknown -> "[DM Intent: Unknown]"
  | cat ->
      let detail =
        match intent.keywords_matched with
        | [] -> ""
        | kws ->
            let joined = String.concat " and " (List.filteri (fun i _ -> i < 3) kws) in
            Printf.sprintf " - %s detected" joined
      in
      Printf.sprintf "[DM Intent: %s%s]" (short_label cat) detail

let to_yojson (intent : dm_intent) : Yojson.Safe.t =
  let secondary_json =
    match intent.secondary with
    | None -> `Null
    | Some cat -> `String (string_of_category cat)
  in
  let keywords_json =
    `List (List.map (fun s -> `String s) intent.keywords_matched)
  in
  `Assoc
    [
      ("primary", `String (string_of_category intent.primary));
      ("secondary", secondary_json);
      ("confidence", `Float intent.confidence);
      ("keywords_matched", keywords_json);
      ("mode", `String intent.mode);
      ("provenance", `String intent.provenance);
    ]
