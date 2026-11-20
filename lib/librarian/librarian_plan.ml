open Keeper_memory_os_types
module Answer = Librarian_answer
module Effects = Librarian_effects
module Ids = Set_util.StringSet
module By_id = Set_util.StringMap
module Op_numbers = Set.Make (Int)

type shown =
  { memory : (string * string) list option
  ; units : (string * int) list
  }

type working_state =
  | Kept
  | Replaced of string
  | Alone of Librarian_log.alone_working_state

type t =
  { facts : fact list
  ; effects : Effects.t
  ; working_state : working_state
  }

(* What a screened op says of one fact, in Memory ids. *)
type stating =
  | New_claim of string * Answer.new_fact * int list
  (** Id of the claim, the claim, and the offsets of the units it names. *)
  | Seen_again of string * int list
  (** Id of a fact Memory holds, and the offsets of the units that said it
      again. *)

(* The fact a stating op leaves in Memory, and the offsets of its units. *)
let kept_and_units = function
  | New_claim (id, (_ : Answer.new_fact), offsets) | Seen_again (id, offsets) -> id, offsets
;;

(* An op that passed screening, in Memory ids. *)
type screened =
  { number : int
  ; removes : (string * Effects.removal) list
  ; states : stating option
  }

let ( let* ) = Result.bind
let ids_of facts = List.fold_left (fun ids fact -> Ids.add (memory_id fact) ids) Ids.empty facts

let resolve_one table name ~missing =
  match List.assoc_opt name table with
  | Some value -> Ok value
  | None -> Error missing
;;

let resolve_all table names ~missing =
  List.fold_right
    (fun name resolved ->
       let* resolved = resolved in
       let* value = resolve_one table name ~missing in
       Ok (value :: resolved))
    names
    (Ok [])
;;

let stated_fact = function
  | Answer.Add fact | Merge { into = fact; _ } | Revise { into = fact; _ } -> Some fact
  | Drop _ | Seen _ -> None
;;

let named_facts = function
  | Answer.Add _ -> []
  | Drop { ref_; _ } | Revise { ref_; _ } | Seen { ref_; _ } -> [ ref_ ]
  | Merge { refs; _ } -> refs
;;

(* A named fact whose claim is the new claim is the fact that stays. *)
let replaced ids ~by removal =
  List.filter_map (fun id -> if String.equal id by then None else Some (id, removal)) ids
;;

let screen ~shown ~current ~removed_since ~named_before number op =
  let* table =
    match shown.memory, op with
    | None, (Answer.Drop _ | Merge _ | Revise _ | Seen _) -> Error Effects.Not_valid_alone
    | None, Add _ -> Ok []
    | Some table, (Add _ | Drop _ | Merge _ | Revise _ | Seen _) -> Ok table
  in
  let* named = resolve_all table (named_facts op) ~missing:Effects.Unknown_ref in
  let stated =
    Option.map
      (fun (fact : Answer.new_fact) -> memory_id_of_claim fact.claim, fact)
      (stated_fact op)
  in
  let* () =
    match
      List.find_map
        (fun id -> By_id.find_opt id removed_since)
        (named @ Option.to_list (Option.map fst stated))
    with
    | Some seq -> Error (Effects.Removed_during_flight { seq })
    | None -> Ok ()
  in
  let* () =
    if List.for_all (fun id -> Ids.mem id current) named
    then Ok ()
    else Error Effects.Unknown_ref
  in
  let* () =
    if List.exists (fun id -> Ids.mem id named_before) named
    then Error Effects.Ref_used_twice
    else Ok ()
  in
  let units names =
    resolve_all shown.units names ~missing:Effects.Source_outside_question
  in
  let* states =
    match op, stated with
    | Answer.Seen { ref_; from_units }, (_ : (string * Answer.new_fact) option) ->
      let* seen = resolve_one table ref_ ~missing:Effects.Unknown_ref in
      let* offsets = units from_units in
      Ok (Some (Seen_again (seen, offsets)))
    | (Add _ | Drop _ | Merge _ | Revise _), None -> Ok None
    | (Add _ | Drop _ | Merge _ | Revise _), Some (id, fact) ->
      let* offsets = units fact.from_units in
      Ok (Some (New_claim (id, fact, offsets)))
  in
  let removes =
    match op with
    | Answer.Add _ | Seen _ -> []
    | Drop { reason; _ } -> List.map (fun id -> id, Effects.Dropped { reason }) named
    | Merge { into; _ } ->
      let successor = memory_id_of_claim into.claim in
      replaced named ~by:successor (Effects.Merged_into successor)
    | Revise { into; _ } ->
      let successor = memory_id_of_claim into.claim in
      replaced named ~by:successor (Effects.Revised_into successor)
  in
  Ok ({ number; removes; states }, named)
;;

let observed_fact ~first_seen ~last_seen ~trace_id (fact : Answer.new_fact) : fact =
  { claim = fact.claim
  ; category = fact.category
  ; first_seen
  ; last_seen
  ; origin = { kind = Injected; trace_id }
  ; basis = Observed fact.observation
  }
;;

(* What the facts a claim replaces say about time. A merge or a revision
   says what those facts said, so Memory has known it since the oldest of
   them was first seen, and has no newer evidence for it than the newest of
   them was last seen unless an op names a unit for it. *)
type replaced_span =
  { earliest_first_seen : float
  ; latest_last_seen : float
  }

(* For each claim a live op states, the span of the facts the ops stating it
   replace. A claim that replaces nothing has no entry. *)
let replaced_spans ~by_id live =
  List.fold_left
    (fun spans op ->
       match op.states with
       | None | Some (Seen_again _) -> spans
       | Some (New_claim (successor, (_ : Answer.new_fact), (_ : int list))) ->
         List.fold_left
           (fun spans (replaced, (_ : Effects.removal)) ->
              match By_id.find_opt replaced by_id with
              | None -> spans
              | Some (fact : fact) ->
                let span =
                  match By_id.find_opt successor spans with
                  | None ->
                    { earliest_first_seen = fact.first_seen
                    ; latest_last_seen = fact.last_seen
                    }
                  | Some span ->
                    { earliest_first_seen = Float.min span.earliest_first_seen fact.first_seen
                    ; latest_last_seen = Float.max span.latest_last_seen fact.last_seen
                    }
                in
                By_id.add successor span spans)
           spans
           op.removes)
    By_id.empty
    live
;;

(* The claims a live op states or sees again while naming at least one unit.
   Only those have new evidence: a held claim written again without a unit is
   the question's own Memory read back, and a merge or a revision that names
   no unit only says again what Memory held. *)
let evidenced live =
  List.fold_left
    (fun ids op ->
       match op.states with
       | None -> ids
       | Some stating ->
         (match kept_and_units stating with
          | (_ : string), [] -> ids
          | id, _ :: _ -> Ids.add id ids))
    Ids.empty
    live
;;

(* Offsets of one fact from every op that stated it: ascending, none twice. *)
let sources_of stated =
  List.fold_left
    (fun sources (id, offsets) ->
       match offsets with
       | [] -> sources
       | _ :: _ ->
         let merged previous = List.sort_uniq Int.compare (previous @ offsets) in
         if List.mem_assoc id sources
         then
           List.map
             (fun (other, previous) ->
                if String.equal other id then other, merged previous else other, previous)
             sources
         else sources @ [ id, merged [] ])
    []
    stated
;;

let of_answer ~shown ~facts ~removed_since ~at ~trace_id (answer : Answer.t) =
  let current = ids_of facts in
  let by_id = List.fold_left (fun by_id fact -> By_id.add (memory_id fact) fact by_id) By_id.empty facts in
  let removed_since =
    List.fold_left
      (fun by_id (id, seq) -> By_id.add id seq by_id)
      By_id.empty
      removed_since
  in
  let screened, refused, (_ : Ids.t) =
    List.fold_left
      (fun (screened, refused, named_before) (number, op) ->
         match screen ~shown ~current ~removed_since ~named_before number op with
         | Ok (op, named) ->
           op :: screened, refused, List.fold_left (fun ids id -> Ids.add id ids) named_before named
         | Error why -> screened, (number, why, stated_fact op) :: refused, named_before)
      ([], [], Ids.empty)
      (List.mapi (fun number op -> number, op) answer.ops)
  in
  let screened = List.rev screened in
  (* Withdrawn ops only grow, so this ends after at most one round per op. *)
  let rec settle withdrawn =
    let live = List.filter (fun op -> not (Op_numbers.mem op.number withdrawn)) screened in
    let removal_of =
      List.fold_left
        (fun by_id op ->
           List.fold_left (fun by_id (id, removal) -> By_id.add id removal by_id) by_id op.removes)
        By_id.empty
        live
    in
    let kept = List.filter (fun fact -> not (By_id.mem (memory_id fact) removal_of)) facts in
    let kept_ids = ids_of kept in
    let spans = replaced_spans ~by_id live in
    let evidenced = evidenced live in
    let touched, added, (_ : Ids.t) =
      List.fold_left
        (fun (touched, added, added_ids) op ->
           match op.states with
           | None -> touched, added, added_ids
           | Some stating ->
             let id = fst (kept_and_units stating) in
             if Ids.mem id kept_ids
             then
               if Ids.mem id evidenced
               then Ids.add id touched, added, added_ids
               else touched, added, added_ids
             else (
               match stating with
               | Seen_again ((_ : string), (_ : int list)) ->
                 (* Only a live op of this answer removes a fact here, and that
                    op names it, so screening refused a seen of the same fact
                    as [Ref_used_twice]. A fact removed outside since the
                    question was refused there as [Removed_during_flight]. *)
                 touched, added, added_ids
               | New_claim ((_ : string), fact, (_ : int list)) ->
                 if Ids.mem id added_ids
                 then touched, added, added_ids
                 else (
                   (* Neither time is later than the commit. *)
                   let first_seen, last_seen =
                     match By_id.find_opt id spans, Ids.mem id evidenced with
                     | None, (true | false) -> at, at
                     | Some span, true -> Float.min span.earliest_first_seen at, at
                     | Some span, false ->
                       ( Float.min span.earliest_first_seen at
                       , Float.min span.latest_last_seen at )
                   in
                   ( touched
                   , observed_fact ~first_seen ~last_seen ~trace_id fact :: added
                   , Ids.add id added_ids ))))
        (Ids.empty, [], Ids.empty)
        live
    in
    let added = List.rev added in
    let supported, unsupported =
      Keeper_memory_os_support_core.maintain_supported_facts (kept @ added)
    in
    let supported_ids = ids_of supported in
    let lost_successor =
      List.filter
        (fun op ->
           match op.states with
           | Some stating -> not (Ids.mem (fst (kept_and_units stating)) supported_ids)
           | None -> false)
        live
    in
    match lost_successor with
    | _ :: _ ->
      settle
        (List.fold_left
           (fun withdrawn op -> Op_numbers.add op.number withdrawn)
           withdrawn
           lost_successor)
    | [] ->
      let removed_by_ops =
        List.filter_map
          (fun fact ->
             Option.map
               (fun removal -> fact, removal)
               (By_id.find_opt (memory_id fact) removal_of))
          facts
      in
      let removed_by_support =
        List.map
          (fun (lost : Keeper_memory_os_current_types.support_invalidation) ->
             lost.fact, Effects.Support_lost { missing = lost.missing_premise_ids })
          unsupported
      in
      let withdrawn_ops =
        List.filter_map
          (fun op ->
             if Op_numbers.mem op.number withdrawn
             then
               Some
                 ( op.number
                 , Effects.Successor_unsupported
                 , match op.states with
                   | Some (New_claim ((_ : string), fact, (_ : int list))) -> Some fact
                   | Some (Seen_again _) | None -> None )
             else None)
          screened
      in
      let effects : Effects.t =
        { added
        ; touched =
            List.filter_map
              (fun fact ->
                 let id = memory_id fact in
                 if Ids.mem id touched && Ids.mem id supported_ids then Some id else None)
              facts
        ; removed = removed_by_ops @ removed_by_support
        ; not_applied =
            List.sort
              (fun (left, (_ : Effects.why_not), (_ : Answer.new_fact option))
                (right, (_ : Effects.why_not), (_ : Answer.new_fact option)) ->
                 Int.compare left right)
              (refused @ withdrawn_ops)
        ; sources =
            sources_of
              (List.filter_map
                 (fun op ->
                    match op.states with
                    | Some stating ->
                      let id, offsets = kept_and_units stating in
                      if Ids.mem id supported_ids then Some (id, offsets) else None
                    | None -> None)
                 live)
        }
      in
      effects
  in
  let effects = settle Op_numbers.empty in
  { facts = Effects.apply ~at facts effects
  ; effects
  ; working_state =
      (match shown.memory, answer.working_state with
       | Some (_ : (string * string) list), Keep -> Kept
       | Some (_ : (string * string) list), Set text -> Replaced text
       | None, Keep -> Alone Untouched
       | None, Set (_ : string) -> Alone Not_valid_alone)
  }
;;
