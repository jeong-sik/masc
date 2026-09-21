module P = Keeper_librarian_progress
module B = Keeper_turn_boundaries

type refusal =
  | Not_read_yet of { atom_count : int }
  | Unread_atoms of
      { end_atom : int
      ; atom_count : int
      }
  | Position_off_history of
      { end_atom : int
      ; atom_count : int
      }
  | Rewrite_empties_history

let refusal_to_string = function
  | Not_read_yet { atom_count } ->
    Printf.sprintf
      "the Librarian has not read this history yet (%d atoms unread)"
      atom_count
  | Unread_atoms { end_atom; atom_count } ->
    Printf.sprintf
      "the Librarian has read %d of %d atoms; the rest would be renumbered under it"
      end_atom
      atom_count
  | Position_off_history { end_atom; atom_count } ->
    Printf.sprintf
      "the Librarian read position (atom %d) does not describe this history (%d atoms)"
      end_atom
      atom_count
  | Rewrite_empties_history ->
    "the rewrite would leave no atom for the read position to stand on"
;;

type decision =
  | Allowed of P.t option
  | Refused of refusal

let ( let* ) = Result.bind

(* The end of a saved history: how many atoms it holds and the digest that
   opens the last one, or [None] for a history that holds no atom.
   [position_of_messages] describes saved messages, so the two positions a
   turn can report without a checkpoint do not arise here; naming them keeps
   the match total without a wildcard. *)
let endpoint messages =
  let* position = B.position_of_messages messages in
  match position with
  | B.Atom_history { end_atom; last_atom_digest } -> Ok (Some (end_atom, last_atom_digest))
  | B.Empty_atom_history -> Ok None
  | B.No_atom_history | B.Stale_noop ->
    Error "saved messages reported a position that only a running turn can report"
;;

let decide ~trace_id ~boundary_lines_present ~progress ~before ~after =
  let* before = endpoint before in
  let* after = endpoint after in
  let position_for_trace =
    match progress with
    | Some ({ P.position; boundary_lines_seen = _ } as progress)
      when String.equal position.P.trace_id trace_id -> Some progress
    | Some _ | None -> None
  in
  match before, position_for_trace with
  | None, _ ->
    (* Nothing is saved, so nothing can be renumbered. *)
    Ok (Allowed None)
  | Some (atom_count, _), None ->
    if boundary_lines_present || Option.is_some progress
    then Ok (Refused (Not_read_yet { atom_count }))
    else Ok (Allowed None)
  | Some (atom_count, digest), Some ({ P.position; boundary_lines_seen = _ } as progress) ->
    if position.P.end_atom = atom_count && String.equal position.P.last_atom_digest digest
    then (
      match after with
      | None -> Ok (Refused Rewrite_empties_history)
      | Some (end_atom, last_atom_digest) ->
        Ok
          (Allowed
             (Some
                { progress with
                  P.position = { position with P.end_atom; last_atom_digest }
                })))
    else if position.P.end_atom < atom_count
    then Ok (Refused (Unread_atoms { end_atom = position.P.end_atom; atom_count }))
    else Ok (Refused (Position_off_history { end_atom = position.P.end_atom; atom_count }))
;;
