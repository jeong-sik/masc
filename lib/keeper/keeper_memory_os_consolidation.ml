(** Keeper_memory_os_consolidation — per-keeper LLM consolidation pass.

    The librarian writes facts as they are observed; over time a keeper's store
    accumulates redundant, superseded, and verbose claims. This pass is the
    "summarize" half of RFC-0247: periodically an LLM reads the keeper's whole
    fact set and JUDGES which claims say the same thing (merge them into one
    consolidated claim) and which are now obsolete (forget them).

    Boundary (the design tenet): the DECISION — what to merge, what to forget, how
    to word a consolidated claim — is the LLM's. The STRUCTURE — numbering the
    facts, parsing the plan, applying it, preserving provenance, writing back — is
    deterministic and lives here, fully testable without an LLM. There is no score:
    the LLM names the groups directly.

    Plan application is conservative:
    apply is conservative. The LLM references existing facts only by index, so it
    cannot fabricate a survivor; a fact named in no group and no drop list is kept
    unchanged; a "group" with fewer than two valid members is a no-op (we do not
    let the LLM silently reword a single fact); out-of-range or duplicate indices
    are skipped. *)

open Keeper_memory_os_types

let wire_field_member_indices = "member_indices"
let wire_field_consolidated_claim = "consolidated_claim"
let wire_field_category = "category"
let wire_field_groups = "groups"
let wire_field_drop_indices = "drop_indices"

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

type output_rejection_reason =
  | Non_json
  | Non_object_json

let output_rejection_reason_to_string = function
  | Non_json -> "non_json"
  | Non_object_json -> "non_object_json"
;;

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

(* A merged row has one [claim_kind] slot, so members with different explicit
   tags cannot be represented without losing information. Reject that group and
   preserve every member. *)
let group_preserves_claim_kind ~members =
  match members with
  | [] -> true
  | (first : fact) :: rest ->
    List.for_all (fun (m : fact) -> m.claim_kind = first.claim_kind) rest
;;

(* A merged row has only one [valid_until] slot. If members carry different
   explicit values, choosing min/max/earliest would invent policy and discard
   information, so the group is rejected and every member remains unchanged. *)
let group_preserves_valid_until ~members =
  match members with
  | [] -> true
  | (first : fact) :: rest ->
    List.for_all (fun (member : fact) -> member.valid_until = first.valid_until) rest
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
    ( assoc_field wire_field_member_indices json
    , string_field wire_field_consolidated_claim json
    , string_field wire_field_category json )
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

(* Parse the LLM's consolidation plan. Unknown/garbled groups inside a valid
   object are dropped individually (defensive degrade) and emit a warning with
   dropped/total counts, never aborting the whole plan. The provider output
   itself must be an exact JSON object; prose, markdown fences, and substring
   salvage are rejected at [plan_of_string]. *)
let log_dropped_groups ~dropped ~total =
  if dropped > 0
  then
    Log.Keeper.warn
      "memory_os_consolidation: dropped malformed merge groups dropped=%d total=%d"
      dropped
      total
;;

let plan_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc _ ->
    let groups =
      match assoc_field wire_field_groups json with
      | Some (`List items) ->
        let parsed = List.filter_map merge_group_of_json items in
        log_dropped_groups ~dropped:(List.length items - List.length parsed) ~total:(List.length items);
        parsed
      | _ -> []
    in
    let drop_indices =
      match assoc_field wire_field_drop_indices json with
      | Some indices_json -> int_list_of_json indices_json
      | None -> []
    in
    { groups; drop_indices }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    empty_plan
;;

let json_of_output_result raw =
  let raw = String.trim raw in
  match Yojson.Safe.from_string raw with
  | `Assoc _ as json -> Ok json
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error Non_object_json
  | exception Yojson.Json_error _ -> Error Non_json
;;

let log_rejected_output ~reason ~raw =
  Log.Keeper.warn
    "memory_os_consolidation: rejected provider output reason=%s bytes=%d; \
     expected exact JSON object"
    (output_rejection_reason_to_string reason)
    (String.length raw)
;;

let plan_result_of_string raw =
  match json_of_output_result raw with
  | Ok json -> Ok (plan_of_json json)
  | Error reason ->
    log_rejected_output ~reason ~raw;
    Error reason
;;

let plan_of_string raw =
  match plan_result_of_string raw with
  | Ok plan -> Some plan
  | Error _ -> None
;;

(* ---------- Apply (pure, deterministic) ---------- *)

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

let valid_until_for_members = function
  | [] -> None
  | (first : fact) :: _ -> first.valid_until
;;

let last_verified_for_members members =
  max_optional_float (List.map (fun (m : fact) -> m.last_verified_at) members)
;;

let shared_claim_id_for_members members =
  let ids =
    members
    |> List.filter_map (fun (m : fact) -> m.claim_id)
    |> List.sort_uniq String.compare
  in
  match ids with
  | [ id ] -> Some id
  | [] | _ :: _ :: _ -> None
;;

(* The consolidated fact for one group: claim/category come from the LLM;
   provenance is reconstructed structurally. The exact common [valid_until] is
   preserved; groups with different explicit horizons never reach this function. *)
let consolidated_fact ~now:_ ~members (group : merge_group) =
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
    (* Carry the earliest member's tag. The merge gate
       ([group_preserves_claim_kind] in [apply_plan]) guarantees every member shares
       one claim_kind, so the earliest's tag IS the group's — sound regardless of
       which member is earliest. *)
  ; claim_kind = earliest.claim_kind
  ; source = earliest.source
  ; observed_by
  ; first_seen
  ; valid_until = valid_until_for_members members
  ; last_verified_at = last_verified_for_members members
  ; schema_version
  ; claim_id = shared_claim_id_for_members members
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
         if group_preserves_claim_kind ~members:member_facts
            && group_preserves_valid_until ~members:member_facts
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
