(** Keeper_memory_os_consolidation — per-keeper LLM consolidation pass.

    The librarian writes facts as they are observed; over time a keeper's store
    accumulates redundant, superseded, and verbose claims. This pass is the
    "summarize" half of RFC-0247: periodically an LLM reads the keeper's whole
    fact set and JUDGES which claims say the same thing (merge them into one
    consolidated claim) and which are now obsolete (forget them).

    Not to be confused with {!Keeper_memory_os_consolidator}: that is the
    cross-keeper Tier-2 pass (promote a claim several DISTINCT keepers hold into
    the shared store); this is the intra-keeper pass (shrink ONE keeper's own
    store via the LLM).

    Boundary (the design tenet): the DECISION — what to merge, what to forget, how
    to word a consolidated claim — is the LLM's. The STRUCTURE — numbering the
    facts, parsing the plan, applying it, preserving provenance, writing back — is
    deterministic and lives here, fully testable without an LLM. There is no score:
    the LLM names the groups directly.

    Safety (RFC-0247 §7, R7 — never lose a good fact to a hallucinated plan):
    apply is conservative. The LLM references existing facts only by index, so it
    cannot fabricate a survivor; a fact named in no group and no drop list is kept
    unchanged; a "group" with fewer than two valid members is a no-op (we do not
    let the LLM silently reword a single fact); out-of-range or duplicate indices
    are skipped. *)

open Keeper_memory_os_types

(* The LLM's judgement that several existing facts (referenced by 0-based index
   into the numbered input list) state the same thing or supersede one another,
   and should collapse into one [consolidated_claim] under [category]. *)
type merge_group =
  { member_indices : int list
  ; consolidated_claim : string
  ; category : category
  }

(* A consolidation plan: groups to merge, plus indices the LLM judges obsolete and
   wants forgotten outright (a claim now false, not merged into anything). *)
type consolidation_plan =
  { groups : merge_group list
  ; drop_indices : int list
  }

let empty_plan = { groups = []; drop_indices = [] }

(* The numbered fact list the consolidation prompt sees: one 0-based line per
   fact, "[category] claim". The index is the only handle the LLM gets on an
   existing fact, so [apply_plan] reads back the same order. Pure — no IO. *)
let one_line_claim claim =
  claim
  |> String.map (function
    | '\r' | '\n' -> ' '
    | c -> c)
  |> String.trim
;;

let render_numbered_facts facts =
  facts
  |> List.mapi (fun i (f : fact) ->
    Printf.sprintf "%d: [%s] %s" i (category_to_string f.category) (one_line_claim f.claim))
  |> String.concat "\n"
;;

let category_specificity = function
  | Ephemeral | Unknown _ -> 0
  | Fact -> 1
  | Code_change | Preference | Blocker | Goal | Constraint -> 2
  | Validated_approach | Lesson -> 3
;;

let group_preserves_category ~members (group : merge_group) =
  let group_specificity = category_specificity group.category in
  let member_specificity =
    List.fold_left
      (fun acc (fact : fact) -> max acc (category_specificity fact.category))
      0
      members
  in
  group_specificity = member_specificity
  && List.exists
       (fun (fact : fact) ->
          String.equal
            (category_to_string fact.category)
            (category_to_string group.category))
       members
;;

(* ---------- JSON parsing (defensive, like the librarian) ---------- *)

let int_list_of_json = function
  | `List items ->
    List.filter_map
      (function
        | `Int i -> Some i
        | `Intlit s -> int_of_string_opt s
        | `Assoc _ | `Bool _ | `Float _ | `List _ | `Null | `String _ -> None)
      items
  | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _ -> []
;;

let assoc_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

let string_field key json =
  match assoc_field key json with
  | Some (`String s) -> Some s
  | _ -> None
;;

let merge_group_of_json json =
  match
    ( assoc_field "member_indices" json
    , string_field "consolidated_claim" json
    , string_field "category" json )
  with
  | Some indices_json, Some claim, Some category_str
    when String.trim claim <> "" ->
    Some
      { member_indices = int_list_of_json indices_json
      ; consolidated_claim = String.trim claim
      ; category = category_of_string category_str
      }
  | _ -> None
;;

(* Parse the LLM's consolidation output. Unknown/garbled groups are dropped
   individually (defensive degrade), never aborting the whole plan. A plan that
   fails to parse at all yields [empty_plan] = a no-op consolidation. *)
let plan_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc _ ->
    let groups =
      match assoc_field "groups" json with
      | Some (`List items) -> List.filter_map merge_group_of_json items
      | _ -> []
    in
    let drop_indices =
      match assoc_field "drop_indices" json with
      | Some indices_json -> int_list_of_json indices_json
      | None -> []
    in
    { groups; drop_indices }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    empty_plan
;;

let json_of_output raw =
  let raw = String.trim raw in
  let raw =
    if String.starts_with ~prefix:"```" raw
    then (
      match String.split_on_char '\n' raw with
      | first :: rest when String.starts_with ~prefix:"```" first ->
        rest
        |> List.rev
        |> (function
          | last :: rest when String.starts_with ~prefix:"```" (String.trim last) ->
            List.rev rest
          | lines -> List.rev lines)
        |> String.concat "\n"
        |> String.trim
      | _ -> raw)
    else raw
  in
  match Yojson.Safe.from_string raw with
  | json -> Some json
  | exception Yojson.Json_error _ ->
    let len = String.length raw in
    let rec find_from i ch =
      if i >= len then None else if Char.equal raw.[i] ch then Some i else find_from (i + 1) ch
    in
    let rec find_from_right i ch =
      if i < 0
      then None
      else if Char.equal raw.[i] ch
      then Some i
      else find_from_right (i - 1) ch
    in
    (match find_from 0 '{', find_from_right (len - 1) '}' with
     | Some start, Some stop when start < stop ->
       let candidate = String.sub raw start (stop - start + 1) in
       (match Yojson.Safe.from_string candidate with
        | json -> Some json
        | exception Yojson.Json_error _ -> None)
     | _ -> None)
;;

let plan_of_string raw =
  match json_of_output raw with
  | Some json -> Some (plan_of_json json)
  | None -> None
;;

(* ---------- Apply (pure, deterministic) ---------- *)

let min_optional_float values =
  List.fold_left
    (fun acc -> function
       | None -> acc
       | Some value ->
         (match acc with
          | None -> Some value
          | Some current -> Some (Float.min current value)))
    None
    values
;;

let max_optional_float values =
  List.fold_left
    (fun acc -> function
       | None -> acc
       | Some value ->
         (match acc with
          | None -> Some value
          | Some current -> Some (Float.max current value)))
    None
    values
;;

let valid_until_for_group ~now ~members category =
  match category with
  | Ephemeral ->
    (match min_optional_float (List.map (fun (m : fact) -> m.valid_until) members) with
     | Some _ as valid_until -> valid_until
     | None -> category_valid_until ~now category)
  | Fact | Constraint | Preference | Blocker | Goal | Code_change
  | Validated_approach | Lesson | Unknown _ -> category_valid_until ~now category
;;

let last_verified_for_members members =
  max_optional_float (List.map (fun (m : fact) -> m.last_verified_at) members)
;;

(* The consolidated fact for one group: its claim/category come from the LLM; its
   provenance and temporal metadata are reconstructed structurally from the
   members so nothing is fabricated — earliest source/first_seen, the union of
   corroborating keepers, existing Ephemeral expiry, and the newest verification
   timestamp from the merged members. *)
let consolidated_fact ~now ~members (group : merge_group) =
  let earliest =
    match members with
    | [] -> invalid_arg "Keeper_memory_os_consolidation.consolidated_fact: empty members"
    | first :: rest ->
      List.fold_left
        (fun acc m -> if m.first_seen < acc.first_seen then m else acc)
        first
        rest
  in
  let first_seen =
    List.fold_left (fun acc m -> Float.min acc m.first_seen) earliest.first_seen members
  in
  let observed_by =
    List.concat_map (fun m -> m.observed_by) members |> List.sort_uniq String.compare
  in
  { claim = group.consolidated_claim
  ; category = group.category
  ; source = earliest.source
  ; observed_by
  ; first_seen
  ; valid_until = valid_until_for_group ~now ~members group.category
  ; last_verified_at = last_verified_for_members members
  ; schema_version
  }
;;

(* Apply a plan to a keeper's facts. Returns the new fact list. Conservative: a
   fact not claimed by any valid group and not explicitly dropped survives
   unchanged; a group needs >= 2 in-range members (each used at most once) to
   merge; every other index reference is skipped. Output order is deterministic:
   each consolidated fact takes the slot of its earliest member index, survivors
   keep their slot, dropped slots vanish. *)
let apply_plan ~now ~facts plan =
  let n = List.length facts in
  let facts_arr = Array.of_list facts in
  (* slot.(i) = `Keep | `Consumed | `Drop ; consolidated keyed by min member idx *)
  let slot = Array.make n `Keep in
  let consolidated = Hashtbl.create 16 in
  let in_range i = i >= 0 && i < n in
  let dedup_sorted is = List.sort_uniq compare (List.filter in_range is) in
  List.iter
    (fun group ->
       (* a member is eligible only if still `Keep (not already consumed by an
          earlier group or dropped) — first group wins a contested fact. *)
       let members =
         dedup_sorted group.member_indices
         |> List.filter (fun i -> slot.(i) = `Keep)
       in
       if List.length members >= 2
       then (
         let member_facts = List.map (fun i -> facts_arr.(i)) members in
         if group_preserves_category ~members:member_facts group
         then (
           let anchor =
             (* members is guaranteed non-empty by the [>= 2] guard above *)
             match members with
             | [] -> invalid_arg "Keeper_memory_os_consolidation.apply_plan: empty group"
             | first :: rest ->
               List.fold_left
                 (fun acc i ->
                    if facts_arr.(i).first_seen < facts_arr.(acc).first_seen
                    then i
                    else acc)
                 first
                 rest
           in
           List.iter (fun i -> slot.(i) <- `Consumed) members;
           Hashtbl.replace
             consolidated
             anchor
             (consolidated_fact ~now ~members:member_facts group))))
    plan.groups;
  List.iter
    (fun i -> if in_range i && slot.(i) = `Keep then slot.(i) <- `Drop)
    plan.drop_indices;
  (* Walk original index order, emitting survivors and the consolidated fact that
     anchors at each slot, so the result is deterministic and roughly preserves
     the store's order. *)
  let out = ref [] in
  for i = n - 1 downto 0 do
    (match Hashtbl.find_opt consolidated i with
     | Some f -> out := f :: !out
     | None -> ());
    (match slot.(i) with
     | `Keep -> out := facts_arr.(i) :: !out
     | `Consumed | `Drop -> ())
  done;
  !out
;;
