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

type selection =
  { new_claims : fact list
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
let wire_current_fields =
  [ wire_field_new_claims; wire_field_dropped; "working_contexts"; "working_state" ]

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
  | Absorbed_memory_id_restated of string
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
  | Absorbed_memory_id_restated identity ->
    "absorbed_memory_id_restated: " ^ identity
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
    | { supersedes_token = None; claim_fact = _; absorbs_tokens = _ } :: rest -> loop acc rest
    | { supersedes_token = Some token; claim_fact = fact; absorbs_tokens = _ } :: rest ->
      (match String_map.find_opt token by_surrogate with
       | None -> Error (Supersedes_unknown_memory_id token)
       | Some superseded ->
         if String_set.mem superseded dropped_ids
         then (
           let revision = { superseded; superseded_by = memory_id fact } in
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
   contradicts itself: a retired id has to name one of them, exactly once, and a
   memory the answer retires or absorbs cannot also be claimed in it. *)

(* [memory_id] is the claim's own bytes, so two claims with the same text are
   one memory. They become one claim: the first keeps its fields and gains the
   [absorbs] ids the later one adds. A list that names an id twice still names
   it twice, so {!translate_absorbs} still refuses it. *)
let merge_same_claims stated_claims =
  let same identity claim = String.equal (memory_id claim.claim_fact) identity in
  let rec loop acc = function
    | [] -> List.rev acc
    | claim :: rest ->
      let identity = memory_id claim.claim_fact in
      (match List.find_opt (same identity) acc with
       | None -> loop (claim :: acc) rest
       | Some first ->
         let added =
           List.filter
             (fun token -> not (List.exists (String.equal token) first.absorbs_tokens))
             claim.absorbs_tokens
         in
         let merged = { first with absorbs_tokens = first.absorbs_tokens @ added } in
         loop
           (List.map (fun kept -> if same identity kept then merged else kept) acc)
           rest)
  in
  loop [] stated_claims
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

(* The facts after the answer, and the claims it adds to them. A claim whose
   identity is a current memory the answer keeps is that memory written again:
   it adds nothing, and the stored fact keeps its first sighting and basis. A
   claim naming a memory the same answer drops or absorbs says both "gone" and
   "kept" about one memory, so the answer is refused. *)
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
  let rec added added_rev = function
    | [] -> Ok (List.rev added_rev)
    | fact :: rest ->
      let identity = memory_id fact in
      if String_set.mem identity dropped_ids
      then Error (Dropped_memory_id_recreated identity)
      else if String_set.mem identity absorbed_ids
      then Error (Absorbed_memory_id_restated identity)
      else if String_map.mem identity current_by_id
      then added added_rev rest
      else added (fact :: added_rev) rest
  in
  let+ added = added [] new_claims in
  retained @ added, added
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
       let* working_state = match List.assoc_opt "working_state" fields with
         | None | Some `Null -> Ok None
         | Some (`String text) when String.trim text <> "" -> Ok (Some text)
         | Some _ -> Error (Working_state_invalid "working_state must be nonblank text or null") in
       let* working_contexts =
         match List.assoc_opt "working_contexts" fields with
         | None -> Error Missing_required_fields
         | Some json -> Keeper_librarian_context.select inp.working_context json
             |> Result.map_error (fun detail -> Working_context_invalid detail)
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
                   let merged_claims = merge_same_claims stated_claims in
                   let new_claims =
                     List.map (fun claim -> claim.claim_fact) merged_claims
                   in
                   let by_surrogate =
                     surrogate_identity_map (current_facts inp)
                   in
                   (match translate_dropped_ids ~by_surrogate dropped with
                   | Ok dropped ->
                     (match translate_absorbs ~by_surrogate ~dropped merged_claims with
                      | Ok absorbed ->
                        (match
                           materialize_facts
                             ~current_facts:(current_facts inp)
                             ~new_claims
                             ~dropped
                             ~absorbed
                         with
                         | Ok (facts, new_claims) ->
                           (match
                              translate_revisions ~by_surrogate ~dropped stated_claims
                            with
                            | Ok revisions ->
                              Ok
                                { new_claims
                                ; dropped
                                ; absorbed
                                ; facts
                                ; revisions
                                ; working_state
                                ; working_contexts
                                }
                            | Error _ as error -> error)
                         | Error _ as error -> error)
                      | Error _ as error -> error)
                   | Error _ as error -> error)
                 | Some _, None -> Error Dropped_schema_mismatch
                 | None, _ -> Error Claim_schema_mismatch)))
        | _ -> Error Missing_required_fields))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error Top_level_not_object
;;
