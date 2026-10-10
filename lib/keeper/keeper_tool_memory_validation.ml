module StringSet = Set_util.StringSet

type fact_store =
  | Ordinary_current
  | Source_bound_current

(** Which half of a derivation arrived without the other. *)
type derivation_half =
  | Rule_id_without_premise_ids
  | Premise_ids_without_rule_id

(** Why the [rule_id] and [premise_ids] this call carried cannot name a
    derivation. Closed and produced only by {!validate_memory_write_args}, so a
    new refusal has to say what to change before it can be made.
    [Keeper_memory_os_types.is_memory_id] stays the single premise grammar;
    this type only records which element broke it and where. *)
type derivation_rejection =
  | Rule_id_not_a_string
  | Premise_ids_not_an_array
  | Rule_id_blank
  | Premise_ids_empty
  | Premise_not_a_string of { index : int }
  | Premise_repeated of
      { index : int
      ; premise_id : string
      }
  | Premise_not_a_memory_id of
      { index : int
      ; premise_id : string
      }

(** Pure validation result for a [keeper_memory_write] call. Splitting
    this from the persistence step lets tests pin the error_kind
    taxonomy without constructing a [Workspace.config]. *)
type memory_write_error_kind =
  | Content_empty
  | Source_path_invalid
  | Source_read_failed of Keeper_memory_source_current.source_read_failure
  | Derivation_incomplete of derivation_half
  | Derivation_invalid of derivation_rejection
  | Derived_source_path_unsupported
  | Board_ref_invalid
  | Board_comment_without_post
  | Board_ref_with_derivation_unsupported
  | Board_ref_with_source_path_unsupported
  | Unsupported_derivation
  | Supersedes_invalid
  | Supersedes_with_source_path_unsupported
  | Supersedes_self
  | Supersedes_not_current
  | Supersedes_not_authored
  | Supersedes_premise_of_successor
  | Pending_admission_persistence_failed
  | Persistence_failed of fact_store
  | Commit_receipt_inconsistent
  | No_memory_write_error

let memory_write_error_kind_to_string = function
  | Content_empty -> "content_empty"
  | Source_path_invalid -> "source_path_invalid"
  | Source_read_failed _ -> "source_read_failed"
  | Derivation_incomplete _ -> "derivation_incomplete"
  | Derivation_invalid _ -> "derivation_invalid"
  | Derived_source_path_unsupported -> "derived_source_path_unsupported"
  | Board_ref_invalid -> "board_ref_invalid"
  | Board_comment_without_post -> "board_comment_without_post"
  | Board_ref_with_derivation_unsupported -> "board_ref_with_derivation_unsupported"
  | Board_ref_with_source_path_unsupported -> "board_ref_with_source_path_unsupported"
  | Unsupported_derivation -> "unsupported_derivation"
  | Supersedes_invalid -> "supersedes_invalid"
  | Supersedes_with_source_path_unsupported -> "supersedes_with_source_path_unsupported"
  | Supersedes_self -> "supersedes_self"
  | Supersedes_not_current -> "supersedes_not_current"
  | Supersedes_not_authored -> "supersedes_not_authored"
  | Supersedes_premise_of_successor -> "supersedes_premise_of_successor"
  | Persistence_failed (Ordinary_current | Source_bound_current) -> "persistence_failed"
  | Pending_admission_persistence_failed -> "pending_admission_persistence_failed"
  | Commit_receipt_inconsistent -> "commit_receipt_inconsistent"
  | No_memory_write_error -> ""
;;

(* What the model does next depends on which side failed. Input the caller
   can correct is a policy rejection; a store or source file that could not
   be read or written is a dependency the arguments never reached; the
   "no error" kind never travels with ok=false, so reaching it here is a
   producer bug. *)
let class_of_memory_write_error_kind = function
  | Content_empty
  | Source_path_invalid
  | Derivation_incomplete _
  | Derivation_invalid _
  | Derived_source_path_unsupported
  | Board_ref_invalid
  | Board_comment_without_post
  | Board_ref_with_derivation_unsupported
  | Board_ref_with_source_path_unsupported
  | Unsupported_derivation
  | Supersedes_invalid
  | Supersedes_with_source_path_unsupported
  | Supersedes_self
  | Supersedes_not_authored
  | Supersedes_premise_of_successor
  | Source_read_failed
      ( Keeper_memory_source_current.Source_path_rejected _
      | Keeper_memory_source_current.Source_missing
      | Keeper_memory_source_current.Source_not_a_regular_file
      | Keeper_memory_source_current.Source_too_large _
      | Keeper_memory_source_current.Source_over_limit _ ) ->
    Tool_result.Policy_rejection
  (* Like a retraction of an absent fact: the store moved on since the id was
     read, which a fresh search answers. *)
  | Supersedes_not_current -> Tool_result.Workflow_rejection
  | Source_read_failed
      ( Keeper_memory_source_current.Source_io_failed _
      | Keeper_memory_source_current.Source_endpoint_unanswered _ )
  | Pending_admission_persistence_failed
  | Persistence_failed (Ordinary_current | Source_bound_current) ->
    Tool_result.Dependency_unavailable
  (* The store committed and then did not show what it committed: a
     producer bug, not a dependency that can answer on a later turn. *)
  | Commit_receipt_inconsistent | No_memory_write_error -> Tool_result.Runtime_failure
;;

(* What a failed write committed, and the same fact told to the model, both
   follow from why it failed, so one match on the kind decides them and no
   failure site states either.

   A refusal means this claim was not committed. It does not mean the store
   wrote nothing: the ordinary store moves a snapshot this build cannot decode
   aside, goes on from empty state, and a derivation can then find its
   premises gone.

   What a repeat write does depends on the store, so a store failure names
   it. In the ordinary store the same title and content are the same fact
   (keyed by their SHA-256). In the source-bound store the path is the key: a
   write for the same path replaces that path's claim. Either store commits
   another revision for every write. *)
let memory_write_failure_effect = function
  | Content_empty
  | Source_path_invalid
  | Source_read_failed _
  | Derivation_incomplete _
  | Derivation_invalid _
  | Derived_source_path_unsupported
  | Board_ref_invalid
  | Board_comment_without_post
  | Board_ref_with_derivation_unsupported
  | Board_ref_with_source_path_unsupported
  | Unsupported_derivation
  | Supersedes_invalid
  | Supersedes_with_source_path_unsupported
  | Supersedes_self ->
    Tool_result.Proven_pre_effect, "The claim was not committed."
  | Supersedes_not_current | Supersedes_not_authored | Supersedes_premise_of_successor ->
    ( Tool_result.Proven_pre_effect
    , "The claim was not committed and no fact was removed." )
  | Commit_receipt_inconsistent ->
    ( Tool_result.Proven_post_effect
    , "A new snapshot revision was committed, but this claim is not in it. Search \
       memory for the claim before writing it again." )
  | Pending_admission_persistence_failed ->
    ( Tool_result.Effect_outcome_unknown
    , "The candidate may or may not have been saved to the pending admission queue. \
       Current Memory search cannot establish whether it is pending. Retain and \
       report this request_id for investigation. Do not retry merely because \
       current search is empty: another tool call creates a new request and may \
       duplicate the candidate. Admission has not been confirmed." )
  | Persistence_failed Ordinary_current ->
    ( Tool_result.Effect_outcome_unknown
    , "The claim may or may not have been committed. Search memory for it before \
       writing it again: the same title and content make the same fact, but each \
       write commits another revision." )
  | Persistence_failed Source_bound_current ->
    ( Tool_result.Effect_outcome_unknown
    , "The claim may or may not have been committed. Search memory for it before \
       writing it again: a write for the same source_path replaces that path's \
       claim, and each write commits another revision." )
  (* The "no error" kind reaching a failure is a producer bug; it proves
     nothing about the store. *)
  | No_memory_write_error ->
    ( Tool_result.Effect_outcome_unknown
    , "The claim may or may not have been committed. Search memory for it before \
       writing it again." )
;;

(* A memory identity is the one argument a model cannot guess, and the
   refusals show it guessing: across 2026-09-01..15 every one of the 20
   derivation_invalid calls broke on a premise that was not a memory identity.
   19 had no "sha256:" prefix at all ("mem_01K4Z5...", "c-c6ba9d...",
   "fact-20260911154720", bare 40-digit hex, "7") and one was a digit too long.
   So the sentence that rejects one also names the shape and the two tools that
   hand a real one out. *)
let premise_id_expectation =
  Printf.sprintf
    "A memory identity is %s. keeper_memory_search returns one as memory_id for \
     current match it finds. A current-store keeper_memory_write receipt returns the \
     identity it committed; a pending admission request_id is not a memory identity."
    Keeper_memory_os_types.memory_id_shape
;;

(* What to change to make this exact call pass, at the field that failed.

   A refusal that names only its kind leaves the model to pick a field, and
   the pick it made was to drop the derivation: of the 54 derivation refusals
   in 2026-09-01..15, one was later written again with rule_id and premise_ids
   intact. The same keeper's next successful write carried neither in the other
   53, ten of them with the refused content. Naming the field and what it takes
   is the answer [Keeper_invocation_contract.exact_fields] already gives for an
   unknown field.

   The kinds answering [] already carry their own coordinates: a source read
   failure reports the path and the operation, and the rest name a single field
   in their own tag. *)
let memory_write_rejection_fields error_kind =
  let at field expected = [ "rejected_field", `String field; "expected", `String expected ] in
  let at_premise index expected =
    at (Printf.sprintf "premise_ids[%d]" index) expected
  in
  match error_kind with
  | Derivation_incomplete Rule_id_without_premise_ids ->
    at
      "premise_ids"
      ("rule_id names a rule, so premise_ids has to name what the rule was \
        applied to. " ^ premise_id_expectation)
  | Derivation_incomplete Premise_ids_without_rule_id ->
    at
      "rule_id"
      "premise_ids names premises, so rule_id has to name the rule that drew \
       this claim from them."
  | Derivation_invalid Rule_id_not_a_string -> at "rule_id" "rule_id is a string."
  | Derivation_invalid Premise_ids_not_an_array ->
    at
      "premise_ids"
      ("premise_ids is an array of memory identity strings. " ^ premise_id_expectation)
  | Derivation_invalid Rule_id_blank ->
    at "rule_id" "rule_id names the rule that drew this claim from its premises."
  | Derivation_invalid Premise_ids_empty ->
    at
      "premise_ids"
      ("A derived claim rests on at least one premise, each a memory identity. "
       ^ premise_id_expectation)
  | Derivation_invalid (Premise_not_a_string { index }) ->
    at_premise
      index
      ("Each premise is a memory identity string. " ^ premise_id_expectation)
  | Derivation_invalid (Premise_repeated { index; premise_id }) ->
    at_premise
      index
      (Printf.sprintf
         "%S is already named earlier in premise_ids. Each premise is named once."
         premise_id)
  | Derivation_invalid (Premise_not_a_memory_id { index; premise_id }) ->
    at_premise
      index
      (Printf.sprintf
         "%S is not a memory identity. %s"
         premise_id
         premise_id_expectation)
  (* The store holds no fact under these identities, so this claim cannot rest
     on them yet. Admission must finish before a candidate can be a premise. *)
  | Unsupported_derivation ->
    at
      "premise_ids"
      "The ids under missing_premise_ids name no current fact in the store. Search \
       current Memory for supported premise identities. Newly submitted observations \
       must pass admission first; their pending request_ids are not premises. Only \
       submit this claim without derivation when it is itself an observation."
  | Supersedes_invalid ->
    at
      "supersedes"
      ("supersedes is the memory identity of your own earlier fact this claim \
        replaces. " ^ premise_id_expectation)
  | Supersedes_with_source_path_unsupported ->
    at
      "supersedes"
      "A source-bound claim is replaced by writing the same source_path again. \
       Drop supersedes, or drop source_path to write an ordinary claim."
  | Supersedes_self ->
    at
      "supersedes"
      "This claim has the same bytes as the fact it names, so it is already \
       current. Drop supersedes, or change the claim."
  | Supersedes_not_current ->
    at
      "supersedes"
      "No current fact of yours has this memory_id. When supersedes_removed is \
       present it names the commit that removed it; a superseded_by reason \
       names the fact that replaced it. Otherwise search memory for the fact \
       you mean to replace and pass the memory_id it returns."
  | Supersedes_premise_of_successor ->
    at
      "premise_ids"
      "A premise under missing_premise_ids is the fact supersedes removes, and a \
       claim cannot rest on the fact it replaces. Drop that premise, or drop \
       supersedes to keep both facts."
  | Supersedes_not_authored ->
    at
      "supersedes"
      "This fact is current but you did not write it with keeper_memory_write, \
       so it cannot be superseded here. Drop supersedes to write the claim \
       alongside it."
  | Content_empty
  | Source_path_invalid
  | Source_read_failed _
  | Derived_source_path_unsupported
  | Board_ref_invalid
  | Board_comment_without_post
  | Board_ref_with_derivation_unsupported
  | Board_ref_with_source_path_unsupported
  | Pending_admission_persistence_failed
  | Persistence_failed (Ordinary_current | Source_bound_current)
  | Commit_receipt_inconsistent
  | No_memory_write_error -> []
;;

let memory_write_error_effect_disposition error_kind =
  fst (memory_write_failure_effect error_kind)
;;

type memory_write_validation =
  | Memory_write_ok of
      { body : string
      ; source_path : string option
      ; basis : Keeper_memory_os_types.basis
      ; supersedes : string option
      }
  | Memory_write_invalid of
      { error_kind : memory_write_error_kind
      ; extras : (string * Yojson.Safe.t) list
      }

let validate_memory_write_args (args : Yojson.Safe.t) : memory_write_validation =
  let title = Safe_ops.json_string ~default:"" "title" args |> String.trim in
  let content = Safe_ops.json_string ~default:"" "content" args |> String.trim in
  let source_path =
    match Safe_ops.safe_member "source_path" args with
    | `Null -> Ok None
    | `String raw ->
      let path = String.trim raw in
      if
        String.equal path ""
        || String.contains path '\n'
        || String.contains path '\r'
      then Error Source_path_invalid
      else Ok (Some path)
    | _ -> Error Source_path_invalid
  in
  (* A Board reference is an observation source: the claim was read from a
     post, optionally from one of its comments. The ids are parsed by the
     Board's own grammar; whether the post still exists is not checked at
     write time and no reader checks it yet (RFC-0402 piece 2). *)
  let board_ref =
    let optional_string key =
      match Safe_ops.safe_member key args with
      | `Null -> Ok None
      | `String raw ->
        let value = String.trim raw in
        if String.equal value "" then Error Board_ref_invalid else Ok (Some value)
      | _ -> Error Board_ref_invalid
    in
    match optional_string "board_post_id", optional_string "board_comment_id" with
    | Error error, _ | _, Error error -> Error error
    | Ok None, Ok None -> Ok None
    | Ok None, Ok (Some _) -> Error Board_comment_without_post
    | Ok (Some post_id), Ok comment_id ->
      (match Keeper_memory_os_types.board_ref_of_ids ~post_id ~comment_id with
       | Ok board -> Ok (Some board)
       | Error _ -> Error Board_ref_invalid)
  in
  let derivation =
    match Safe_ops.safe_member "rule_id" args, Safe_ops.safe_member "premise_ids" args with
    | `Null, `Null ->
      (match board_ref with
       | Ok (Some board) ->
         Ok (Keeper_memory_os_types.Observed (Keeper_memory_os_types.Board board))
       | Ok None | Error _ ->
         Ok (Keeper_memory_os_types.Observed Keeper_memory_os_types.Transcript))
    | `String raw_rule_id, `List premise_values ->
      let rule_id = String.trim raw_rule_id in
      (* Each arm names the element and the constraint it broke, because the
         caller can only correct the premise it actually got wrong. The rule is
         checked before the premises so a call wrong in both is not refused
         twice. *)
      let rec premise_ids index seen acc = function
        | [] ->
          (match acc with
           | [] -> Error (Derivation_invalid Premise_ids_empty)
           | _ :: _ ->
             Ok
               (Keeper_memory_os_types.Derived
                  [ { rule_id; premise_ids = List.rev acc } ]))
        | `String premise_id :: rest ->
          if StringSet.mem premise_id seen
          then Error (Derivation_invalid (Premise_repeated { index; premise_id }))
          else if not (Keeper_memory_os_types.is_memory_id premise_id)
          then Error (Derivation_invalid (Premise_not_a_memory_id { index; premise_id }))
          else
            premise_ids
              (index + 1)
              (StringSet.add premise_id seen)
              (premise_id :: acc)
              rest
        | _ -> Error (Derivation_invalid (Premise_not_a_string { index }))
      in
      if String.equal rule_id ""
      then Error (Derivation_invalid Rule_id_blank)
      else premise_ids 0 StringSet.empty [] premise_values
    | `Null, _ -> Error (Derivation_incomplete Premise_ids_without_rule_id)
    | _, `Null -> Error (Derivation_incomplete Rule_id_without_premise_ids)
    | `String _, _ -> Error (Derivation_invalid Premise_ids_not_an_array)
    | _, _ -> Error (Derivation_invalid Rule_id_not_a_string)
  in
  (* The id is taken as sent: [is_memory_id] is the one grammar, and a padded
     id is not the id a search returned. *)
  let supersedes =
    match Safe_ops.safe_member "supersedes" args with
    | `Null -> Ok None
    | `String memory_id when Keeper_memory_os_types.is_memory_id memory_id ->
      Ok (Some memory_id)
    | _ -> Error Supersedes_invalid
  in
  match source_path, derivation, board_ref, supersedes with
  | Error error_kind, _, _, _
  | _, Error error_kind, _, _
  | _, _, Error error_kind, _
  | _, _, _, Error error_kind ->
    Memory_write_invalid { error_kind; extras = [] }
  | Ok source_path, Ok basis, Ok board_ref, Ok supersedes ->
    if Option.is_some supersedes && Option.is_some source_path
    then
      Memory_write_invalid
        { error_kind = Supersedes_with_source_path_unsupported; extras = [] }
    else if
      Option.is_some source_path
      && (match basis with
          | Keeper_memory_os_types.Observed _ -> false
          | Keeper_memory_os_types.Derived _ -> true)
    then
      Memory_write_invalid
        { error_kind = Derived_source_path_unsupported; extras = [] }
    else if
      Option.is_some board_ref
      && (match basis with
          | Keeper_memory_os_types.Observed _ -> false
          | Keeper_memory_os_types.Derived _ -> true)
    then
      Memory_write_invalid
        { error_kind = Board_ref_with_derivation_unsupported; extras = [] }
    else if Option.is_some board_ref && Option.is_some source_path
    then
      Memory_write_invalid
        { error_kind = Board_ref_with_source_path_unsupported; extras = [] }
    else if content = ""
    then Memory_write_invalid { error_kind = Content_empty; extras = [] }
    else
      let body =
        if title = "" then content else Printf.sprintf "**%s** %s" title content
      in
      Memory_write_ok { body; source_path; basis; supersedes }
;;

(* The observed arms echo the stored wire shape; the derived arm reports a
   count instead of the derivations. *)
let memory_write_basis_receipt = function
  | Keeper_memory_os_types.Observed _ as basis ->
    Keeper_memory_os_types.basis_to_json basis
  | Keeper_memory_os_types.Derived derivations ->
    `Assoc
      [ "kind", `String "derived"
      ; "proof_count", `Int (List.length derivations)
      ]
;;

type memory_retract_error_kind =
  | Memory_id_invalid
  | Reason_empty
  | Fact_not_found
  | Retract_persistence_failed
  | No_memory_retract_error

let memory_retract_error_kind_to_string = function
  | Memory_id_invalid -> "memory_id_invalid"
  | Reason_empty -> "reason_empty"
  | Fact_not_found -> "fact_not_found"
  | Retract_persistence_failed -> "persistence_failed"
  | No_memory_retract_error -> ""
;;

let class_of_memory_retract_error_kind = function
  | Memory_id_invalid | Reason_empty -> Tool_result.Policy_rejection
  | Fact_not_found -> Tool_result.Workflow_rejection
  | Retract_persistence_failed -> Tool_result.Dependency_unavailable
  | No_memory_retract_error -> Tool_result.Runtime_failure
;;

(* As for a write, one match on the kind decides what committed and what the
   model is told. A refusal means the retraction was not committed; the store
   may still have moved aside a snapshot it could not decode, which also
   leaves the fact absent.

   A fact the snapshot does not hold is the answer for an id that was never
   current, for one an earlier retraction already removed (including one whose
   result said it may or may not have committed), and for one that was in a
   snapshot the store set aside. The model is told all three, so a retry's
   refusal is not read as proof that the first attempt did nothing. *)
let memory_retract_failure_effect = function
  | Memory_id_invalid | Reason_empty ->
    Tool_result.Proven_pre_effect, "The retraction was not committed."
  | Fact_not_found ->
    ( Tool_result.Proven_pre_effect
    , "The retraction was not committed: this memory_id is not in the current \
       snapshot. It may never have been current, an earlier retraction may have \
       removed it (even one whose result said it may or may not have committed), \
       or it may have been in a snapshot the store could not read and set aside." )
  | Retract_persistence_failed | No_memory_retract_error ->
    ( Tool_result.Effect_outcome_unknown
    , "The retraction may or may not have been committed. Search memory for this \
       fact before retracting it again: if it is gone, this attempt committed and \
       a second retraction answers fact_not_found." )
;;

type memory_retract_validation =
  | Memory_retract_ok of
      { memory_id : string
      ; reason : string
      }
  | Memory_retract_invalid of memory_retract_error_kind

let validate_memory_retract_args (args : Yojson.Safe.t) =
  let memory_id = Safe_ops.json_string ~default:"" "memory_id" args in
  let reason = Safe_ops.json_string ~default:"" "reason" args |> String.trim in
  if not (Keeper_memory_os_types.is_memory_id memory_id)
  then Memory_retract_invalid Memory_id_invalid
  else if String.equal reason ""
  then Memory_retract_invalid Reason_empty
  else Memory_retract_ok { memory_id; reason }
;;
