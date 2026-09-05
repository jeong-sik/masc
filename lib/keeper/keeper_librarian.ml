(** Keeper_librarian — LLM-owned current Memory OS selection. *)

open Keeper_memory_os_types

module Canonical_tool = Agent_core.Canonical_tool
module String_map = Map.Make (String)
module String_set = Set.Make (String)

type object_field_error =
  | Unexpected_object_field of string
  | Duplicate_object_field of string

type current_selection =
  { facts : fact list }

type tool_observation_outcome =
  | Succeeded
  | Failed
  | Unknown

type tool_observation =
  { tool_name : string
  ; outcome : tool_observation_outcome
  }

type input =
  { turn_ref : Ids.Turn_ref.t
  ; keeper_instructions : string
  ; current : current_selection option
  ; messages : Agent_core.Types.message list
  ; tool_observations : tool_observation list
  ; counterpart_observations : Keeper_counterpart_observation.t list
  }

(* A new claim that continues a dropped memory: the librarian said so with
   [supersedes], and the parser checked that the old id exists and is in
   [dropped]. Recorded as a [Revised] event on the old id (RFC-0418). *)
type revision =
  { superseded : string
  ; superseded_by : string
  }

type selection =
  { retained_memory_ids : string list
  ; new_claims : fact list
  ; dropped : dropped_statement list
  ; facts : fact list
  ; revisions : revision list
  }

let wire_field_retained_memory_ids = "retained_memory_ids"
let wire_field_new_claims = "new_claims"
let wire_field_dropped = "dropped"
let wire_field_claim = Keeper_memory_os_types.wire_field_claim
let wire_field_category = Keeper_memory_os_types.wire_field_category
let wire_field_memory_id = Keeper_memory_os_types.wire_field_memory_id
let wire_field_reason = Keeper_memory_os_types.wire_field_reason
let wire_field_supersedes = Keeper_memory_os_types.wire_field_supersedes
let wire_claim_fields = Keeper_memory_os_types.wire_librarian_claim_fields
let wire_dropped_fields = Keeper_memory_os_types.wire_librarian_dropped_fields
let wire_current_fields =
  [ wire_field_retained_memory_ids; wire_field_new_claims; wire_field_dropped ]

let trim_nonempty s =
  let s = String.trim s in
  if String.equal s "" then None else Some s
;;

let role_to_string = Agent_core.Types.role_to_string

let text_of_content block =
  match Canonical_tool.tool_result_of_block block with
  | Some result ->
    Some
      (Printf.sprintf
         "[tool result omitted: id=%s is_error=%b]"
         result.Canonical_tool.call_id
         (Agent_core.Types.tool_result_outcome_is_error
            result.Canonical_tool.outcome))
  | None -> (
    match Canonical_tool.tool_call_of_block block with
    | Some call ->
      Some
        (Printf.sprintf
           "[tool use omitted: id=%s name=%s]"
           call.Canonical_tool.call_id
           call.Canonical_tool.name)
    | None -> (
      match block with
      | Agent_core.Types.Text s -> trim_nonempty s
      | Agent_core.Types.ToolResult _ ->
        invalid_arg
          "keeper_librarian: AGENT_CORE canonical tool-result projection unavailable"
      | Agent_core.Types.ToolUse _ ->
        invalid_arg
          "keeper_librarian: AGENT_CORE canonical tool-call projection unavailable"
      | Agent_core.Types.Thinking _
      | Agent_core.Types.ReasoningDetails _
      | Agent_core.Types.RedactedThinking _ -> None
      | Agent_core.Types.Image _ -> Some "[image omitted]"
      | Agent_core.Types.Document _ -> Some "[document omitted]"
      | Agent_core.Types.Audio _ -> Some "[audio omitted]"))
;;

let message_to_text ~turn (m : Agent_core.Types.message) : string =
  let parts = List.filter_map text_of_content m.content in
  let body = String.concat "\n" parts |> String.trim in
  let header = Printf.sprintf "turn=%d role=%s" turn (role_to_string m.role) in
  if String.equal body ""
  then Printf.sprintf "[%s] (empty)" header
  else Printf.sprintf "[%s] %s" header body
;;

let format_messages_for_prompt messages =
  match messages with
  | [] -> "[no messages]"
  | _ ->
    messages
    |> List.mapi (fun turn message -> message_to_text ~turn message)
    |> String.concat "\n\n---\n\n"
;;

(* The LLM never sees the cryptographic identity. A 64-hex digest cannot be
   echoed verbatim reliably — observed live 2026-08-22 (masc#29558): hamming-1
   miscopies of current identities and stale digests recopied from recall
   renderings in conversation history, each looping for hours under exact
   decoding. The prompt renders short surrogate identities [m1], [m2], ... in
   current-fact order, and the parser maps them back to real identities before
   validation. Unknown tokens still reject the whole answer, so a stale or
   invented identity stays fail-closed. *)
let surrogate_id_of_index index = Printf.sprintf "m%d" (index + 1)

let current_fact_json index fact =
  `Assoc
    [ wire_field_memory_id, `String (surrogate_id_of_index index)
    ; ( "fact"
      , `Assoc
          [ wire_field_claim, `String fact.claim
          ; wire_field_category, `String (category_to_string fact.category)
          ] )
    ]
;;

let current_selection_json (current : current_selection) =
  `Assoc
    [ "facts", `List (List.mapi current_fact_json current.facts) ]
;;

let format_current_selection_for_prompt
      (current : current_selection option)
  =
  match current with
  | None -> Yojson.Safe.pretty_to_string `Null
  | Some current ->
    current_selection_json current |> Yojson.Safe.pretty_to_string
;;

let format_keeper_instructions_for_prompt instructions =
  match trim_nonempty instructions with
  | None -> "[no keeper instructions]"
  | Some instructions -> instructions
;;

let tool_observation_outcome_to_string = function
  | Succeeded -> "succeeded"
  | Failed -> "failed"
  | Unknown -> "unknown"
;;

let format_tool_observations_for_prompt observations =
  `List
    (List.map
       (fun observation ->
          `Assoc
            [ "tool_name", `String observation.tool_name
            ; ( "outcome"
              , `String
                  (tool_observation_outcome_to_string observation.outcome) )
            ])
       observations)
  |> Yojson.Safe.pretty_to_string
;;

let prompt_variables (inp : input) : (string * string) list =
  [ ( "keeper_instructions"
    , format_keeper_instructions_for_prompt inp.keeper_instructions )
  ; "current_memory", format_current_selection_for_prompt inp.current
  ; ( "conversation_history"
    , format_messages_for_prompt inp.messages )
  ; ( "turn_tool_observations"
    , format_tool_observations_for_prompt inp.tool_observations )
  ; ( "counterpart_observations"
    , Keeper_counterpart_observation.render_for_prompt
        inp.counterpart_observations )
  ]
;;

let string_field key fields =
  match List.assoc_opt key fields with
  | Some (`String s) -> trim_nonempty s
  | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null)
  | None -> None
;;

let rec traverse f = function
  | [] -> Some []
  | x :: xs ->
    (match f x, traverse f xs with
     | Some y, Some ys -> Some (y :: ys)
     | (Some _, None) | (None, _) -> None)
;;

let string_list_field key fields =
  match List.assoc_opt key fields with
  | Some (`List items) -> traverse (function `String s -> trim_nonempty s | _ -> None) items
  | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _)
  | None -> None
;;

let field_allowed ~allowed field =
  List.exists (String.equal field) allowed
;;

let first_object_field_error ~allowed fields =
  let rec loop seen = function
    | [] -> None
    | (field, _) :: rest ->
      if String_set.mem field seen
      then Some (Duplicate_object_field field)
      else if not (field_allowed ~allowed field)
      then Some (Unexpected_object_field field)
      else loop (String_set.add field seen) rest
  in
  loop String_set.empty fields
;;

type parse_error =
  | Top_level_not_object
  | Unexpected_field of string
  | Duplicate_field of string
  | Missing_required_fields
  | Claim_schema_mismatch
  | Dropped_schema_mismatch
  | Unknown_retained_memory_id of string
  | Duplicate_retained_memory_id of string
  | Duplicate_selected_memory_id of string
  | Unknown_dropped_memory_id of string
  | Duplicate_dropped_memory_id of string
  | Dropped_memory_id_also_retained of string
  | Missing_disposition of string
  | Supersedes_unknown_memory_id of string
  | Supersedes_not_dropped of string

let parse_error_to_string = function
  | Top_level_not_object -> "top_level_not_object"
  | Unexpected_field field -> "unexpected_field: " ^ field
  | Duplicate_field field -> "duplicate_field: " ^ field
  | Missing_required_fields -> "missing_required_fields"
  | Claim_schema_mismatch -> "claim_schema_mismatch"
  | Dropped_schema_mismatch -> "dropped_schema_mismatch"
  | Unknown_retained_memory_id identity ->
    "unknown_retained_memory_id: " ^ identity
  | Duplicate_retained_memory_id identity ->
    "duplicate_retained_memory_id: " ^ identity
  | Duplicate_selected_memory_id identity ->
    "duplicate_selected_memory_id: " ^ identity
  | Unknown_dropped_memory_id identity ->
    "unknown_dropped_memory_id: " ^ identity
  | Duplicate_dropped_memory_id identity ->
    "duplicate_dropped_memory_id: " ^ identity
  | Dropped_memory_id_also_retained identity ->
    "dropped_memory_id_also_retained: " ^ identity
  | Missing_disposition identity -> "missing_disposition: " ^ identity
  | Supersedes_unknown_memory_id token -> "supersedes_unknown_memory_id: " ^ token
  | Supersedes_not_dropped identity -> "supersedes_not_dropped: " ^ identity
;;

let fact_of_json ~now (json : Yojson.Safe.t) : fact option =
  match json with
  | `Assoc fields ->
    (match
       string_field wire_field_claim fields
       , (match List.assoc_opt wire_field_category fields with
          | Some (`String raw) -> category_of_string raw
          | Some _ | None -> None)
     with
     | Some claim, Some category ->
       (* Where the claim was read: a Board post the librarian names, or the
          transcript. The schema answers both fields on every claim, null for
          the transcript. A field that is present but not null and not a
          non-blank string, a comment without its post, or an id the Board
          grammar rejects all reject the claim, like any other malformed
          claim field; only null or absence means the transcript. *)
       let board_field key =
         match List.assoc_opt key fields with
         | None | Some `Null -> Ok None
         | Some (`String raw) ->
           (match trim_nonempty raw with
            | Some value -> Ok (Some value)
            | None -> Error ())
         | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _) ->
           Error ()
       in
       let observation =
         match
           ( board_field Keeper_memory_os_types.wire_field_board_post_id
           , board_field Keeper_memory_os_types.wire_field_board_comment_id )
         with
         | Error (), _ | _, Error () -> None
         | Ok None, Ok None -> Some Keeper_memory_os_types.Transcript
         | Ok None, Ok (Some _) -> None
         | Ok (Some post_id), Ok comment_id ->
           (match Keeper_memory_os_types.board_ref_of_ids ~post_id ~comment_id with
            | Ok board -> Some (Keeper_memory_os_types.Board board)
            | Error _ -> None)
       in
       (match observation with
        | None -> None
        | Some observation ->
          (* Origin is the extraction itself: this row is a copy of something
             the keeper already saw. [trace_id] is empty by construction — the
             committing journal entry (snapshot-level source) carries the exact
             trace; the row never guesses one. *)
          Some
            { claim
            ; category
            ; first_seen = now
            ; last_seen = now
            ; origin = { kind = Keeper_memory_os_types.Injected; trace_id = "" }
            ; basis = Keeper_memory_os_types.Observed observation
            })
     | (Some _, None) | (None, _) -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

(* [supersedes] names, by its short id, the dropped memory this claim
   continues. Absent or null is a claim that continues nothing. Any other
   value that is not a non-blank string rejects the claim like any other
   malformed field. Whether the id exists and was dropped is checked once the
   ids are translated, where that answer lives. *)
let new_claim_of_json ~now (json : Yojson.Safe.t) : (fact * string option) option =
  match fact_of_json ~now json, json with
  | Some fact, `Assoc fields ->
    (match List.assoc_opt wire_field_supersedes fields with
     | None | Some `Null -> Some (fact, None)
     | Some (`String raw) ->
       (match trim_nonempty raw with
        | Some token -> Some (fact, Some token)
        | None -> None)
     | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _) -> None)
  | None, _ -> None
  | Some _, (`Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _) ->
    None
;;

let claim_field_error = function
  | `Assoc fields -> first_object_field_error ~allowed:wire_claim_fields fields
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

let dropped_field_error = function
  | `Assoc fields -> first_object_field_error ~allowed:wire_dropped_fields fields
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

let dropped_statement_of_json (json : Yojson.Safe.t) : dropped_statement option =
  match json with
  | `Assoc fields ->
    (match
       string_field wire_field_memory_id fields
       , string_field wire_field_reason fields
     with
     | Some memory_id, Some reason -> Some { memory_id; reason }
     | (Some _, None) | (None, _) -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

let current_facts_by_id facts =
  List.fold_left
    (fun by_id fact ->
       String_map.add (memory_id fact) fact by_id)
    String_map.empty
    facts
;;

let surrogate_identity_map facts =
  List.mapi (fun index fact -> surrogate_id_of_index index, memory_id fact) facts
  |> List.to_seq
  |> String_map.of_seq
;;

let translate_retained_ids ~by_surrogate retained_memory_ids =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | token :: rest ->
      (match String_map.find_opt token by_surrogate with
       | Some identity -> loop (identity :: acc) rest
       | None -> Error (Unknown_retained_memory_id token))
  in
  loop [] retained_memory_ids
;;

let translate_dropped_ids ~by_surrogate dropped =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (statement : dropped_statement) :: rest ->
      (match String_map.find_opt statement.memory_id by_surrogate with
       | Some identity ->
         loop ({ statement with memory_id = identity } :: acc) rest
       | None -> Error (Unknown_dropped_memory_id statement.memory_id))
  in
  loop [] dropped
;;

(* A revision pairs the dropped memory with the claim that continues it. The
   old id has to be one the librarian saw and dropped in this same answer: a
   supersede of a retained memory would keep both versions, and one of an
   unknown id names nothing. *)
let translate_revisions ~by_surrogate ~(dropped : dropped_statement list) pairs =
  let dropped_ids =
    List.fold_left
      (fun set (statement : dropped_statement) -> String_set.add statement.memory_id set)
      String_set.empty
      dropped
  in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (_, None) :: rest -> loop acc rest
    | (fact, Some token) :: rest ->
      (match String_map.find_opt token by_surrogate with
       | None -> Error (Supersedes_unknown_memory_id token)
       | Some superseded ->
         if String_set.mem superseded dropped_ids
         then loop ({ superseded; superseded_by = memory_id fact } :: acc) rest
         else Error (Supersedes_not_dropped superseded))
  in
  loop [] pairs
;;

let current_facts inp =
  match inp.current with
  | None -> []
  | Some current -> current.facts
;;

let materialize_facts ~current_facts ~retained_memory_ids ~new_claims ~dropped =
  let open Result.Syntax in
  let current_by_id = current_facts_by_id current_facts in
  let rec retain seen retained_rev = function
    | [] -> Ok (List.rev retained_rev, seen)
    | identity :: rest ->
      if String_set.mem identity seen
      then Error (Duplicate_retained_memory_id identity)
      else
        (match String_map.find_opt identity current_by_id with
         | None -> Error (Unknown_retained_memory_id identity)
         | Some fact ->
           retain
             (String_set.add identity seen)
             (fact :: retained_rev)
             rest)
  in
  let* retained, selected_ids =
    retain String_set.empty [] retained_memory_ids
  in
  (* Totality: every current identity must be dispositioned exactly once —
     retained or dropped with a stated reason. Silent omission is no longer
     the deletion operation; it is a contract violation. *)
  let rec validate_dropped seen = function
    | [] -> Ok seen
    | (statement : dropped_statement) :: rest ->
      if String_set.mem statement.memory_id seen
      then Error (Duplicate_dropped_memory_id statement.memory_id)
      else if String_set.mem statement.memory_id selected_ids
      then Error (Dropped_memory_id_also_retained statement.memory_id)
      else if not (String_map.mem statement.memory_id current_by_id)
      then Error (Unknown_dropped_memory_id statement.memory_id)
      else validate_dropped (String_set.add statement.memory_id seen) rest
  in
  let* dropped_ids = validate_dropped String_set.empty dropped in
  let* () =
    match
      List.find_opt
        (fun fact ->
           let identity = memory_id fact in
           not
             (String_set.mem identity selected_ids
              || String_set.mem identity dropped_ids))
        current_facts
    with
    | Some fact -> Error (Missing_disposition (memory_id fact))
    | None -> Ok ()
  in
  let rec append_new selected_ids new_rev = function
    | [] -> Ok (retained @ List.rev new_rev)
    | fact :: rest ->
      let identity = memory_id fact in
      if
        String_set.mem identity selected_ids
        || String_map.mem identity current_by_id
      then Error (Duplicate_selected_memory_id identity)
      else
        append_new
          (String_set.add identity selected_ids)
          (fact :: new_rev)
          rest
  in
  append_new selected_ids [] new_claims
;;

let selection_of_json_result ?now (inp : input) (json : Yojson.Safe.t) :
  (selection, parse_error) result
  =
  let now =
    match now with
    | Some now -> now
    | None ->
      (* NDT-OK: extraction time is presentation metadata only. *)
      Unix.gettimeofday ()
  in
  match json with
  | `Assoc fields ->
    (match first_object_field_error ~allowed:wire_current_fields fields with
     | Some (Unexpected_object_field field) -> Error (Unexpected_field field)
     | Some (Duplicate_object_field field) -> Error (Duplicate_field field)
     | None ->
       (match
          string_list_field wire_field_retained_memory_ids fields
          , List.assoc_opt wire_field_new_claims fields
          , List.assoc_opt wire_field_dropped fields
        with
        | ( Some retained_memory_ids
          , Some (`List claim_items)
          , Some (`List dropped_items) ) ->
          (match List.find_map claim_field_error claim_items with
           | Some (Unexpected_object_field field) -> Error (Unexpected_field field)
           | Some (Duplicate_object_field field) -> Error (Duplicate_field field)
           | None ->
             (match List.find_map dropped_field_error dropped_items with
              | Some (Unexpected_object_field field) ->
                Error (Unexpected_field field)
              | Some (Duplicate_object_field field) ->
                Error (Duplicate_field field)
              | None ->
                (match
                   traverse (new_claim_of_json ~now) claim_items
                   , traverse dropped_statement_of_json dropped_items
                 with
                 | Some new_claim_pairs, Some dropped ->
                   let new_claims = List.map fst new_claim_pairs in
                   let by_surrogate =
                     surrogate_identity_map (current_facts inp)
                   in
                   (match
                      ( translate_retained_ids
                          ~by_surrogate
                          retained_memory_ids
                      , translate_dropped_ids ~by_surrogate dropped )
                    with
                   | Ok retained_memory_ids, Ok dropped ->
                     (match
                        materialize_facts
                          ~current_facts:(current_facts inp)
                          ~retained_memory_ids
                          ~new_claims
                          ~dropped
                      with
                      | Ok facts ->
                        (match
                           translate_revisions ~by_surrogate ~dropped new_claim_pairs
                         with
                         | Ok revisions ->
                           Ok
                             { retained_memory_ids
                             ; new_claims
                             ; dropped
                             ; facts
                             ; revisions
                             }
                         | Error _ as error -> error)
                    | Error _ as error -> error)
                   | (Error _ as error), _ | _, (Error _ as error) -> error)
                 | Some _, None -> Error Dropped_schema_mismatch
                 | None, _ -> Error Claim_schema_mismatch)))
        | _ -> Error Missing_required_fields))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error Top_level_not_object
;;
