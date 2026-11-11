module Ids = Set_util.StringSet

type counts =
  { added : int
  ; absorbed : int
  ; superseded : int
  ; dropped : int
  }

let ids facts = Ids.of_list (List.map Keeper_memory_os_types.memory_id facts)

(* The IDs that left are split three ways: an applied absorption, then an
   applied revision, then everything else. Only an ID that left can be
   absorbed or superseded, so the four counts never overlap. *)
let classify ~before ~after ~absorbed ~revisions =
  let before = ids before
  and after = ids after in
  let left = Ids.diff before after in
  let absorbed =
    List.map (fun (statement : Keeper_memory_os_types.absorbed_statement) -> statement.absorbed) absorbed
    |> Ids.of_list
    |> Ids.inter left
  in
  let superseded =
    Ids.diff
      (List.map (fun (revision : Keeper_memory_os_types.revision) -> revision.superseded) revisions
       |> Ids.of_list
       |> Ids.inter left)
      absorbed
  in
  { added = Ids.cardinal (Ids.diff after before)
  ; absorbed = Ids.cardinal absorbed
  ; superseded = Ids.cardinal superseded
  ; dropped = Ids.cardinal (Ids.diff (Ids.diff left absorbed) superseded)
  }
;;

(* [change.added] holds every new or rewritten fact and [change.removed] every
   gone or rewritten one, so their IDs differ exactly by the IDs that arrived
   and the IDs that left. *)
let of_change ~absorbed ~revisions (change : Keeper_memory_os_current_types.change) =
  classify ~before:change.removed ~after:change.added ~absorbed ~revisions
;;

type exit_kind =
  | Absorbed
  | Superseded

(* How [id] left [stage], with every applied destination. An absorption
   comes first, as in [classify]. *)
let exit_of (stage : Keeper_memory_os_program_types.stage) id =
  let absorbed =
    List.fold_left
      (fun into (statement : Keeper_memory_os_types.absorbed_statement) ->
         if String.equal statement.absorbed id then Ids.add statement.into into else into)
      Ids.empty stage.absorbed_applied
  in
  if not (Ids.is_empty absorbed) then Some (Absorbed, absorbed)
  else
    let revised =
      List.fold_left
        (fun into (revision : Keeper_memory_os_types.revision) ->
           if String.equal revision.superseded id then Ids.add revision.superseded_by into else into)
        Ids.empty stage.revisions_applied
    in
    if Ids.is_empty revised then None else Some (Superseded, revised)
;;

type carrier =
  { first_exit : exit_kind option
  ; live : Ids.t
  }

(* Every initial fact starts with its own carrier. Each stage moves every
   live branch once and removes carriers absent from that stage's result.
   An empty set stays empty, so reintroducing an ID cannot revive a dead
   branch. Splits retain all successors and convergence deduplicates them.
   The bounded stage fold does not recursively chase links within a stage. *)
let carriers (execution : Keeper_memory_os_program_types.execution) =
  let initial =
    List.fold_left
      (fun carried fact ->
         let id = Keeper_memory_os_types.memory_id fact in
         Set_util.StringMap.add id { first_exit = None; live = Ids.singleton id } carried)
      Set_util.StringMap.empty execution.initial_facts
  in
  List.fold_left
    (fun carried (stage : Keeper_memory_os_program_types.stage) ->
       let after = ids stage.after in
       Set_util.StringMap.map
         (fun (carrier : carrier) ->
            let first_exit, live =
              Ids.fold
                (fun id (first, live) ->
                   match exit_of stage id with
                   | None -> first, Ids.add id live
                   | Some (kind, next) ->
                     let first = match first with None -> Some kind | Some _ -> first in
                     first, Ids.union live next)
                carrier.live (carrier.first_exit, Ids.empty)
            in
            { first_exit; live = Ids.inter live after })
         carried)
    initial execution.stages
;;

(* A program commits once, so it is counted as the one disposition it
   amounts to, from the facts it started from to the facts it left. An
   initial fact with a surviving absorption or revision branch counts once
   by its first exit. If every branch dies, it is dropped. A fact one stage
   added and a later stage removed was never in a committed snapshot, so it
   counts nowhere. *)
let of_publication (publication : Keeper_memory_os_program_types.publication) =
  let execution = publication.execution in
  let final = ids execution.final_facts in
  let absorbed, revisions =
    Set_util.StringMap.fold
      (fun id (carried : carrier) (absorbed, revisions) ->
         (* Counts are per original ID, so one final witness is sufficient. *)
         match Ids.choose_opt (Ids.inter carried.live final) with
         | None -> absorbed, revisions
         | Some carrier ->
           (match carried.first_exit with
            | None -> absorbed, revisions
            | Some Absorbed ->
              { Keeper_memory_os_types.absorbed = id; into = carrier } :: absorbed, revisions
            | Some Superseded ->
              absorbed, { Keeper_memory_os_types.superseded = id; superseded_by = carrier } :: revisions))
      (carriers execution)
      ([], [])
  in
  classify ~before:execution.initial_facts ~after:execution.final_facts ~absorbed ~revisions
;;

type 'a change_count =
  | Counted of
      { pass : Keeper_memory_commit_pass.t
      ; count : Keeper_memory_os_current_types.t -> 'a -> counts
      }
  | Not_counted

let set_gauges ~keeper_id change_count (snapshot : Keeper_memory_os_current_types.t) =
  match change_count with
  | Not_counted -> ()
  | Counted _ ->
    Otel_metric_store.set_gauge
      Keeper_metrics.(to_string MemoryFacts)
      ~labels:[ "keeper", keeper_id ]
      (float_of_int (List.length snapshot.facts));
    Otel_metric_store.set_gauge
      Keeper_metrics.(to_string MemorySnapshotBytes)
      ~labels:[ "keeper", keeper_id ]
      (float_of_int (String.length (Keeper_memory_os_render.render_facts snapshot.facts)))
;;

let count_changes ~keeper_id change_count (snapshot : Keeper_memory_os_current_types.t) output =
  match change_count with
  | Not_counted -> ()
  | Counted { pass; count } ->
    let counts = count snapshot output in
    let pass = Keeper_memory_commit_pass.to_label pass in
    List.iter
      (fun (change, value) ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string MemoryChanges)
           ~labels:[ "keeper", keeper_id; "pass", pass; "change", change ]
           ~delta:(float_of_int value)
           ())
      [ "added", counts.added
      ; "absorbed", counts.absorbed
      ; "superseded", counts.superseded
      ; "dropped", counts.dropped
      ]
;;
