(** trpg_actor_match.ml — Actor-Keeper Compatibility Scoring.

    Scores how well a Keeper (LLM agent) matches an Actor (TRPG character)
    based on three dimensions:
    - Trait overlap (Jaccard similarity of trait sets)
    - Archetype affinity (predefined affinity matrix)
    - Semantic alignment (keyword overlap between persona and keeper description)

    @since 2.70.0 *)

(** Result of scoring one keeper against one actor. *)
type match_score = {
  keeper_name : string;
  actor_id : string;
  trait_overlap : float;       (** 0.0-1.0 Jaccard similarity *)
  archetype_affinity : float;  (** 0.0-1.0 from affinity matrix *)
  semantic_alignment : float;  (** 0.0-1.0 keyword overlap *)
  total : float;               (** weighted combination *)
}

(* ---------- Stop Words ---------- *)

let stop_words = [
  "the"; "a"; "an"; "is"; "are"; "was"; "were";
  "and"; "or"; "but"; "in"; "on"; "at"; "to";
  "for"; "of"; "with"; "by";
]

(* ---------- Text Normalization ---------- *)

(** Normalize a word to lowercase ASCII. *)
let normalize (w : string) : string =
  String.lowercase_ascii w

(** Split text into normalized word tokens, filtering stop words and
    single-character fragments. Splits on spaces and common punctuation. *)
let tokenize (text : string) : string list =
  text
  |> String.lowercase_ascii
  |> String.split_on_char ' '
  |> List.concat_map (String.split_on_char ',')
  |> List.concat_map (String.split_on_char '.')
  |> List.concat_map (String.split_on_char ';')
  |> List.concat_map (String.split_on_char ':')
  |> List.concat_map (String.split_on_char '!')
  |> List.concat_map (String.split_on_char '?')
  |> List.concat_map (String.split_on_char '-')
  |> List.concat_map (String.split_on_char '_')
  |> List.concat_map (String.split_on_char '(')
  |> List.concat_map (String.split_on_char ')')
  |> List.map String.trim
  |> List.filter (fun w -> String.length w > 1)
  |> List.filter (fun w -> not (List.mem w stop_words))
  |> List.sort_uniq String.compare

(* ---------- Archetype Affinity Matrix ---------- *)

(** Predefined affinity between keeper styles and actor archetypes.
    Returns a score in 0.0-1.0. Unmatched pairs default to 0.5. *)
let archetype_affinity_score (keeper_style : string) (actor_archetype : string) : float =
  let ks = normalize keeper_style in
  let aa = normalize actor_archetype in
  match (ks, aa) with
  | ("analytical", "wizard")  -> 0.9
  | ("analytical", "rogue")   -> 0.6
  | ("analytical", "warrior") -> 0.4
  | ("creative", "bard")      -> 0.9
  | ("creative", "wizard")    -> 0.7
  | ("creative", "warrior")   -> 0.5
  | ("empathetic", "healer")  -> 0.9
  | ("empathetic", "bard")    -> 0.7
  | ("empathetic", "warrior") -> 0.5
  | ("strategic", "warrior")  -> 0.9
  | ("strategic", "rogue")    -> 0.7
  | ("strategic", "wizard")   -> 0.6
  | ("chaotic", "rogue")      -> 0.9
  | ("chaotic", "bard")       -> 0.7
  | ("chaotic", "warrior")    -> 0.6
  | _ -> 0.5

(* ---------- Trait Overlap (Jaccard Similarity) ---------- *)

(** Compute Jaccard similarity between two trait sets.
    Returns |intersection| / |union|. Both empty -> 0.5 (neutral). *)
let trait_overlap_score (keeper_traits : string list) (actor_traits : string list) : float =
  let normalize_set traits =
    traits |> List.map normalize |> List.sort_uniq String.compare
  in
  let ks = normalize_set keeper_traits in
  let as_ = normalize_set actor_traits in
  match (ks, as_) with
  | ([], []) -> 0.5
  | _ ->
    let intersection_count =
      List.length (List.filter (fun k -> List.mem k as_) ks)
    in
    (* union = |A| + |B| - |intersection| *)
    let union_count =
      List.length ks + List.length as_ - intersection_count
    in
    if union_count = 0 then 0.5
    else float_of_int intersection_count /. float_of_int union_count

(* ---------- Semantic Alignment ---------- *)

(** Compute keyword overlap between actor persona and keeper description.
    Returns common_words / max(len_a, len_b). Both empty -> 0.0. *)
let semantic_alignment_score (actor_persona : string) (keeper_description : string) : float =
  let words_a = tokenize actor_persona in
  let words_b = tokenize keeper_description in
  let len_a = List.length words_a in
  let len_b = List.length words_b in
  let max_len = max len_a len_b in
  if max_len = 0 then 0.0
  else
    let common_count =
      List.length (List.filter (fun w -> List.mem w words_b) words_a)
    in
    float_of_int common_count /. float_of_int max_len

(* ---------- Scoring ---------- *)

(** Weights for the three scoring dimensions. *)
let weight_trait = 0.3
let weight_archetype = 0.4
let weight_semantic = 0.3

(** Score a single keeper against a single actor.
    Total = trait_overlap * 0.3 + archetype_affinity * 0.4 + semantic_alignment * 0.3 *)
let score ~(keeper_name : string) ~(keeper_style : string)
    ~(keeper_description : string) ~(actor_id : string)
    ~(actor_archetype : string) ~(actor_traits : string list)
    ~(actor_persona : string) : match_score =
  (* Keeper traits are extracted from description for trait overlap *)
  let keeper_traits = tokenize keeper_description in
  let t_overlap = trait_overlap_score keeper_traits actor_traits in
  let a_affinity = archetype_affinity_score keeper_style actor_archetype in
  let s_alignment = semantic_alignment_score actor_persona keeper_description in
  let total =
    t_overlap *. weight_trait
    +. a_affinity *. weight_archetype
    +. s_alignment *. weight_semantic
  in
  {
    keeper_name;
    actor_id;
    trait_overlap = t_overlap;
    archetype_affinity = a_affinity;
    semantic_alignment = s_alignment;
    total;
  }

(* ---------- Ranking ---------- *)

(** Score multiple keepers against one actor. Returns list sorted by
    total score, highest first. Each keeper is (name, style, description). *)
let rank ~(keepers : (string * string * string) list) ~(actor_id : string)
    ~(actor_archetype : string) ~(actor_traits : string list)
    ~(actor_persona : string) : match_score list =
  keepers
  |> List.map (fun (name, style, description) ->
       score ~keeper_name:name ~keeper_style:style
         ~keeper_description:description ~actor_id ~actor_archetype
         ~actor_traits ~actor_persona)
  |> List.sort (fun a b -> compare b.total a.total)

(** Return the top match, or None if no keepers are provided. *)
let best_match ~(keepers : (string * string * string) list) ~(actor_id : string)
    ~(actor_archetype : string) ~(actor_traits : string list)
    ~(actor_persona : string) : match_score option =
  match rank ~keepers ~actor_id ~actor_archetype ~actor_traits ~actor_persona with
  | best :: _ -> Some best
  | [] -> None

(* ---------- JSON Serialization ---------- *)

(** Convert a match_score to Yojson.Safe.t. *)
let to_yojson (m : match_score) : Yojson.Safe.t =
  `Assoc [
    ("keeperName", `String m.keeper_name);
    ("actorId", `String m.actor_id);
    ("traitOverlap", `Float m.trait_overlap);
    ("archetypeAffinity", `Float m.archetype_affinity);
    ("semanticAlignment", `Float m.semantic_alignment);
    ("total", `Float m.total);
  ]

(** Convert a list of match_scores to a JSON array. *)
let ranking_to_yojson (scores : match_score list) : Yojson.Safe.t =
  `List (List.map to_yojson scores)
