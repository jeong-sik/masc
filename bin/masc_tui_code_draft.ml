type scope = Code_scope_project | Code_scope_keeper of string | Code_scope_repo of string
type address = { base_path : string; masc_root : string; scope : scope; path : string }
type source = { text : string; revision : string }
type ticket = unit ref
type review_reason = Conflict of string | Uncertain of string
type phase = Editable | Saving of ticket | Rejected of string
  | Needs_review of review_reason * source option
type t = { identity : unit ref; address : address; base : source; text : string; phase : phase }
let address draft = draft.address
let base draft = draft.base
let text draft = draft.text
let phase draft = draft.phase
let same_draft a b = a.identity == b.identity
let equal_address a b = a = b
type ending = Empty_source | Final_lf | Final_crlf | No_final_newline
let ending text =
  let length = String.length text in
  if length = 0 then Empty_source
  else if text.[length - 1] <> '\n' then No_final_newline
  else if length > 1 && text.[length - 2] = '\r' then Final_crlf
  else Final_lf
let create ~address ~source = { identity=ref (); address; base = source; text = source.text; phase = Editable }
let can_discard draft = match draft.phase with
  | Saving _ -> false | Editable | Rejected _ | Needs_review _ -> true
let edit text draft = match draft.phase with
  | Saving _ -> Error "Wait for the submitted save before editing this draft"
  | Editable | Rejected _ -> Ok { draft with text; phase = Editable }
  | Needs_review _ -> Ok { draft with text }
let begin_save draft = match draft.phase with
  | Saving _ -> Error "This draft already has a submitted save"
  | Needs_review _ -> Error "Reread and compare the current file, then adopt its revision before saving"
  | Editable | Rejected _ ->
    let ticket = ref () in Ok ({ draft with phase = Saving ticket }, ticket)
let observe current draft = match draft.phase with
  | Saving _ -> draft
  | Needs_review (reason, _) -> { draft with phase = Needs_review (reason, Some current) }
  | Editable | Rejected _ ->
    if String.equal current.revision draft.base.revision then draft
    else { draft with phase = Needs_review (Conflict "The server file changed", Some current) }
let adopt_current draft = match draft.phase with
  | Needs_review (_, Some current) -> Ok { draft with base = current; phase = Editable }
  | Needs_review (_, None) -> Error "Reread the server file before adopting its revision"
  | Saving _ -> Error "Wait for the submitted save before changing its revision"
  | Editable | Rejected _ -> Error "This draft has no newer comparison to adopt"
type outcome = Save_succeeded of string | Save_refused of string
  | Save_conflict of string | Save_uncertain of string
type completion = Ignored | Retained of t | Committed of source
let complete ticket outcome draft = match draft.phase with
  | Saving current when current == ticket ->
    (match outcome with
     | Save_succeeded revision -> Committed { text = draft.text; revision }
     | Save_refused detail -> Retained { draft with phase = Rejected detail }
     | Save_conflict detail -> Retained { draft with phase = Needs_review (Conflict detail, None) }
     | Save_uncertain detail -> Retained { draft with phase = Needs_review (Uncertain detail, None) })
  | Saving _ | Editable | Rejected _ | Needs_review _ -> Ignored
