open Keeper_memory_os_types
module Answer = Librarian_answer
module Effects = Librarian_effects
module Lifecycle = Librarian_lifecycle
module Ids = Set_util.StringSet
module By_id = Set_util.StringMap
module Op_numbers = Map.Make (Int)
module Offsets = Set.Make (Int)

let max_promotions_per_answer = 4
let max_promotion_claim_bytes = 512
let max_promotion_scope_bytes = 64
let max_promotion_facets = 8
let max_promotion_facet_bytes = 48

let has_control_char s =
  let len = String.length s in
  let rec loop i =
    if i >= len
    then false
    else (
      let code = Char.code (String.unsafe_get s i) in
      if code < 32 || code = 127 then true else loop (i + 1))
  in
  loop 0
;;

let validate_and_redact_promotion ~redact (promo : Lifecycle.world_promotion) =
  let scope = String.trim (Keeper_secret_redaction.redact_text redact promo.scope) in
  let claim = String.trim (Keeper_secret_redaction.redact_text redact promo.claim) in
  let facets =
    List.map (fun f -> String.trim (Keeper_secret_redaction.redact_text redact f)) promo.facets
  in
  let scope_ok =
    scope <> ""
    && String.length scope <= max_promotion_scope_bytes
    && not (has_control_char scope)
  in
  let claim_ok =
    claim <> ""
    && String.length claim <= max_promotion_claim_bytes
    && not (String.contains claim '\000')
  in
  let facets_ok =
    List.length facets <= max_promotion_facets
    && List.for_all
         (fun f ->
            f <> ""
            && String.length f <= max_promotion_facet_bytes
            && not (has_control_char f))
         facets
  in
  if scope_ok && claim_ok && facets_ok
  then Ok { promo with scope; claim; facets }
  else Error Effects.Promotion_refused
;;

type private_provenance =
  | Clean
  | Private_board of observation
  | Private_personal
  | Unresolved_premise

(* Fail-closed transitive provenance check: a promotion citing ANY fact whose
   direct or transitive derivation chain touches an [Observed (Board _)] post
   without explicit public-board clearance — or any unresolvable premise ID —
   is refused. *)
let inspect_private_provenance ~is_public_board_post ~fact_by_id source_ids =
  let rec walk visited unresolved = function
    | [] -> if unresolved then Unresolved_premise else Clean
    | id :: rest ->
      if Ids.mem id visited
      then walk visited unresolved rest
      else (
        let visited = Ids.add id visited in
        match By_id.find_opt id fact_by_id with
        | None -> walk visited true rest
        | Some (fact : fact) ->
          (match fact.basis with
           | Observed Transcript -> walk visited unresolved rest
           | Observed (Personal _) -> Private_personal
           | Observed (Board { post_id; _ } as board_src) ->
             if is_public_board_post post_id
             then walk visited unresolved rest
             else Private_board board_src
           | Derived derivations ->
             let premise_ids =
               List.concat_map (fun (d : derivation) -> d.premise_ids) derivations
             in
             walk visited unresolved (premise_ids @ rest)))
  in
  walk Ids.empty false source_ids
;;

let has_private_provenance ~is_public_board_post ~fact_by_id source_ids =
  match inspect_private_provenance ~is_public_board_post ~fact_by_id source_ids with
  | Clean -> false
  | Private_board _ | Private_personal | Unresolved_premise -> true
;;

type read =
  | Range of
      { memory : (string * string) list
      ; units : (string * int) list
      }
  | Item_alone of { units : (string * int) list }

type personal_source =
  { unit_name : string
  ; item_index : int
  ; observation : Keeper_external_attention.item
  }

type shown =
  | Read of read
  | Room of { memory : (string * string) list }
  | Molt of
      { memory : (string * string) list
      ; trigger : Lifecycle.molt_trigger
      }

let units_of = function
  | Read (Range { units; _ } | Item_alone { units }) -> units
  | Room _ | Molt _ -> []
;;

type working_state =
  | Kept
  | Replaced of string
  | Alone of Librarian_log.alone_working_state

type t =
  { facts : fact list
  ; effects : Effects.t
  ; working_state : working_state
  }

type stating =
  | New_claim of string * Answer.new_fact * int list
  | New_personal of fact * int
  | Seen_again of string * int list

let kept_and_units = function
  | New_claim (id, (_ : Answer.new_fact), offsets) | Seen_again (id, offsets) -> id, offsets
  | New_personal (fact, offset) -> memory_id fact, [ offset ]
;;

type screened =
  { number : int
  ; removes : (string * Effects.removal) list
  ; states : stating option
  ; promotion : Lifecycle.world_promotion option
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
  | Remember_personal _ | Drop _ | Seen _ | Synthesize _ | Molt _ | Promote_to_world _ -> None
;;

(* Refs whose facts are mutated/removed or confirmed — cannot be targeted twice
   by mutating ops in the same answer. Read-only premise citations in
   [Synthesize] and [Promote_to_world] are validated against [current] and
   [removed_since] without blocking sibling read-only synthesis/promotion. *)
let mutating_named_facts = function
  | Answer.Add _ | Remember_personal _ | Synthesize _ | Promote_to_world _ -> []
  | Drop { ref_; _ } | Revise { ref_; _ } | Seen { ref_; _ } -> [ ref_ ]
  | Merge { refs; _ } | Molt { refs; _ } -> refs
;;

let read_only_named_facts = function
  | Answer.Synthesize { refs; _ } | Promote_to_world { refs; _ } -> refs
  | Add _ | Remember_personal _ | Drop _ | Merge _ | Revise _ | Seen _ | Molt _ -> []
;;

let replaced ids ~by removal =
  List.filter_map (fun id -> if String.equal id by then None else Some (id, removal)) ids
;;

let screen
      ~is_public_board_post
      ~redact
      ~by_id
      ~promotions_accepted
      ~shown
      ~current
      ~removed_since
      ~named_before
      ~personal_sources
      ~at
      ~trace_id
      number
      op
  =
  let* table =
    match shown, op with
    | ( Read (Item_alone _)
      , (Answer.Drop _ | Merge _ | Revise _ | Seen _ | Synthesize _ | Molt _ | Promote_to_world _) )
      -> Error Effects.Not_valid_alone
    | Read (Item_alone _), (Add _ | Remember_personal _) -> Ok []
    | (Room _ | Molt _), (Add _ | Remember_personal _ | Seen _) -> Error Effects.Not_valid_in_room
    | ( (Room { memory } | Molt { memory; _ })
      , (Drop _ | Merge _ | Revise _ | Synthesize _ | Molt _ | Promote_to_world _) )
    | ( Read (Range { memory; _ })
      , (Add _ | Remember_personal _ | Drop _ | Merge _ | Revise _ | Seen _ | Synthesize _ | Molt _ | Promote_to_world _) )
      -> Ok memory
  in
  let* mutating_named = resolve_all table (mutating_named_facts op) ~missing:Effects.Unknown_ref in
  let* readonly_named = resolve_all table (read_only_named_facts op) ~missing:Effects.Unknown_ref in
  let all_named = mutating_named @ readonly_named in
  let stated_claim_id =
    match op with
    | Answer.Add fact | Merge { into = fact; _ } | Revise { into = fact; _ } ->
      Some (memory_id_of_claim fact.claim)
    | Synthesize { claim; _ } -> Some (memory_id_of_claim claim)
    | Remember_personal _ | Drop _ | Seen _ | Molt _ | Promote_to_world _ -> None
  in
  let* () =
    match
      List.find_map
        (fun id -> By_id.find_opt id removed_since)
        (all_named @ Option.to_list stated_claim_id)
    with
    | Some seq -> Error (Effects.Removed_during_flight { seq })
    | None -> Ok ()
  in
  let* () =
    if List.for_all (fun id -> Ids.mem id current) all_named
    then Ok ()
    else Error Effects.Unknown_ref
  in
  let* () =
    if List.exists (fun id -> Ids.mem id named_before) mutating_named
    then Error Effects.Ref_used_twice
    else Ok ()
  in
  let units names =
    resolve_all (units_of shown) names ~missing:Effects.Source_outside_question
  in
  let* states, promotion =
    match op with
    | Answer.Seen { ref_; from_units } ->
      let* seen = resolve_one table ref_ ~missing:Effects.Unknown_ref in
      let* offsets = units from_units in
      Ok (Some (Seen_again (seen, offsets)), None)
    | Add fact ->
      let* offsets = units fact.from_units in
      Ok (Some (New_claim (memory_id_of_claim fact.claim, fact, offsets)), None)
    | Remember_personal { unit_name; item_index; claim; category } ->
      let* offset = resolve_one (units_of shown) unit_name ~missing:Effects.Source_outside_question in
      let matches source =
        String.equal source.unit_name unit_name && Int.equal source.item_index item_index
      in
      (match List.filter matches personal_sources with
       | [ { observation; _ } ] ->
         let claim = Keeper_secret_redaction.redact_text redact claim in
         (match Librarian_direct.remember_personal ~claim ~category observation with
          | Some (Remember { claim; category; basis }) when String.trim claim <> "" ->
            let origin = { kind = Injected; trace_id } in
            let fact = { claim; category; first_seen = at; last_seen = at; origin; basis } in
            let id = memory_id fact in
            (match By_id.find_opt id removed_since with
             | Some seq -> Error (Effects.Removed_during_flight { seq })
             | None -> Ok (Some (New_personal (fact, offset)), None))
          | Some (Remember _ | Supersede _ | Retract _) | None -> Error Effects.Source_outside_question)
       | [] | _ :: _ :: _ -> Error Effects.Source_outside_question)
    | Merge { into = fact; _ } | Revise { into = fact; _ } ->
      let* offsets = units fact.from_units in
      let basis_already_private =
        match fact.basis with
        | Observed (Board { post_id; _ }) -> not (is_public_board_post post_id)
        | Observed Transcript -> false
        | Observed (Personal _) -> true
        | Derived derivations ->
          let premise_ids =
            List.concat_map (fun (d : derivation) -> d.premise_ids) derivations
          in
          has_private_provenance ~is_public_board_post ~fact_by_id:by_id premise_ids
      in
      let* preserved_fact =
        if basis_already_private
        then Ok fact
        else (
          match inspect_private_provenance ~is_public_board_post ~fact_by_id:by_id mutating_named with
          | Clean -> Ok fact
          | Private_board board_src -> Ok { fact with basis = Observed board_src }
          | Private_personal | Unresolved_premise -> Error Effects.Promotion_refused)
      in
      Ok (Some (New_claim (memory_id_of_claim preserved_fact.claim, preserved_fact, offsets)), None)
    | Synthesize { claim; category; rule_id; from_units; _ } ->
      let* offsets = units from_units in
      let derivation = normalize_derivation { rule_id; premise_ids = readonly_named } in
      let synth_fact : Answer.new_fact =
        { claim; category; basis = Derived [ derivation ]; from_units }
      in
      Ok (Some (New_claim (memory_id_of_claim claim, synth_fact, offsets)), None)
    | Promote_to_world { scope; claim; category; facets; _ } ->
      if promotions_accepted >= max_promotions_per_answer
      then Error Effects.Promotion_refused
      else if has_private_provenance ~is_public_board_post ~fact_by_id:by_id readonly_named
      then Error Effects.Promotion_refused
      else (
        let raw_promo : Lifecycle.world_promotion =
          { source_fact_ids = readonly_named; claim; category; facets; scope }
        in
        let* promo = validate_and_redact_promotion ~redact raw_promo in
        Ok (None, Some promo))
    | Drop _ | Molt _ -> Ok (None, None)
  in
  let removes =
    match op with
    | Answer.Add _ | Remember_personal _ | Seen _ | Synthesize _ | Promote_to_world _ -> []
    | Drop { reason; _ } -> List.map (fun id -> id, Effects.Dropped { reason }) mutating_named
    | Molt { reason; _ } -> List.map (fun id -> id, Effects.Molted { reason }) mutating_named
    | Merge { into; _ } ->
      let successor = memory_id_of_claim into.claim in
      replaced mutating_named ~by:successor (Effects.Merged_into successor)
    | Revise { into; _ } ->
      let successor = memory_id_of_claim into.claim in
      replaced mutating_named ~by:successor (Effects.Revised_into successor)
  in
  Ok ({ number; removes; states; promotion }, mutating_named)
;;

let normalize_basis = function
  | Observed _ as basis -> basis
  | Derived derivations -> Derived (List.map normalize_derivation derivations)
;;

let materialized_fact ~first_seen ~last_seen ~trace_id (fact : Answer.new_fact) : fact =
  { claim = fact.claim
  ; category = fact.category
  ; first_seen
  ; last_seen
  ; origin = { kind = Injected; trace_id }
  ; basis = normalize_basis fact.basis
  }
;;

type replaced_span =
  { earliest_first_seen : float
  ; latest_last_seen : float
  }

let replaced_spans ~by_id live =
  List.fold_left
    (fun spans op ->
       match op.states with
       | None | Some (Seen_again _ | New_personal _) -> spans
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

let reserve_personal_sources screened =
  let offsets, claims =
    List.fold_left (fun (offsets, claims) op ->
      match op.states with
      | Some (New_personal (fact, offset)) ->
        Offsets.add offset offsets, Ids.add (memory_id_of_claim fact.claim) claims
      | Some (New_claim _ | Seen_again _) | None -> offsets, claims)
      (Offsets.empty, Ids.empty) screened
  in
  if Offsets.is_empty offsets
  then screened, [], false
  else
    let reads_reserved offset = Offsets.mem offset offsets in
    let ordinary_write_uses_reserved_source op =
      match op.states with
      | Some (New_claim (id, _, cited)) ->
        Ids.mem id claims || List.exists reads_reserved cited
      | Some (Seen_again (_, cited)) -> List.exists reads_reserved cited
      | Some (New_personal _) -> false
      | None -> Option.is_some op.promotion || not (List.is_empty op.removes)
    in
    let accepted, refused = List.partition_map (fun op ->
      if ordinary_write_uses_reserved_source op
      then Either.Right (op.number, Effects.Source_reserved_for_personal_memory, None)
      else Either.Left op) screened
    in
    accepted, refused, true
;;

let of_answer
      ?(is_public_board_post = fun (_ : Board_types.Post_id.t) -> false)
      ?(redact = Keeper_secret_redaction.empty)
      ?(personal_sources = [])
      ~shown
      ~facts
      ~removed_since
      ~at
      ~trace_id
      (answer : Answer.t)
  =
  let current = ids_of facts in
  let by_id =
    List.fold_left (fun by_id fact -> By_id.add (memory_id fact) fact by_id) By_id.empty facts
  in
  let removed_since =
    List.fold_left
      (fun by_id (id, seq) -> By_id.add id seq by_id)
      By_id.empty
      removed_since
  in
  let screened, refused, (_ : Ids.t), (_ : int) =
    List.fold_left
      (fun (screened, refused, named_before, promotions_accepted) (number, op) ->
         match
           screen
             ~is_public_board_post
             ~redact
             ~by_id
             ~promotions_accepted
             ~shown
             ~current
             ~removed_since
             ~named_before
             ~personal_sources
             ~at
             ~trace_id
             number
             op
         with
         | Ok (screened_op, named) ->
           let promotions_accepted =
             if Option.is_some screened_op.promotion
             then promotions_accepted + 1
             else promotions_accepted
           in
           ( screened_op :: screened
           , refused
           , List.fold_left (fun ids id -> Ids.add id ids) named_before named
           , promotions_accepted )
         | Error why ->
           screened, (number, why, stated_fact op) :: refused, named_before, promotions_accepted)
      ([], [], Ids.empty, 0)
      (List.mapi (fun number op -> number, op) answer.ops)
  in
  let screened, reserved_refusals, uses_personal_sources =
    reserve_personal_sources (List.rev screened)
  in
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
           | Some (New_personal (fact, _)) -> touched, fact :: added, added_ids
           | Some ((New_claim _ | Seen_again _) as stating) ->
             let id = fst (kept_and_units stating) in
             if Ids.mem id kept_ids
             then
               if Ids.mem id evidenced
               then Ids.add id touched, added, added_ids
               else touched, added, added_ids
             else (
               match stating with
               | Seen_again _ | New_personal _ -> touched, added, added_ids
               | New_claim ((_ : string), fact, (_ : int list)) ->
                 if Ids.mem id added_ids
                 then touched, added, added_ids
                 else (
                   let first_seen, last_seen =
                     match By_id.find_opt id spans, Ids.mem id evidenced with
                     | None, (true | false) -> at, at
                     | Some span, true -> Float.min span.earliest_first_seen at, at
                     | Some span, false ->
                       ( Float.min span.earliest_first_seen at
                       , Float.min span.latest_last_seen at )
                   in
                   ( touched
                   , materialized_fact ~first_seen ~last_seen ~trace_id fact :: added
                   , Ids.add id added_ids ))))
        (Ids.empty, [], Ids.empty)
        live
    in
    let added = List.rev added in
    let supported, unsupported =
      Effects.add_facts kept added
      |> Keeper_memory_os_support_core.maintain_supported_facts
    in
    let supported_ids = ids_of supported in
    let supported_by_id =
      List.fold_left (fun acc fact -> By_id.add (memory_id fact) fact acc) By_id.empty supported
    in
    let lost_ops =
      List.filter_map
        (fun op ->
           let state_lost =
             match op.states with
             | Some stating -> not (Ids.mem (fst (kept_and_units stating)) supported_ids)
             | None -> false
           in
           if state_lost
           then Some (op.number, Effects.Successor_unsupported)
           else (
             match op.promotion with
             | None -> None
             | Some promo ->
               if not (List.for_all (fun id -> Ids.mem id supported_ids) promo.source_fact_ids)
               then Some (op.number, Effects.Successor_unsupported)
               else if
                 has_private_provenance
                   ~is_public_board_post
                   ~fact_by_id:supported_by_id
                   promo.source_fact_ids
               then Some (op.number, Effects.Promotion_refused)
               else None))
        live
    in
    match lost_ops with
    | _ :: _ ->
      settle
        (List.fold_left
           (fun withdrawn (op_num, why) -> Op_numbers.add op_num why withdrawn)
           withdrawn
           lost_ops)
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
             match Op_numbers.find_opt op.number withdrawn with
             | Some why ->
               Some
                 ( op.number
                 , why
                 , match op.states with
                   | Some (New_claim ((_ : string), fact, (_ : int list))) -> Some fact
                   | Some (Seen_again _ | New_personal _) | None -> None )
             | None -> None)
          screened
      in
      let promotions = List.filter_map (fun op -> op.promotion) live in
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
              (let rejected = refused @ reserved_refusals @ withdrawn_ops in
               if uses_personal_sources
               then List.map (fun (number, why, _) -> number, why, None) rejected
               else rejected)
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
        ; promotions
        }
      in
      effects
  in
  let effects = settle Op_numbers.empty in
  { facts = Effects.apply ~at facts effects
  ; effects
  ; working_state =
      (match shown, answer.working_state with
       | Read (Range _), Set _ when uses_personal_sources -> Kept
       | (Read (Range _) | Room _ | Molt _), Keep -> Kept
       | (Read (Range _) | Room _ | Molt _), Set text -> Replaced text
       | Read (Item_alone _), Keep -> Alone Untouched
       | Read (Item_alone _), Set (_ : string) -> Alone Not_valid_alone)
  }
;;
