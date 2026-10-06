type document = { path : string; source_text : string; source_revision : string }
type t = {
  base : document;
  text : string;
  current : document option;
  error : string option;
}

let open_document base = { base; text = base.source_text; current = None; error = None }
let edit text session = { session with text; error = None }
let failed error session = { session with error = Some error }

let observe current session =
  if String.equal current.path session.base.path then Ok { session with current = Some current }
  else Error "The current file belongs to a different configuration path; the draft is unchanged."

let adopt_current session =
  match session.current with
  | None -> Error "Read the current file before adopting its revision."
  | Some base -> Ok { session with base; current = None; error = None }

let replace_with_current session =
  match session.current with
  | None -> Error "Read the current file before replacing the draft."
  | Some current -> Ok (open_document current)
