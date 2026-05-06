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

let has_duplicate_candidate candidates =
  let rec aux seen = function
    | [] -> None
    | c :: rest ->
        let key = (c.provider, c.model) in
        if List.mem key seen then Some c.provider
        else aux (key :: seen) rest
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
          match has_duplicate_candidate candidates with
          | Some p -> Error (Duplicate_provider p)
          | None -> Ok { keeper_id; candidates; weight; min_tier }

(* JSON parsing helpers.  Avoid Yojson.Safe.Util to keep the diff
   reviewable — direct match on `Assoc / `List / `String / `Int. *)

let assoc_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let int_or_default ~default = function
  | Some (`Int n) -> n
  | _ -> default

let string_field = function
  | Some (`String s) -> Some s
  | _ -> None

let candidate_of_json json =
  let provider = string_field (assoc_field "provider" json) in
  let model = string_field (assoc_field "model" json) in
  let tier_str = string_field (assoc_field "tier" json) in
  match provider, model, tier_str with
  | Some provider, Some model, Some tier_str ->
      (match tier_of_label tier_str with
       | Some tier -> Ok { provider; model; tier }
       | None -> Error (Unknown_tier_label tier_str))
  | _ -> Error Empty_candidate_list
    (* Missing required field is treated as malformed input — the
       caller's invariant is that every candidate row has provider /
       model / tier. *)

let candidates_of_json = function
  | `List rows ->
      let rec collect acc = function
        | [] -> Ok (List.rev acc)
        | row :: rest ->
            (match candidate_of_json row with
             | Ok c -> collect (c :: acc) rest
             | Error e -> Error e)
      in
      collect [] rows
  | _ -> Error Empty_candidate_list

let parse_admission_json ~keeper_id (json : Yojson.Safe.t) =
  let weight = int_or_default ~default:1 (assoc_field "weight" json) in
  let min_tier_label =
    Option.value ~default:"Acceptable"
      (string_field (assoc_field "min_tier" json))
  in
  match tier_of_label min_tier_label with
  | None -> Error (Unknown_tier_label min_tier_label)
  | Some min_tier ->
      (match assoc_field "candidates" json with
       | None -> Error Empty_candidate_list
       | Some candidates_json ->
           (match candidates_of_json candidates_json with
            | Error e -> Error e
            | Ok candidates ->
                of_fields ~keeper_id ~candidates ~weight ~min_tier))

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
