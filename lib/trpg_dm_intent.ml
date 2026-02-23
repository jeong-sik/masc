(** trpg_dm_intent.ml — DM Intent Extraction (deterministic, keyword-based).
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
}

(* --- Keyword tables ---------------------------------------------------- *)

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

(* --- Text tokenisation ------------------------------------------------- *)

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

(* --- Scoring ----------------------------------------------------------- *)

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

(* --- Public API -------------------------------------------------------- *)

let extract (text : string) : dm_intent =
  let words = tokenize text in
  let scores =
    List.map
      (fun (cat, keywords) -> score_category words cat keywords)
      keyword_table
  in
  (* sort descending by confidence, stable *)
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
      }
  | best :: rest ->
      if best.confidence < primary_threshold then
        {
          primary = Unknown;
          secondary = None;
          confidence = 0.0;
          keywords_matched = [];
        }
      else
        let secondary =
          match rest with
          | second :: _ when
              second.confidence >= secondary_threshold
              && not (equal_intent_category second.category best.category) ->
              Some second.category
          | _ -> None
        in
        {
          primary = best.category;
          secondary;
          confidence = best.confidence;
          keywords_matched = best.matched;
        }

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
    ]
