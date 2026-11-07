type owner = { id : string; source_path : string; revision : string }

type release = Released | Not_released

type 'runtime persistence =
  | Ephemeral
  | Persistent of { package_id : string; runtime : 'runtime }
  | Package_unreadable

type identity = Minted of { instance_id : string; minted_ms : int64 } | Unminted

type ('visibility, 'runtime) binding = {
  identity : identity;
  release : release;
  owner : owner option;
  visibility : 'visibility;
  persistence : 'runtime persistence;
}

type count = {
  eligible : string list;
  protected : int;
  diverging_bindings : int;
  diverging_groups : int;
}

type group = Revision of string * string * string | Persistent_state of string * string

type verdict = Eligible of string | Protected | Diverging of group

(* The instance id of a binding that can represent its group or be eligible. *)
let usable_id ~now_ms binding =
  match binding.identity with
  | Minted { instance_id; minted_ms } when Int64.compare minted_ms now_ms <= 0 -> Some instance_id
  | Minted _ | Unminted -> None

let persistent_group binding =
  match binding.owner, binding.persistence with
  | Some o, Persistent { package_id; _ } -> Some (Persistent_state (o.id, package_id))
  | None, (Ephemeral | Persistent _ | Package_unreadable)
  | Some _, (Ephemeral | Package_unreadable) -> None

let revision_group binding =
  Option.map (fun (o : owner) -> Revision (o.id, o.source_path, o.revision)) binding.owner

(* Each group's representative: the greatest usable instance id. UUIDv7 ids
   sort by their time. *)
let representatives ~now_ms group_of bindings =
  List.fold_left
    (fun reps binding ->
      match group_of binding, usable_id ~now_ms binding with
      | Some group, Some id -> (
          match List.assoc_opt group reps with
          | Some (best, _) when String.compare best id >= 0 -> reps
          | Some _ | None -> (group, (id, binding)) :: List.remove_assoc group reps)
      | Some _, None | None, (Some _ | None) -> reps)
    [] bindings

let plan ~now_ms ~live ~owner_faulted bindings =
  let revisions = representatives ~now_ms revision_group bindings in
  let persistents = representatives ~now_ms persistent_group bindings in
  (* Condition 5 of section 4.1, for a binding that passed conditions 1 to 4. *)
  let persistent_verdict (o : owner) id binding =
    match binding.persistence with
    | Ephemeral -> Eligible id
    | Package_unreadable -> Protected
    | Persistent { package_id; runtime } -> (
        let group = Persistent_state (o.id, package_id) in
        match List.assoc_opt group persistents with
        | None -> Protected
        | Some (rep_id, _) when String.equal rep_id id -> Protected
        | Some (_, rep) -> (
            match rep.persistence with
            | Persistent { runtime = rep_runtime; _ } when rep_runtime = runtime -> Eligible id
            | Persistent _ | Ephemeral | Package_unreadable -> Diverging group))
  in
  let verdict binding =
    match binding.release, binding.owner, usable_id ~now_ms binding with
    | Not_released, (None | Some _), (None | Some _)
    | Released, None, (None | Some _)
    | Released, Some _, None -> Protected
    | Released, Some o, Some id -> (
        if live id || owner_faulted o then Protected
        else
          let group = Revision (o.id, o.source_path, o.revision) in
          match List.assoc_opt group revisions with
          | None -> Protected
          | Some (rep_id, _) when String.equal rep_id id -> Protected
          | Some (_, rep) ->
              if rep.visibility = binding.visibility then persistent_verdict o id binding
              else Diverging group)
  in
  let eligible, protected, diverging, groups =
    List.fold_left
      (fun (eligible, protected, diverging, groups) binding ->
        match verdict binding with
        | Eligible id -> (id :: eligible, protected, diverging, groups)
        | Protected -> (eligible, protected + 1, diverging, groups)
        | Diverging group ->
            ( eligible,
              protected + 1,
              diverging + 1,
              if List.mem group groups then groups else group :: groups ))
      ([], 0, 0, []) bindings
  in
  {
    eligible = List.rev eligible;
    protected;
    diverging_bindings = diverging;
    diverging_groups = List.length groups;
  }

type claims = Claimed of string list | Unattributed

let unclaimed ~folder_key ~instance_key claims folders =
  match claims with
  | Unattributed -> []
  | Claimed ids ->
      let claimed = Hashtbl.create (List.length ids) in
      List.iter (fun id -> Hashtbl.replace claimed (instance_key id) ()) ids;
      List.filter (fun folder -> not (Hashtbl.mem claimed (folder_key folder))) folders
