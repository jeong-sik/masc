open Keeper_memory_os_types
open Keeper_memory_os_current_types
open Result.Syntax

module Identity_map = Map.Make (String)

let fact_payload fact =
  fact_to_json fact |> Yojson.Safe.to_string
;;

let derivations_supported current_ids derivations =
  List.exists
    (fun derivation ->
       List.for_all
         (fun premise_id -> Set_util.StringSet.mem premise_id current_ids)
         derivation.premise_ids)
    derivations
;;

let missing_premises_for current_ids derivations =
  List.fold_left
    (fun missing derivation ->
       List.fold_left
         (fun missing premise_id ->
            if Set_util.StringSet.mem premise_id current_ids
            then missing
            else Set_util.StringSet.add premise_id missing)
         missing
         derivation.premise_ids)
    Set_util.StringSet.empty
    derivations
  |> Set_util.StringSet.elements
;;

let support_closure_ids facts =
  let rules =
    List.concat_map
      (fun fact ->
         match fact.basis with
         | Observed _ -> []
         | Derived derivations ->
           List.map
             (fun derivation -> memory_id fact, derivation.premise_ids)
             derivations)
      facts
    |> Array.of_list
  in
  let remaining = Array.map (fun (_, premise_ids) -> List.length premise_ids) rules in
  let dependents = Hashtbl.create (Array.length rules) in
  Array.iteri
    (fun rule_index (_, premise_ids) ->
       List.iter
         (fun premise_id ->
            let current = Hashtbl.find_opt dependents premise_id |> Option.value ~default:[] in
            Hashtbl.replace dependents premise_id (rule_index :: current))
         premise_ids)
    rules;
  let current = ref Set_util.StringSet.empty in
  let pending = Queue.create () in
  let activate identity =
    if not (Set_util.StringSet.mem identity !current)
    then (
      current := Set_util.StringSet.add identity !current;
      Queue.add identity pending)
  in
  List.iter
    (fun fact ->
       match fact.basis with
       | Observed _ -> activate (memory_id fact)
       | Derived _ -> ())
    facts;
  while not (Queue.is_empty pending) do
    let identity = Queue.take pending in
    Hashtbl.find_opt dependents identity
    |> Option.value ~default:[]
    |> List.iter (fun rule_index ->
      remaining.(rule_index) <- remaining.(rule_index) - 1;
      if remaining.(rule_index) = 0
      then activate (fst rules.(rule_index)))
  done;
  !current
;;

let map_facts facts =
  let rec loop map = function
    | [] -> Ok map
    | fact :: rest ->
      let identity = memory_id fact in
      if Identity_map.mem identity map
      then Error (Printf.sprintf "duplicate Memory OS fact identity: %s" identity)
      else loop (Identity_map.add identity fact map) rest
  in
  loop Identity_map.empty facts
;;

let compute_change ~previous ~next ~invalidated =
  let* previous_by_id = map_facts previous in
  let* next_by_id = map_facts next in
  let added_rev, retained =
    List.fold_left
      (fun (added_rev, retained) next_fact ->
         let identity = memory_id next_fact in
         match Identity_map.find_opt identity previous_by_id with
         | Some previous_fact
           when String.equal (fact_payload previous_fact) (fact_payload next_fact) ->
           added_rev, retained + 1
         | Some _ | None -> next_fact :: added_rev, retained)
      ([], 0)
      next
  in
  let removed_rev =
    List.fold_left
      (fun removed_rev previous_fact ->
         let identity = memory_id previous_fact in
         match Identity_map.find_opt identity next_by_id with
         | Some next_fact
           when String.equal (fact_payload previous_fact) (fact_payload next_fact) ->
           removed_rev
         | Some _ | None -> previous_fact :: removed_rev)
      []
      previous
  in
  Ok
    { added = List.rev added_rev
    ; removed = List.rev removed_rev
    ; retained
    ; invalidated
    }
;;

(* Truth maintenance over positive support sets. Observations seed a worklist;
   each newly supported identity advances only the derivations that name it.
   A derived fact activates when one whole derivation reaches zero missing
   premises. Unsupported cycles never enter the worklist. *)
let maintain_supported_facts facts =
  let current_ids = support_closure_ids facts in
  let current_rev, invalidated_rev =
    List.fold_left
      (fun (current_rev, invalidated_rev) fact ->
         if Set_util.StringSet.mem (memory_id fact) current_ids
         then fact :: current_rev, invalidated_rev
         else
           match fact.basis with
           | Observed _ -> fact :: current_rev, invalidated_rev
           | Derived derivations ->
             let missing_premise_ids =
               missing_premises_for current_ids derivations
             in
             current_rev, { fact; missing_premise_ids } :: invalidated_rev)
      ([], [])
      facts
  in
  List.rev current_rev, List.rev invalidated_rev
;;

(* The same claim bytes seen again: an observation outranks a derivation, and
   a Board reference outranks the transcript because it names a source the
   transcript cannot. Two Board references keep the first unless the second
   names a comment under the same post the first only named as a post; the
   second reading otherwise adds nothing the first did not. *)
let merge_observation existing incoming =
  match existing, incoming with
  | Board { post_id; comment_id = None }, Board { post_id = incoming_post; comment_id = Some _ }
    when Board_types.Post_id.to_string post_id
         = Board_types.Post_id.to_string incoming_post ->
    incoming
  | Board _, (Board _ | Transcript) -> existing
  | Transcript, Board _ -> incoming
  | Transcript, Transcript -> Transcript
;;

let merge_basis existing incoming =
  match existing, incoming with
  | Observed existing, Observed incoming ->
    Observed (merge_observation existing incoming)
  | Observed existing, Derived _ -> Observed existing
  | Derived _, Observed incoming -> Observed incoming
  | Derived existing, Derived incoming ->
    let derivations =
      List.fold_left
        (fun derivations candidate ->
           if
             List.exists
               (fun current -> String.equal current.rule_id candidate.rule_id)
               derivations
           then
             List.map
               (fun current ->
                  if String.equal current.rule_id candidate.rule_id
                  then candidate
                  else current)
               derivations
           else derivations @ [ candidate ])
        existing
        incoming
    in
    Derived derivations
;;

let make_snapshot_from_maintained
      ~previous
      ~now
      ~source
      ~facts
      ~invalidated
      ()
  =
  let previous_facts, revision =
    match previous with
    | None -> [], 1
    | Some snapshot -> snapshot.facts, snapshot.revision + 1
  in
  let+ change = compute_change ~previous:previous_facts ~next:facts ~invalidated in
  { revision
  ; updated_at = now
  ; source
  ; facts
  ; change
  }
;;

let make_snapshot
      ~previous
      ~now
      ~source
      ~facts
      ()
  =
  let facts, invalidated = maintain_supported_facts facts in
  make_snapshot_from_maintained
    ~previous
    ~now
    ~source
    ~facts
    ~invalidated
    ()
;;

let insert_or_reobserve current_facts (incoming : Keeper_memory_os_types.fact) =
  let incoming_identity = memory_id incoming in
  let found = ref false in
  let facts =
    List.map
      (fun existing ->
         if String.equal (memory_id existing) incoming_identity
         then (
           found := true;
           (* Byte-identical re-observation of an existing row. The exact
              claim bytes were already on file, so this is not a new fact:
              preserve the authoritative insertion time and the original
              origin (an injected copy re-observed must not repaint an
              authored row) and refresh the observation time. Nothing is
              counted: seeing the same bytes again says nothing about the
              fact's worth (RFC-0418). *)
           { incoming with
             first_seen = existing.first_seen
           ; last_seen = Float.max existing.last_seen incoming.last_seen
           ; origin = existing.origin
           ; basis = merge_basis existing.basis incoming.basis
           })
         else existing)
      current_facts
  in
  if !found then facts else facts @ [ incoming ]
;;

let upsert_snapshot ~previous ~now ~source incoming =
    let current_facts =
      match previous with
      | None -> []
      | Some snapshot -> snapshot.facts
    in
    let current_ids =
      List.fold_left
        (fun ids fact -> Set_util.StringSet.add (memory_id fact) ids)
        Set_util.StringSet.empty
        current_facts
    in
    let* () =
      match incoming.basis with
      | Observed _ -> Ok ()
      | Derived derivations when derivations_supported current_ids derivations ->
        Ok ()
      | Derived derivations ->
        Error
          (Unsupported_derivation
             { fact = incoming
             ; missing_premise_ids = missing_premises_for current_ids derivations
             })
    in
    let facts = insert_or_reobserve current_facts incoming in
    let facts, invalidated = maintain_supported_facts facts in
    let incoming_identity = memory_id incoming in
    match
      List.find_opt
        (fun invalidation ->
           String.equal (memory_id invalidation.fact) incoming_identity)
        invalidated
    with
    | Some invalidation -> Error (Unsupported_derivation invalidation)
    | None ->
      make_snapshot_from_maintained
        ~previous
        ~now
        ~source
        ~facts
        ~invalidated
        ()
      |> Result.map_error (fun detail -> Upsert_persistence_failed detail)
;;
