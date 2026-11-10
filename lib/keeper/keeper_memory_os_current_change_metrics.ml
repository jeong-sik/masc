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

(* A program commits once, so it is counted once: from the facts it started
   from to the facts it left, with the absorptions and revisions of all its
   stages. Like a disposition, which needs the replacing claim in the
   snapshot it commits, an absorption or revision counts only when the claim
   it went into is in the final facts; a later stage that dropped that claim
   leaves the initial fact dropped. A fact one stage added and a later stage
   removed was never in a committed snapshot, so it counts nowhere. *)
let of_publication (publication : Keeper_memory_os_program_types.publication) =
  let execution = publication.execution in
  let final = ids execution.final_facts in
  let applied select = List.concat_map select execution.stages in
  classify
    ~before:execution.initial_facts
    ~after:execution.final_facts
    ~absorbed:
      (applied (fun (stage : Keeper_memory_os_program_types.stage) -> stage.absorbed_applied)
       |> List.filter (fun (statement : Keeper_memory_os_types.absorbed_statement) ->
         Ids.mem statement.into final))
    ~revisions:
      (applied (fun (stage : Keeper_memory_os_program_types.stage) -> stage.revisions_applied)
       |> List.filter (fun (revision : Keeper_memory_os_types.revision) ->
         Ids.mem revision.superseded_by final))
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
