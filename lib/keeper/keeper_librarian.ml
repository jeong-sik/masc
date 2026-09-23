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

type goal_context =
  | No_task
  | Task_goals of
      { task_id : string
      ; criteria : ((string * Goal_phase.t * Goal_store.criterion) list, string) result
      }

type input =
  { turn_ref : Ids.Turn_ref.t
  ; goal_context : goal_context
  ; keeper_instructions : string
  ; current : current_selection option
  ; working_context : Keeper_librarian_context.input
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

(* The claim fields a restated memory or a second same-text claim carries that
   differ from the fields kept. [origin] is not among them: every claim the
   librarian writes is [Injected], so a keeper-authored memory differs there on
   every restatement and says nothing. *)
type claim_field =
  | Claim_category
  | Claim_basis

type kept_fields_from =
  | Current_memory
  | First_claim

type ignored_fields =
  { restated_id : string
  ; kept_from : kept_fields_from
  ; differing : claim_field list
  }

let claim_field_to_string = function
  | Claim_category -> "category"
  | Claim_basis -> "basis"
;;

let kept_fields_from_to_string = function
  | Current_memory -> "current_memory"
  | First_claim -> "first_claim"
;;

type selection =
  { new_claims : fact list
  ; restated : fact list
  ; ignored_fields : ignored_fields list
  ; dropped : dropped_statement list
  ; absorbed : Keeper_memory_os_types.absorbed_statement list
  ; facts : fact list
  ; revisions : revision list
  ; working_state : string option
  ; working_contexts : Keeper_librarian_context.pocket list
  }

let wire_field_new_claims = "new_claims"
let wire_field_dropped = "dropped"
let wire_field_claim = Keeper_memory_os_types.wire_field_claim
let wire_field_category = Keeper_memory_os_types.wire_field_category
let wire_field_memory_id = Keeper_memory_os_types.wire_field_memory_id
let wire_field_reason = Keeper_memory_os_types.wire_field_reason
let wire_field_supersedes = Keeper_memory_os_types.wire_field_supersedes
let wire_field_absorbs = Keeper_memory_os_types.wire_field_absorbs
let wire_claim_fields = Keeper_memory_os_types.wire_librarian_claim_fields
let wire_dropped_fields = Keeper_memory_os_types.wire_librarian_dropped_fields
let wire_field_working_state = "working_state"
let wire_field_working_contexts = "working_contexts"
let wire_current_fields =
  [ wire_field_new_claims; wire_field_dropped; wire_field_working_contexts
  ; wire_field_working_state ]

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

let basis_for_prompt ~by_identity = function
  | Observed _ as basis -> basis_to_json basis
  | Derived derivations ->
    (* Deduplicate before projection: distinct missing premises both become null. *)
    let premise_paths =
      List.map (fun proof -> (normalize_derivation proof).premise_ids) derivations
      |> List.sort_uniq (List.compare String.compare)
    in
    `Assoc
      [ wire_field_kind, `String "derived"
      ; wire_field_derivations,
        `List (List.map (fun premise_ids ->
          `List (List.map (fun identity ->
            String_map.find_opt identity by_identity
            |> Json_util.string_opt_to_json) premise_ids)) premise_paths)
      ]
;;

let current_fact_json ~by_identity index fact =
  `Assoc
    [ wire_field_memory_id, `String (surrogate_id_of_index index)
    ; ( "fact"
      , `Assoc
          [ wire_field_claim, `String fact.claim
          ; wire_field_category, `String (category_to_string fact.category)
          ; wire_field_origin,
            `Assoc [ wire_field_kind, `String (origin_kind_to_string fact.origin.kind) ]
          ; wire_field_basis, basis_for_prompt ~by_identity fact.basis
          ] )
    ]
;;

let current_selection_json (current : current_selection) =
  let by_identity =
    List.mapi (fun index fact -> memory_id fact, surrogate_id_of_index index) current.facts
    |> List.to_seq |> String_map.of_seq
  in
  `Assoc
    [ "facts", `List (List.mapi (current_fact_json ~by_identity) current.facts) ]
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

let goal_context_to_json = function
  | No_task -> `Assoc [ "status", `String "no_task" ]
  | Task_goals { task_id; criteria } ->
    let fields = match criteria with
      | Error detail -> [ "status", `String "unavailable"; "detail", `String detail ]
      | Ok goals ->
        [ "status", `String "available"
        ; "goals", `List (List.map (fun (goal_id, phase, criterion) ->
            `Assoc [ "goal_id", `String goal_id
                   ; "phase", `String (Goal_phase.to_string phase)
                   ; "criterion", Goal_store.criterion_to_yojson criterion ]) goals) ]
    in
    `Assoc (("task_id", `String task_id) :: fields)
;;

let prompt_variables (inp : input) : (string * string) list =
  [ ( "keeper_instructions"
    , format_keeper_instructions_for_prompt inp.keeper_instructions )
  ; "continuity", "null"
  ; "working_context", Yojson.Safe.to_string (Keeper_librarian_context.prompt_json inp.working_context)
  ; "goal_context", Yojson.Safe.to_string (goal_context_to_json inp.goal_context)
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

let continuity_prompt_variables (inp : input) ~continuity =
  [ ( "keeper_instructions"
    , format_keeper_instructions_for_prompt inp.keeper_instructions )
  ; "goal_context", Yojson.Safe.to_string (goal_context_to_json inp.goal_context)
  ; "current_memory", format_current_selection_for_prompt inp.current
  ; "continuity", Yojson.Safe.to_string continuity
  ]
;;

let working_context_prompt_variables (inp : input) =
  [ ( "keeper_instructions"
    , format_keeper_instructions_for_prompt inp.keeper_instructions )
  ; "goal_context", Yojson.Safe.to_string (goal_context_to_json inp.goal_context)
  ; "current_memory", format_current_selection_for_prompt inp.current
  ; "working_context", Yojson.Safe.to_string (Keeper_librarian_context.prompt_json inp.working_context)
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
  | Working_context_invalid of string
  | Working_state_invalid of string
  | Unexpected_field of string
  | Duplicate_field of string
  | Missing_required_fields
  | Claim_schema_mismatch
  | Dropped_schema_mismatch
  | Dropped_memory_id_recreated of string
  | Unknown_dropped_memory_id of string
  | Duplicate_dropped_memory_id of string
  | Supersedes_unknown_memory_id of string
  | Supersedes_not_dropped of string
  | Absorbs_unknown_memory_id of string
  | Absorbs_dropped_memory_id of string
  | Absorbs_memory_id_twice of string

let parse_error_to_string = function
  | Top_level_not_object -> "top_level_not_object"
  | Working_context_invalid detail -> "working_context_invalid: " ^ detail
  | Working_state_invalid detail -> "working_state_invalid: " ^ detail
  | Unexpected_field field -> "unexpected_field: " ^ field
  | Duplicate_field field -> "duplicate_field: " ^ field
  | Missing_required_fields -> "missing_required_fields"
  | Claim_schema_mismatch -> "claim_schema_mismatch"
  | Dropped_schema_mismatch -> "dropped_schema_mismatch"
  | Dropped_memory_id_recreated identity ->
    "dropped_memory_id_recreated: " ^ identity
  | Unknown_dropped_memory_id identity ->
    "unknown_dropped_memory_id: " ^ identity
  | Duplicate_dropped_memory_id identity ->
    "duplicate_dropped_memory_id: " ^ identity
  | Supersedes_unknown_memory_id token -> "supersedes_unknown_memory_id: " ^ token
  | Supersedes_not_dropped identity -> "supersedes_not_dropped: " ^ identity
  | Absorbs_unknown_memory_id token -> "absorbs_unknown_memory_id: " ^ token
  | Absorbs_dropped_memory_id identity -> "absorbs_dropped_memory_id: " ^ identity
  | Absorbs_memory_id_twice identity -> "absorbs_memory_id_twice: " ^ identity
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

(* A new claim as the answer states it: the fact, the short id it corrects in
   [supersedes], and the short ids it absorbs in [absorbs]. *)
type new_claim =
  { claim_fact : fact
  ; supersedes_token : string option
  ; absorbs_tokens : string list
  }

(* [supersedes] names, by its short id, the dropped memory this claim
   continues. Absent or null is a claim that continues nothing. [absorbs] names,
   by short id, the current memories this claim now says (RFC-0456 §4.2);
   absent, null or empty absorbs nothing. Any other value, or a list holding
   anything but non-blank strings, rejects the claim like any other malformed
   field. Whether the ids exist, and whether they were dropped, is checked once
   the ids are translated, where that answer lives. *)
let new_claim_of_json ~now (json : Yojson.Safe.t) : new_claim option =
  match fact_of_json ~now json, json with
  | Some fact, `Assoc fields ->
    let supersedes =
      match List.assoc_opt wire_field_supersedes fields with
      | None | Some `Null -> Some None
      | Some (`String raw) ->
        (match trim_nonempty raw with
         | Some token -> Some (Some token)
         | None -> None)
      | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _) -> None
    in
    let absorbs =
      match List.assoc_opt wire_field_absorbs fields with
      | None | Some `Null -> Some []
      | Some (`List items) ->
        traverse
          (function
            | `String raw -> trim_nonempty raw
            | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null -> None)
          items
      | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `String _) -> None
    in
    (match supersedes, absorbs with
     | Some supersedes_token, Some absorbs_tokens ->
       Some { claim_fact = fact; supersedes_token; absorbs_tokens }
     | None, _ | _, None -> None)
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
   unknown id names nothing. A claim that [ignored] names (a restatement of a
   memory another claim absorbs) continues nothing. *)
let translate_revisions ~by_surrogate ~(dropped : dropped_statement list) ~ignored pairs =
  let dropped_ids =
    List.fold_left
      (fun set (statement : dropped_statement) -> String_set.add statement.memory_id set)
      String_set.empty
      dropped
  in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | { supersedes_token = None; claim_fact = _; absorbs_tokens = _ } :: rest -> loop acc rest
    | { supersedes_token = Some token; claim_fact = fact; absorbs_tokens = _ } :: rest ->
      let identity = memory_id fact in
      (match String_map.find_opt token by_surrogate with
       | None -> Error (Supersedes_unknown_memory_id token)
       | Some _ when String_set.mem identity ignored -> loop acc rest
       | Some superseded ->
         if String_set.mem superseded dropped_ids
         then (
           let revision = { superseded; superseded_by = identity } in
           (* Two claims with the same text and the same [supersedes] are one
              revision. *)
           let same (other : revision) =
             String.equal other.superseded revision.superseded
             && String.equal other.superseded_by revision.superseded_by
           in
           if List.exists same acc then loop acc rest else loop (revision :: acc) rest)
         else Error (Supersedes_not_dropped superseded))
  in
  loop [] pairs
;;

let current_facts inp =
  match inp.current with
  | None -> []
  | Some current -> current.facts
;;

(* The librarian states only what changes: which memories to retire, and what
   to claim. A memory it does not name stays. That is what the apply step has
   always done -- [Keeper_memory_os_current] keeps every fact no dropped
   statement names -- so the whole-set roll call the answer used to carry was
   validated here and then discarded at apply time, while costing the librarian
   a correct restatement of every current identity on every pass. A single slip
   in that restatement threw the whole pass away, which made "retain everything,
   drop nothing, claim nothing" the one answer that always passed (RFC-0456).

   What is checked here is not what deserves to be remembered -- that is the
   librarian's judgment and no rule here narrows it. It is whether the answer
   refers to memories the librarian was actually shown, and whether it
   contradicts itself: a retired id has to name one of them, exactly once. A
   claim that repeats a current memory word for word is read as that memory,
   never as a reason to refuse the pass. *)

(* The fields of [kept] that [claim] states differently. *)
let differing_fields ~(kept : fact) (claim : fact) =
  let category =
    if String.equal
         (Keeper_memory_os_types.category_to_string kept.category)
         (Keeper_memory_os_types.category_to_string claim.category)
    then []
    else [ Claim_category ]
  in
  let basis =
    if Yojson.Safe.equal
         (Keeper_memory_os_types.basis_to_json kept.basis)
         (Keeper_memory_os_types.basis_to_json claim.basis)
    then []
    else [ Claim_basis ]
  in
  category @ basis
;;

(* [memory_id] is the claim's own bytes, so two claims with the same text are
   one memory. They become one claim: the first keeps its fields and gains the
   [absorbs] ids the later one adds. A list that names an id twice still names
   it twice, so {!translate_absorbs} still refuses it. A later claim whose
   fields differ from the first one's is named in the second result. *)
let merge_same_claims stated_claims =
  let same identity claim = String.equal (memory_id claim.claim_fact) identity in
  let rec loop acc ignored_rev = function
    | [] -> List.rev acc, List.rev ignored_rev
    | claim :: rest ->
      let identity = memory_id claim.claim_fact in
      (match List.find_opt (same identity) acc with
       | None -> loop (claim :: acc) ignored_rev rest
       | Some first ->
         let added =
           List.filter
             (fun token -> not (List.exists (String.equal token) first.absorbs_tokens))
             claim.absorbs_tokens
         in
         let merged = { first with absorbs_tokens = first.absorbs_tokens @ added } in
         let ignored_rev =
           match differing_fields ~kept:first.claim_fact claim.claim_fact with
           | [] -> ignored_rev
           | differing ->
             { restated_id = identity; kept_from = First_claim; differing } :: ignored_rev
         in
         loop
           (List.map (fun kept -> if same identity kept then merged else kept) acc)
           ignored_rev
           rest)
  in
  loop [] [] stated_claims
;;

(* The identities of claims that restate a current memory another claim of the
   same answer absorbs. A restatement adds nothing, so the absorption wins and
   the claim is read as not written. That includes its own [absorbs]: a memory
   it names there stays current, which is what an absorption that is not
   applied always does. A restatement of a memory the answer drops is not
   here: that says both "gone" and "kept", and {!materialize_facts} refuses it. *)
let ignored_restatements ~by_surrogate ~current_ids merged_claims =
  let absorbed_by_another =
    List.fold_left
      (fun ids claim ->
         let into = memory_id claim.claim_fact in
         List.fold_left
           (fun ids token ->
              match String_map.find_opt token by_surrogate with
              | Some absorbed when not (String.equal absorbed into) ->
                String_set.add absorbed ids
              | Some _ | None -> ids)
           ids
           claim.absorbs_tokens)
      String_set.empty
      merged_claims
  in
  List.fold_left
    (fun ids claim ->
       let identity = memory_id claim.claim_fact in
       if String_set.mem identity current_ids && String_set.mem identity absorbed_by_another
       then String_set.add identity ids
       else ids)
    String_set.empty
    merged_claims
;;

(* An absorbed memory has to be one the librarian saw, has to still be current
   in the answer (a dropped one is gone, not said by the new claim), and can be
   said by one new claim only. A claim that writes a current memory again as it
   stands is that memory, so its own id in its [absorbs] asks for nothing: the
   memory stays, and no absorption row says it went into itself. *)
let translate_absorbs ~by_surrogate ~(dropped : dropped_statement list) new_claims =
  let dropped_ids =
    List.fold_left
      (fun set (statement : dropped_statement) -> String_set.add statement.memory_id set)
      String_set.empty
      dropped
  in
  let rec tokens seen acc ~into = function
    | [] -> Ok (seen, acc)
    | token :: rest ->
      (match String_map.find_opt token by_surrogate with
       | None -> Error (Absorbs_unknown_memory_id token)
       | Some absorbed when String.equal absorbed into -> tokens seen acc ~into rest
       | Some absorbed ->
         if String_set.mem absorbed dropped_ids
         then Error (Absorbs_dropped_memory_id absorbed)
         else if String_set.mem absorbed seen
         then Error (Absorbs_memory_id_twice absorbed)
         else
           tokens
             (String_set.add absorbed seen)
             ({ Keeper_memory_os_types.absorbed; into } :: acc)
             ~into
             rest)
  in
  let rec claims seen acc = function
    | [] -> Ok (List.rev acc)
    | claim :: rest ->
      (match tokens seen acc ~into:(memory_id claim.claim_fact) claim.absorbs_tokens with
       | Ok (seen, acc) -> claims seen acc rest
       | Error _ as error -> error)
  in
  claims String_set.empty [] new_claims
;;

type materialized =
  { facts_after : fact list
  ; adds : fact list
  ; restatements : fact list
  ; restatement_fields : ignored_fields list
  }

(* The facts after the answer, the claims it adds to them, and the current
   memories it wrote again. [new_claims] has no restatement of a memory another
   claim absorbs ({!ignored_restatements} took those out). A claim naming a
   memory the same answer drops, directly or as the target of its own
   [supersedes], says both "gone" and "kept", so the answer is refused. Any
   other claim whose identity is current is a memory the answer keeps: it adds
   nothing, and the stored fact keeps its first sighting and its fields. *)
let materialize_facts ~current_facts ~new_claims ~dropped ~absorbed =
  let open Result.Syntax in
  let current_by_id = current_facts_by_id current_facts in
  let rec validate_dropped seen = function
    | [] -> Ok seen
    | (statement : dropped_statement) :: rest ->
      if String_set.mem statement.memory_id seen
      then Error (Duplicate_dropped_memory_id statement.memory_id)
      else if not (String_map.mem statement.memory_id current_by_id)
      then Error (Unknown_dropped_memory_id statement.memory_id)
      else validate_dropped (String_set.add statement.memory_id seen) rest
  in
  let* dropped_ids = validate_dropped String_set.empty dropped in
  let absorbed_ids =
    List.fold_left
      (fun ids (statement : Keeper_memory_os_types.absorbed_statement) ->
         String_set.add statement.absorbed ids)
      String_set.empty
      absorbed
  in
  let retained =
    List.filter
      (fun fact ->
         let identity = memory_id fact in
         not (String_set.mem identity dropped_ids || String_set.mem identity absorbed_ids))
      current_facts
  in
  let rec split (added_rev, restated_rev, ignored_rev) = function
    | [] -> Ok (added_rev, restated_rev, ignored_rev)
    | claim :: rest ->
      let identity = memory_id claim in
      if String_set.mem identity dropped_ids
      then Error (Dropped_memory_id_recreated identity)
      else
        split
          (match String_map.find_opt identity current_by_id with
           | None -> claim :: added_rev, restated_rev, ignored_rev
           | Some stored ->
             let ignored_rev =
               match differing_fields ~kept:stored claim with
               | [] -> ignored_rev
               | differing ->
                 { restated_id = identity; kept_from = Current_memory; differing }
                 :: ignored_rev
             in
             added_rev, stored :: restated_rev, ignored_rev)
          rest
  in
  let+ (added_rev, restated_rev, ignored_rev) = split ([], [], []) new_claims in
  let added = List.rev added_rev in
  { facts_after = retained @ added
  ; adds = added
  ; restatements = List.rev restated_rev
  ; restatement_fields = List.rev ignored_rev
  }
;;

(* What the store is asked to add: the new claims, and each restated memory
   that some applied absorption goes into. The store skips an identity it
   still holds, so a restated memory is added again only when the keeper took
   it away during the pass; without it the absorbed memories would leave and
   their rows would point into an id no snapshot has. A restatement nothing
   goes into stays a restatement: the keeper's retraction stands. *)
let claims_to_apply (selection : selection) ~(absorbed : Keeper_memory_os_types.absorbed_statement list) =
  let intos =
    List.fold_left
      (fun ids (statement : Keeper_memory_os_types.absorbed_statement) ->
         String_set.add statement.into ids)
      String_set.empty
      absorbed
  in
  selection.new_claims
  @ List.filter (fun fact -> String_set.mem (memory_id fact) intos) selection.restated
;;

let working_contexts_of_json (inp : input) json =
  Keeper_librarian_context.select inp.working_context json
  |> Result.map_error (fun detail -> Working_context_invalid detail)
;;

(* A context-only answer is one field. The object check is the same one the
   Memory answer passes, with the allowed set narrowed to that field. *)
let single_field_of_json_result ~field json =
  match json with
  | `Assoc fields ->
    (match first_object_field_error ~allowed:[ field ] fields with
     | Some (Unexpected_object_field name) -> Error (Unexpected_field name)
     | Some (Duplicate_object_field name) -> Error (Duplicate_field name)
     | None ->
       (match List.assoc_opt field fields with
        | None -> Error Missing_required_fields
        | Some value -> Ok value))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error Top_level_not_object
;;

let working_state_of_json_result json =
  Result.bind (single_field_of_json_result ~field:wire_field_working_state json)
    (function
      | `String text when String.trim text <> "" -> Ok text
      | `String _ | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null ->
        Error (Working_state_invalid "working_state must be nonblank text"))
;;

let working_contexts_of_json_result (inp : input) json =
  Result.bind (single_field_of_json_result ~field:wire_field_working_contexts json)
    (working_contexts_of_json inp)
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
       let open Result.Syntax in
       let* working_state = match List.assoc_opt wire_field_working_state fields with
         | None | Some `Null -> Ok None
         | Some (`String text) when String.trim text <> "" -> Ok (Some text)
         | Some _ -> Error (Working_state_invalid "working_state must be nonblank text or null") in
       let* working_contexts =
         match List.assoc_opt wire_field_working_contexts fields with
         | None -> Error Missing_required_fields
         | Some json -> working_contexts_of_json inp json
       in
       (match
          List.assoc_opt wire_field_new_claims fields
          , List.assoc_opt wire_field_dropped fields
        with
        | Some (`List claim_items), Some (`List dropped_items) ->
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
                 | Some stated_claims, Some dropped ->
                   let merged_claims, same_text_fields = merge_same_claims stated_claims in
                   let current = current_facts inp in
                   let by_surrogate = surrogate_identity_map current in
                   let* dropped = translate_dropped_ids ~by_surrogate dropped in
                   let ignored =
                     ignored_restatements
                       ~by_surrogate
                       ~current_ids:
                         (String_set.of_list (List.map memory_id current))
                       merged_claims
                   in
                   let applied_claims =
                     List.filter
                       (fun claim ->
                          not (String_set.mem (memory_id claim.claim_fact) ignored))
                       merged_claims
                   in
                   let* absorbed = translate_absorbs ~by_surrogate ~dropped applied_claims in
                   let* materialized =
                     materialize_facts
                       ~current_facts:current
                       ~new_claims:(List.map (fun claim -> claim.claim_fact) applied_claims)
                       ~dropped
                       ~absorbed
                   in
                   let+ revisions =
                     translate_revisions ~by_surrogate ~dropped ~ignored stated_claims
                   in
                   { new_claims = materialized.adds
                   ; restated = materialized.restatements
                   ; ignored_fields = same_text_fields @ materialized.restatement_fields
                   ; dropped
                   ; absorbed
                   ; facts = materialized.facts_after
                   ; revisions
                   ; working_state
                   ; working_contexts
                   }
                 | Some _, None -> Error Dropped_schema_mismatch
                 | None, _ -> Error Claim_schema_mismatch)))
        | _ -> Error Missing_required_fields))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error Top_level_not_object
;;
