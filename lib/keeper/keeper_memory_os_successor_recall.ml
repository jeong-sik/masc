open Keeper_memory_os_types
open Keeper_memory_os_current_types

module Revision_map = Map.Make (Int)
module Identity_set = Set_util.StringSet

type transition =
  { evidence : revision_evidence
  ; removed : fact list
  ; program : Keeper_memory_os_program_types.publication option
  ; recreated_memory_ids : string list
  }

type lineage =
  | Direct
  | Following of
      { original : fact
      ; path_rev : revision_evidence list
      ; program_steps_rev : successor_program_step list
      }

type frontier =
  { identity : string
  ; lineage : lineage
  }

type accumulated =
  { direct_rev : admission_recall_binding list
  ; candidates_rev : successor_recall_candidate list
  ; unresolved_rev : recall_unresolved list
  }

(* Reconstruct each transition's after-state from current identities. Processing
   a repeated revision only once preserves the prior reverse traversal: replay
   evidence must not undo the same additions/removals twice. *)
let after_states current transitions =
  let active = Identity_set.of_list (List.map memory_id current.facts) in
  let states, _ =
    List.fold_left
      (fun (states, active) row ->
        let revision = row.evidence.snapshot_revision in
        if Revision_map.mem revision states
        then states, active
        else
          let states = Revision_map.add revision active states in
          let before_additions =
            List.fold_left
              (fun ids id -> Identity_set.remove id ids)
              active
              row.evidence.added_memory_ids
          in
          let before =
            List.fold_left
              (fun ids id -> Identity_set.add id ids)
              before_additions
              row.evidence.removed_memory_ids
          in
          states, before)
      (Revision_map.empty, active)
      (List.rev transitions)
  in
  states
;;

let coverage ~current_revision ~born_revision history transitions =
  let rec validate expected acc = function
    | [] ->
      if expected = current_revision
      then Ok (List.rev acc)
      else Error (Missing_transition (expected + 1))
    | row :: rest ->
      let revision = row.evidence.snapshot_revision in
      if revision = expected
      then (
        match acc with
        | prior :: _ when prior = row -> validate expected acc rest
        | [] | _ :: _ -> Error (Invalid_transition revision))
      else if revision <> expected + 1
      then Error (Missing_transition (expected + 1))
      else validate revision (row :: acc) rest
  in
  if born_revision = current_revision
  then Ok []
  else
    match history with
    | Error detail -> Error (History_unavailable detail)
    | Ok _ ->
      List.filter
        (fun row -> row.evidence.snapshot_revision > born_revision)
        transitions
      |> validate born_revision []
;;

let follow row removed ?program_step lineage =
  let add_step steps = match program_step with
    | None -> steps
    | Some step -> step :: steps in
  match lineage with
  | Direct -> Following { original = removed; path_rev = [ row.evidence ];
      program_steps_rev = add_step [] }
  | Following { original; path_rev; program_steps_rev } ->
    let path_rev = match path_rev with
      | previous :: _ when previous = row.evidence -> path_rev
      | [] | _ :: _ -> row.evidence :: path_rev in
    Following { original; path_rev; program_steps_rev = add_step program_steps_rev }
;;

let advance_revision ~after_states ~binding (frontier, unresolved_rev) row =
  let note reason unresolved = { binding; reason } :: unresolved in
  let revision = row.evidence.snapshot_revision in
  let next_rev, unresolved_rev =
    List.fold_left
      (fun (next_rev, unresolved_rev) ({ identity; lineage } as path) ->
        if List.mem identity row.recreated_memory_ids
        then next_rev, note (Unrecorded_lineage revision) unresolved_rev
        else if not (List.mem identity row.evidence.removed_memory_ids)
           || List.mem identity row.evidence.added_memory_ids
        then path :: next_rev, unresolved_rev
        else
          match List.find_opt (fun fact -> memory_id fact = identity) row.removed with
          | None -> next_rev, note (Invalid_transition revision) unresolved_rev
          | Some removed ->
            (match row.evidence.revision_links with
             | None -> next_rev, note (Unrecorded_lineage revision) unresolved_rev
             | Some links ->
               let successors =
                 List.filter (fun (link : revision) -> link.superseded = identity) links
               in
               match successors with
               | [] -> next_rev, note (Retired_without_successor revision) unresolved_rev
               | _ :: _ ->
                 (* Every transition supplied to [advance] also contributed an
                    entry to [after_states]. *)
                 let after = Revision_map.find revision after_states in
                 List.fold_left
                   (fun (next_rev, unresolved_rev) (link : revision) ->
                     if Identity_set.mem identity after
                        || not (Identity_set.mem link.superseded_by after)
                     then next_rev, note (Invalid_transition revision) unresolved_rev
                     else
                       ( { identity = link.superseded_by
                         ; lineage = follow row removed lineage
                         }
                         :: next_rev
                       , unresolved_rev ))
                   (next_rev, unresolved_rev)
                   successors))
      ([], unresolved_rev)
      frontier
  in
  List.sort_uniq compare next_rev, unresolved_rev
;;

let advance_program ~binding row publication state =
  let module P = Keeper_memory_os_program_types in
  let revision = row.evidence.snapshot_revision in
  let transaction_id = publication.P.execution.program.transaction_id in
  let advance_stage (frontier, unresolved_rev) (stage : P.stage) =
    let note reason unresolved = { binding; reason } :: unresolved in
    let next_rev, unresolved_rev = List.fold_left
      (fun (next_rev, unresolved_rev) ({identity;lineage} as path) ->
        match List.find_opt (fun fact -> memory_id fact = identity) stage.before with
        | None -> next_rev, note (Invalid_transition revision) unresolved_rev
        | Some from_fact ->
          if List.exists (fun fact -> memory_id fact = identity) stage.after
          then path :: next_rev, unresolved_rev
          else
            let revisions = List.filter_map (fun (edge : revision) ->
              if edge.superseded = identity then Some (edge.superseded_by, Program_revision)
              else None) stage.revisions_applied in
            let absorptions = List.filter_map (fun (edge : absorbed_statement) ->
              if edge.absorbed = identity then Some (edge.into, Program_absorption)
              else None) stage.absorbed_applied in
            match revisions @ absorptions with
            | [] -> next_rev, note (Retired_without_successor revision) unresolved_rev
            | edges -> List.fold_left (fun (next_rev, unresolved_rev) (target,relation) ->
                match List.find_opt (fun fact -> memory_id fact = target) stage.after with
                | None -> next_rev, note (Invalid_transition revision) unresolved_rev
                | Some into_fact ->
                  let program_step : successor_program_step =
                    { program_revision=revision; transaction_id; stage_index=stage.index;
                      from_fact; into_fact; relation } in
                  {identity=target;lineage=follow row from_fact ~program_step lineage} :: next_rev,
                  unresolved_rev) (next_rev, unresolved_rev) edges)
      ([], unresolved_rev) frontier in
    List.sort_uniq compare next_rev, unresolved_rev in
  List.fold_left advance_stage state publication.execution.stages
;;

let advance ~after_states ~binding state row =
  match row.program with
  | None -> advance_revision ~after_states ~binding state row
  | Some publication -> advance_program ~binding row publication state
;;

let collect current ~binding ~born_revision acc { identity; lineage } =
  match List.find_opt (fun fact -> memory_id fact = identity) current.facts with
  | None ->
    { acc with
      unresolved_rev =
        { binding; reason = Invalid_transition current.revision } :: acc.unresolved_rev
    }
  | Some target ->
    (match lineage with
     | Direct -> { acc with direct_rev = binding :: acc.direct_rev }
     | Following { original; path_rev; program_steps_rev } ->
       { acc with
         candidates_rev =
           { binding
           ; born_revision
           ; original_target = original
           ; target
           ; path = List.rev path_rev
           ; program_steps = List.rev program_steps_rev
           }
           :: acc.candidates_rev
       })
;;

let project (current : t) bindings history =
  let transitions =
    match history with
    | Error _ -> []
    | Ok rows ->
      List.filter (fun row -> row.evidence.commit_effect = Some Rewritten) rows
  in
  let after_states = after_states current transitions in
  let project_binding acc (born_revision, (binding : admission_recall_binding)) =
    match coverage ~current_revision:current.revision ~born_revision history transitions with
    | Error reason ->
      { acc with unresolved_rev = { binding; reason } :: acc.unresolved_rev }
    | Ok rows ->
      let frontier, unresolved_rev =
        List.fold_left
          (advance ~after_states ~binding)
          ([ { identity = binding.target_memory_id; lineage = Direct } ], acc.unresolved_rev)
          rows
      in
      List.fold_left
        (collect current ~binding ~born_revision)
        { acc with unresolved_rev }
        frontier
  in
  let result =
    List.fold_left
      project_binding
      { direct_rev = []; candidates_rev = []; unresolved_rev = [] }
      bindings
  in
  { receipt_verification = Ok ()
  ; snapshot = Some current
  ; direct_bindings = List.rev result.direct_rev
  ; successor_candidates = List.rev result.candidates_rev
  ; unresolved = List.sort_uniq compare result.unresolved_rev
  }
;;
