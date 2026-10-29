module Flow = Keeper_memory_recall_flow
module J = Keeper_memory_recall_judgment
module Candidates = Keeper_memory_recall_candidates
module Facts = Keeper_memory_os_types
module U = Yojson.Safe.Util

(* A fragment that does not render is placed in the text under its key, as the
   other Keeper fragments are: a silently missing sentence would read as an
   absent condition rather than a broken one. *)
let fragment key vars =
  match Prompt_registry.render_prompt_template key vars with
  | Ok text -> text
  | Error detail -> key ^ ": " ^ detail

let impossible detail = invalid_arg ("Keeper_memory_recall_render: " ^ detail)

(* ---- the status line ---- *)

let partial_note coverage =
  if J.is_partial coverage
  then
    Some
      (fragment Prompt_names.keeper_recall_status_partial
         [ "judged", string_of_int (J.coverage_judged coverage)
         ; "candidates", string_of_int (J.coverage_total coverage)
         ])
  else None

let status ~memory_search_available ~turn_ref (judged : Flow.judged) =
  let turn_ref = Ids.Turn_ref.to_string turn_ref in
  let coverage = J.status_coverage judged.status in
  let judged_count = string_of_int (J.coverage_judged coverage) in
  let search_hint key = if memory_search_available then Some (fragment key []) else None in
  let main, hint, ids_line =
    match judged.status with
    | J.Selected { selection; coverage = _; turn_question_contradicted = _ } ->
      let ids = J.selection_ids selection in
      ( fragment Prompt_names.keeper_recall_status_selected
          [ "turn_ref", turn_ref
          ; "candidates", string_of_int (J.coverage_total coverage)
          ; "selected", string_of_int (List.length ids)
          ]
      , None
      , Some
          (fragment Prompt_names.keeper_recall_status_selected_ids
             [ "ids", String.concat ", " ids ]) )
    | J.None_found _ ->
      let key =
        match judged.turn with
        | J.Turn_answered J.Needs_knowledge -> Prompt_names.keeper_recall_status_none_found_needed
        | J.Turn_answered J.Unsure -> Prompt_names.keeper_recall_status_none_found_unsure
        | J.Turn_answered J.Needs_no_knowledge | J.Turn_question_failed ->
          impossible "none_found with a turn question that did not ask for knowledge"
      in
      ( fragment key [ "turn_ref", turn_ref; "candidates", judged_count ]
      , search_hint Prompt_names.keeper_recall_status_search_hint
      , None )
    | J.None_needed _ ->
      ( fragment Prompt_names.keeper_recall_status_none_needed
          [ "turn_ref", turn_ref; "candidates", judged_count ]
      , search_hint Prompt_names.keeper_recall_status_search_hint
      , None )
    | J.Unavailable unavailable ->
      ( fragment Prompt_names.keeper_recall_status_unavailable
          [ "turn_ref", turn_ref; "reason", J.unavailable_reason_token unavailable ]
      , search_hint Prompt_names.keeper_recall_status_search_hint_unavailable
      , None )
  in
  let sentences =
    String.concat " " (main :: List.filter_map Fun.id [ partial_note coverage; hint ])
  in
  match ids_line with
  | None -> sentences
  | Some ids -> sentences ^ "\n" ^ ids

(* ---- the body ---- *)

let day = function
  | `String text -> text
  | `Null -> "unknown"
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _ -> impossible "a candidate day is a string or null"

(* The coordinate a Task completion can cite: only a fact read from a Board
   post has one. *)
let source_coordinate (fact : Facts.fact) =
  match fact.basis with
  | Facts.Observed (Facts.Board { post_id; comment_id = _ }) ->
    Some
      (fragment Prompt_names.keeper_recall_body_source_board
         [ "post_id", Board_types.Post_id.to_string post_id ])
  | Facts.Observed Facts.Transcript | Facts.Derived _ -> None

(* No mark at all is read as not judged: a memory is never worded as standing
   unless question (c) said so. *)
let time_note marks id =
  match List.assoc_opt id marks with
  | Some (J.Marked J.Standing) -> None
  | Some (J.Marked J.Time_bound) -> Some (fragment Prompt_names.keeper_recall_body_time_bound [])
  | Some J.Time_unjudged | None -> Some (fragment Prompt_names.keeper_recall_body_time_unjudged [])

(* A claim of several lines keeps them. Each line after the first is indented,
   so no line of a claim opens an item or a heading of this block. *)
let claim_text claim = String.concat "\n    " (String.split_on_char '\n' claim)

let item ~marks (fact : Facts.fact) =
  let id = Facts.memory_id fact in
  let line = Candidates.line (Candidates.of_fact fact) in
  let field name = U.member name line in
  let head =
    fragment Prompt_names.keeper_recall_body_item
      [ "id", id
      ; "category", U.to_string (field "category")
      ; "first_seen", day (field "first_seen")
      ; "last_seen", day (field "last_seen")
      ; "origin", U.to_string (field "origin")
      ; "claim", claim_text (U.to_string (field "claim"))
      ]
  in
  let notes = List.filter_map Fun.id [ source_coordinate fact; time_note marks id ] in
  String.concat "\n" (head :: List.map (fun note -> "  " ^ note) notes)

let body facts (judged : Flow.judged) =
  match judged.status with
  | J.None_found _ | J.None_needed _ | J.Unavailable _ -> None
  | J.Selected { selection; coverage = _; turn_question_contradicted = _ } ->
    let carried =
      List.map
        (fun id ->
           match List.find_opt (fun fact -> String.equal (Facts.memory_id fact) id) facts with
           | Some fact -> fact
           | None -> impossible ("the carried memory " ^ id ^ " has no fact"))
        (J.selection_ids selection)
    in
    let heading =
      fragment Prompt_names.keeper_recall_body_heading
        [ "count", string_of_int (List.length carried) ]
    in
    Some (String.concat "\n" (heading :: List.map (item ~marks:judged.marks) carried))
