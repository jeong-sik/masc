module Live = Artifact_draft_live
module Draft = Artifact_draft
type active = { turn_ref : Ids.Turn_ref.t; mutable session : (Draft.target * Live.session) option }
type state = Ready | Active of active | Ended
type t = { base_path : string; keeper : string; mutex : Mutex.t; mutable state : state }
type error = Closed | Owner_mismatch | Turn_mismatch
let create ~base_path ~keeper = { base_path; keeper; mutex = Mutex.create (); state = Ready }
let admit scope ~base_path ~keeper ~turn_ref = Mutex.protect scope.mutex (fun () ->
  if scope.base_path <> base_path || scope.keeper <> keeper then Error Owner_mismatch
  else match scope.state with
  | Ended -> Error Closed
  | Active active when not (Ids.Turn_ref.equal active.turn_ref turn_ref) -> Error Turn_mismatch
  | Active _ -> Ok ()
  | Ready -> scope.state <- Active { turn_ref; session = None }; Ok ())
let present scope ~turn_ref (view : Artifact_draft_store.view) = Mutex.protect scope.mutex (fun () ->
  match scope.state with
  | Ready | Ended -> Error Closed
  | Active active when not (Ids.Turn_ref.equal active.turn_ref turn_ref) -> Error Turn_mismatch
  | Active active ->
    let target = view.draft.target in
    let session = match active.session with
      | Some (previous, session) when previous = target -> session
      | previous ->
        Option.iter (fun (_, session) -> Live.leave session) previous;
        let session = Live.join ~base_path:scope.base_path ~actor:scope.keeper ~source:(Live.Keeper_turn turn_ref) ~target in
        active.session <- Some (target, session); session in
    Live.publish ~base_path:scope.base_path ~draft:view.draft ~content:view.content;
    Live.position session (Option.map (fun (selection, _, _) -> selection.Draft.position) view.selection)
    |> Result.map_error (fun _ -> Closed))
let leave scope ~target = Mutex.protect scope.mutex (fun () -> match scope.state with
  | Ready | Ended -> ()
  | Active active -> match active.session with
    | Some (current, session) when current = target -> Live.leave session; active.session <- None
    | None | Some _ -> ())
let close scope = Mutex.protect scope.mutex (fun () ->
  (match scope.state with Ready | Ended -> () | Active active -> Option.iter (fun (_, session) -> Live.leave session) active.session);
  scope.state <- Ended)
