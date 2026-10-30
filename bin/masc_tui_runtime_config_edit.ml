type document = { path : string; source_text : string; source_revision : string }
type t = {
  draft_owner : unit ref;
  basis_owner : unit ref;
  current_read_floor : int option;
  basis_read_generation : int option;
  current_read_generation : int option;
  base : document;
  text : string;
  current : document option;
  error : string option;
}

let open_document ?read_generation base = { draft_owner=ref (); basis_owner=ref (); current_read_floor=None;
  basis_read_generation=read_generation; current_read_generation=None;
  base; text = base.source_text; current = None; error = None }
let edit text session = { session with draft_owner=ref (); text; error = None }
let same_draft left right = left.draft_owner == right.draft_owner
let same_basis left right = left.basis_owner == right.basis_owner
let failed error session = { session with error = Some error }
let unconfirmed ~after_read error session =
  let after_read = match session.current_read_floor with
    | None -> after_read | Some previous -> max previous after_read in
  { session with current=None; current_read_generation=None;
    current_read_floor=Some after_read; error=Some error }

let observe ?read_generation current session =
  if not (String.equal current.path session.base.path) then
    Error "The current file belongs to a different configuration path; the draft is unchanged."
  else match session.current_read_floor, read_generation with
    | Some floor, Some generation when generation > floor ->
        Ok {session with current=Some current; current_read_generation=read_generation}
    | Some _, (None | Some _) -> Error "This read began before the uncertain save outcome; waiting for revalidation."
    | None, (None | Some _) ->
        Ok { session with current = Some current; current_read_generation=read_generation }

let adopt_current session =
  match session.current with
  | None -> Error "Read the current file before adopting its revision."
  | Some base -> Ok { session with draft_owner=ref (); basis_owner=ref (); current_read_floor=None;
      basis_read_generation=session.current_read_generation; current_read_generation=None;
      base; current = None; error = None }

let replace_with_current session =
  match session.current with
  | None -> Error "Read the current file before replacing the draft."
  | Some current -> Ok (open_document ?read_generation:session.current_read_generation current)
