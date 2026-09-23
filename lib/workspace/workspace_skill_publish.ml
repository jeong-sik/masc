type evidence = string list

type evidence_error =
  | Evidence_empty
  | Evidence_blank_entry of { index : int }

let evidence_of_list entries =
  let rec first_blank index = function
    | [] -> None
    | entry :: rest ->
      if String.equal (String.trim entry) "" then Some index else first_blank (index + 1) rest
  in
  match entries with
  | [] -> Error Evidence_empty
  | _ :: _ ->
    (match first_blank 0 entries with
     | Some index -> Error (Evidence_blank_entry { index })
     | None -> Ok entries)
;;

let evidence_to_list evidence = evidence

let evidence_error_to_string = function
  | Evidence_empty -> "evidence must name at least one reference"
  | Evidence_blank_entry { index } -> Printf.sprintf "evidence[%d] is blank" index
;;

type request =
  { actor : string
  ; package_id : Skill_reference.package_id
  ; source_text : string
  ; evidence : evidence
  }

type outcome =
  | Created_and_published of
      { reference : Skill_reference.t
      ; snapshot_revision : string
      }
  | Created_but_unpublished of
      { reference : Skill_reference.t
      ; reason : string
      }

type refusal_cause =
  | Request_refused
  | Source_unavailable
  | Write_outcome_unknown

type error =
  | Not_installed
  | Refused of
      { code : string
      ; message : string
      ; cause : refusal_cause
      }
