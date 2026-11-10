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

let of_publication (publication : Keeper_memory_os_program_types.publication) =
  List.fold_left
    (fun total (stage : Keeper_memory_os_program_types.stage) ->
       let stage =
         classify
           ~before:stage.before
           ~after:stage.after
           ~absorbed:stage.absorbed_applied
           ~revisions:stage.revisions_applied
       in
       { added = total.added + stage.added
       ; absorbed = total.absorbed + stage.absorbed
       ; superseded = total.superseded + stage.superseded
       ; dropped = total.dropped + stage.dropped
       })
    { added = 0; absorbed = 0; superseded = 0; dropped = 0 }
    publication.execution.stages
;;

type 'a change_count =
  | Counted of
      { pass : Keeper_memory_commit_pass.t
      ; count : Keeper_memory_os_current_types.t -> 'a -> counts
      }
  | Not_counted

let record ~keeper_id change_count (snapshot : Keeper_memory_os_current_types.t) output =
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
      ];
    Otel_metric_store.set_gauge
      Keeper_metrics.(to_string MemoryFacts)
      ~labels:[ "keeper", keeper_id ]
      (float_of_int (List.length snapshot.facts));
    Otel_metric_store.set_gauge
      Keeper_metrics.(to_string MemorySnapshotBytes)
      ~labels:[ "keeper", keeper_id ]
      (float_of_int (String.length (Keeper_memory_os_render.render_facts snapshot.facts)))
;;
