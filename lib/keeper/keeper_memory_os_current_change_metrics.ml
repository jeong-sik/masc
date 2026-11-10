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

(* How [id] left [stage], if an applied absorption or revision took it. An
   absorption comes first, as in [classify]. *)
let exit_of (stage : Keeper_memory_os_program_types.stage) id =
  match
    List.find_opt
      (fun (statement : Keeper_memory_os_types.absorbed_statement) -> String.equal statement.absorbed id)
      stage.absorbed_applied
  with
  | Some statement -> Some (Absorbed, statement.into)
  | None ->
    List.find_opt
      (fun (revision : Keeper_memory_os_types.revision) -> String.equal revision.superseded id)
      stage.revisions_applied
    |> Option.map (fun (revision : Keeper_memory_os_types.revision) -> Superseded, revision.superseded_by)
;;

(* Each initial fact that left through an absorption or a revision, with the
   kind of that first exit and the ID that carries it after the last stage.
   In each later stage the carrier follows its own absorption or revision.
   The fold visits every stage once and moves a carrier at most one step per
   stage, so even a malformed proof cannot make it loop. *)
let carriers (execution : Keeper_memory_os_program_types.execution) =
  List.fold_left
    (fun carried stage ->
       let moved =
         Set_util.StringMap.map
           (fun (first, carrier) ->
              match exit_of stage carrier with
              | Some (_, next) -> first, next
              | None -> first, carrier)
           carried
       in
       List.fold_left
         (fun carried fact ->
            let id = Keeper_memory_os_types.memory_id fact in
            if Set_util.StringMap.mem id carried
            then carried
            else (
              match exit_of stage id with
              | Some first_exit -> Set_util.StringMap.add id first_exit carried
              | None -> carried))
         moved
         execution.initial_facts)
    Set_util.StringMap.empty
    execution.stages
;;

(* A program commits once, so it is counted as the one disposition it
   amounts to, from the facts it started from to the facts it left. An
   initial fact whose chain of absorptions and revisions ends in the final
   facts counts by the kind of its first exit; a chain that ends at a
   dropped claim leaves it dropped, as a disposition needs its replacing
   claim in the snapshot it commits. A fact one stage added and a later
   stage removed was never in a committed snapshot, so it counts nowhere. *)
let of_publication (publication : Keeper_memory_os_program_types.publication) =
  let execution = publication.execution in
  let final = ids execution.final_facts in
  let absorbed, revisions =
    Set_util.StringMap.fold
      (fun id (first, carrier) (absorbed, revisions) ->
         match Ids.mem carrier final, first with
         | false, (Absorbed | Superseded) -> absorbed, revisions
         | true, Absorbed ->
           { Keeper_memory_os_types.absorbed = id; into = carrier } :: absorbed, revisions
         | true, Superseded ->
           absorbed, { Keeper_memory_os_types.superseded = id; superseded_by = carrier } :: revisions)
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
