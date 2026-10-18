open Keeper_memory_os_types
module Ids = Set_util.StringSet
module Destinations = Set_util.StringMap

type t =
  { facts : fact list
  ; claims_refused : fact list
  ; absorbed_into : string Destinations.t
  }

let ids_of facts =
  List.fold_left (fun ids fact -> Ids.add (memory_id fact) ids) Ids.empty facts

let plan ~current ~dropped ~absorbed ~revisions ~new_claims =
  let current_ids = ids_of current in
  let held identity = Ids.mem identity current_ids in
  (* A Keeper may have removed the source since the provider read it. Do not
     carry that content into a new successor, and only retire a revised source
     when one successor is held or accepted (#38122). Absorption similarly
     requires a held or accepted candidate destination (#38186); support
     maintenance still has to decide which candidate facts survive. *)
  let continues_a_removed_memory fact =
    let identity = memory_id fact in
    (not (held identity))
    && (List.exists
          (fun (revision : revision) ->
             String.equal revision.superseded_by identity
             && not (held revision.superseded))
          revisions
        || List.exists
             (fun (statement : absorbed_statement) ->
                String.equal statement.into identity && not (held statement.absorbed))
             absorbed)
  in
  let claims_refused, claims_accepted =
    List.partition continues_a_removed_memory new_claims
  in
  let accepted_ids = ids_of claims_accepted in
  let retired =
    List.fold_left
      (fun ids (statement : dropped_statement) -> Ids.add statement.memory_id ids)
      Ids.empty dropped
    |> Ids.filter (fun identity ->
      let successors =
        List.filter (fun (revision : revision) -> String.equal revision.superseded identity)
          revisions
      in
      match successors with
      | [] -> true
      | _ :: _ ->
        List.exists
          (fun (revision : revision) ->
             held revision.superseded_by || Ids.mem revision.superseded_by accepted_ids)
          successors)
  in
  let absorbed_into =
    List.fold_left
      (fun into_of (statement : absorbed_statement) ->
         if held statement.into || Ids.mem statement.into accepted_ids
         then Destinations.add statement.absorbed statement.into into_of
         else into_of)
      Destinations.empty absorbed
  in
  let kept =
    List.filter
      (fun fact ->
         let identity = memory_id fact in
         not (Ids.mem identity retired || Destinations.mem identity absorbed_into))
      current
  in
  let added, _ =
    List.fold_left
      (fun (acc, seen) fact ->
         let identity = memory_id fact in
         if Ids.mem identity seen then acc, seen
         else fact :: acc, Ids.add identity seen)
      ([], ids_of kept) claims_accepted
  in
  { facts = kept @ List.rev added; claims_refused; absorbed_into }
