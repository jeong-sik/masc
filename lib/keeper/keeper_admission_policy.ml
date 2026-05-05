(* See keeper_admission_policy.mli for documentation. *)

type tier = Preferred | Acceptable | Survival

type candidate = {
  provider : string;
  model : string;
  tier : tier;
}

type t = {
  keeper_id : string;
  candidates : candidate list;
  weight : int;
  min_tier : tier;
}

type validation_error =
  | Empty_candidate_list
  | Min_tier_above_preferred
  | Duplicate_provider of string
  | Unknown_tier_label of string
  | Weight_out_of_range of int

let tier_label = function
  | Preferred -> "Preferred"
  | Acceptable -> "Acceptable"
  | Survival -> "Survival"

let tier_of_label = function
  | "Preferred" -> Some Preferred
  | "Acceptable" -> Some Acceptable
  | "Survival" -> Some Survival
  | _ -> None

let tier_compare a b =
  let rank = function
    | Preferred -> 0
    | Acceptable -> 1
    | Survival -> 2
  in
  Stdlib.compare (rank a) (rank b)

let has_duplicate_provider candidates =
  let rec aux seen = function
    | [] -> None
    | c :: rest ->
        if List.mem c.provider seen then Some c.provider
        else aux (c.provider :: seen) rest
  in
  aux [] candidates

let of_fields ~keeper_id ~candidates ~weight ~min_tier =
  if candidates = [] then Error Empty_candidate_list
  else if weight < 1 then Error (Weight_out_of_range weight)
  else
    match List.nth_opt candidates 0 with
    | None -> Error Empty_candidate_list
    | Some head_candidate ->
        if tier_compare min_tier head_candidate.tier < 0 then
          Error Min_tier_above_preferred
        else
          match has_duplicate_provider candidates with
          | Some p -> Error (Duplicate_provider p)
          | None -> Ok { keeper_id; candidates; weight; min_tier }

let parse_toml_block ~keeper_id:_ (_toml_text : string) =
  (* Implementation deferred to PR-B-2.  The mli signature is stable;
     the parser will lift each TOML candidate row into a [candidate]
     record and forward to [of_fields].  Returning [Error] from this
     stub keeps any caller from accidentally building an empty policy
     before the parser lands. *)
  Error Empty_candidate_list

let keeper_id t = t.keeper_id
let candidates t = t.candidates
let weight t = t.weight
let min_tier t = t.min_tier

let candidates_above_min_tier t =
  List.filter (fun c -> tier_compare c.tier t.min_tier <= 0) t.candidates

let top_provider t =
  match t.candidates with
  | c :: _ -> c.provider
  | [] ->
      (* Unreachable: [of_fields] rejects empty lists.  Defensive only. *)
      ""
