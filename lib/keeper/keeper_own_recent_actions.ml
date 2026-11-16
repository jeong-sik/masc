type outcome =
  | Ok_call
  | Failed_call of string option
  | Deferred_call
  | Unrecorded_call

type provenance = { task_id : string option; trace_id : string option }
type task_relation = Selected_task | Other_task | Unknown_task

let task_relation ~current_task_id provenance =
  match provenance.task_id with
  | None -> Unknown_task
  | Some task_id ->
    if current_task_id = Some task_id then Selected_task else Other_task

let provenance_to_json ~current_task_id provenance =
  let optional = function None -> `Null | Some value -> `String value in
  let relation = match task_relation ~current_task_id provenance with
    | Selected_task -> "selected_task" | Other_task -> "other_task"
    | Unknown_task -> "unknown_task" in
  `Assoc ["task_relation", `String relation;
          "task_id", optional provenance.task_id;
          "trace_id", optional provenance.trace_id]

type input =
  | Arguments of string
  | Artifact_reference
  | Unstated_input

let compare_input left right =
  match left, right with
  | Arguments l, Arguments r -> String.compare l r
  | Arguments _, (Artifact_reference | Unstated_input) -> -1
  | Artifact_reference, Arguments _ -> 1
  | Artifact_reference, Artifact_reference -> 0
  | Artifact_reference, Unstated_input -> -1
  | Unstated_input, (Arguments _ | Artifact_reference) -> 1
  | Unstated_input, Unstated_input -> 0
;;

type call =
  { tool : string
  ; input : input
  ; provenance : provenance
  ; source_position : int
  ; outcome : outcome
  }

type turn =
  { turn_id : int
  ; calls : call list
  }

(* Sizing hint for the read window, not a bound on any row: how many calls a
   turn typically makes. Measured on a live Keeper over 932 calls --
   median 8 per turn, p90 21. Reading short costs turns, never a partial turn:
   only the oldest group can be clipped by the window edge, and
   {!turns_of_rows} drops it. *)
let typical_calls_per_turn = 24

let string_field name json =
  match Json_util.assoc_member_opt name json with
  | Some (`String s) -> Some s
  | _ -> None
;;

let provenance_of_row json =
  let identity name = match string_field name json with
    | Some value when String.trim value <> "" -> Some value
    | Some _ | None -> None in
  {task_id=identity "task_id"; trace_id=identity "trace_id"}

(* The writer persists [keeper_turn_id] as an integer. A row whose id is not one
   cannot be ordered against the others, so it is dropped with the unattributed
   rows rather than folded into an adjacent turn. *)
let turn_id_field json =
  match Json_util.assoc_member_opt "keeper_turn_id" json with
  | Some (`String s) -> int_of_string_opt (String.trim s)
  | Some (`Int i) -> Some i
  | _ -> None
;;

(* Only a refusal carries its output. What a successful call returned is not
   what the keeper needs -- that the call landed is the fact -- and it is where
   the bytes are: measured 2026-08-16, a success returns a median 1310 bytes
   against a refusal's 417 (max 2116). Carrying both would put a 10-turn window
   over 80 KB for no added recall, and would force a truncation rule over the
   exact text the keeper has to read to recognise its mistake.

   A refusal the tool did not describe stays [None]. Substituting an empty
   string would render as a refusal with no reason, indistinguishable from one
   the tool declined to explain.

   A row that does not say how the call ended is [Unrecorded_call], not a
   refusal: only a refusal carries its input back to the keeper. *)
let outcome_of_row json =
  match Tool_result.recorded_call_outcome json with
  | Tool_result.Recorded_succeeded -> Ok_call
  | Tool_result.Recorded_failed -> Failed_call (string_field "output" json)
  | Tool_result.Recorded_deferred -> Deferred_call
  | Tool_result.Recorded_unsettled | Tool_result.Recorded_malformed -> Unrecorded_call
;;

(* The request history stores an earlier call's arguments as the reserved
   [_blob] reference, and a model that copies that object into a new call is
   refused before the handler runs (2026-11-02: 377 calls). Replaying the object
   on the refusal row teaches the same shape again, so the form the writer
   recorded decides, and a reference is carried as a variant, never as
   argument text. *)
(* A row that does not state its form (an earlier build's, or a damaged one)
   cannot be told from a reference: its persisted input may be a preview
   string. It is neither read as arguments nor dropped, which would leave its
   turn rendered with a call missing; it stays as [Unstated_input]. *)
let input_of_row json =
  match Keeper_tool_call_log.recorded_input_form json with
  | Some Keeper_tool_call_log.Artifact_reference_input -> Artifact_reference
  | None -> Unstated_input
  | Some Keeper_tool_call_log.Arguments_input ->
    Arguments
      (match Json_util.assoc_member_opt "input" json with
       | None | Some `Null -> "{}"
       | Some (`String s) -> s
       | Some value -> Yojson.Safe.to_string value)
;;

let call_of_row ~source_position json =
  match string_field "tool" json with
  | None -> None
  | Some tool ->
    Some { tool; input = input_of_row json; provenance = provenance_of_row json;
           source_position; outcome = outcome_of_row json }
;;

(* A saturated tail read starts mid-turn, so its oldest group is missing that
   turn's earliest calls. Rendering a turn with some calls silently absent is
   worse than not rendering it: the keeper would read a complete-looking
   history that omits the call it needs to see. *)
type execution_identity = Recorded_trace of string | Unattributed_occurrence of int

let compare_execution_identity left right =
  match left, right with
  | Recorded_trace l, Recorded_trace r -> String.compare l r
  | Recorded_trace _, Unattributed_occurrence _ -> -1
  | Unattributed_occurrence _, Recorded_trace _ -> 1
  | Unattributed_occurrence l, Unattributed_occurrence r -> Int.compare l r
;;

let equal_execution_identity left right =
  compare_execution_identity left right = 0
;;

module Turn_key_map = Map.Make (struct
    type t = execution_identity * int

    let compare (exec_l, turn_l) (exec_r, turn_r) =
      let c = compare_execution_identity exec_l exec_r in
      if c <> 0 then c else Int.compare turn_l turn_r
  end)

let compare_provenance (left : provenance) (right : provenance) =
  let c = Option.compare String.compare left.task_id right.task_id in
  if c <> 0
  then c
  else Option.compare String.compare left.trace_id right.trace_id
;;

module Failure_key_map = Map.Make (struct
    type t = string * input * provenance * int option

    let compare (tool_l, input_l, prov_l, turn_l) (tool_r, input_r, prov_r, turn_r) =
      let c = String.compare tool_l tool_r in
      if c <> 0
      then c
      else (
        let c = compare_input input_l input_r in
        if c <> 0
        then c
        else (
          let c = compare_provenance prov_l prov_r in
          if c <> 0
          then c
          else Option.compare Int.compare turn_l turn_r))
  end)

(* A missing trace does not authorize joining an earlier equal turn number.
   Preserve only its contiguous occurrence, including across clipping. *)
let rows_with_turn_keys rows =
  let _, rev_rows =
    List.fold_left
      (fun (previous, (position, acc)) row ->
         let keeper = string_field "keeper" row in
         let key =
           match turn_id_field row with
           | None -> None
           | Some turn_id ->
             let execution =
               match (provenance_of_row row).trace_id with
               | Some trace -> Recorded_trace trace
               | None ->
                 (match previous with
                  | Some
                      ( prior_keeper
                      , (Unattributed_occurrence _ as identity)
                      , prior_turn )
                    when Option.equal String.equal prior_keeper keeper
                         && Int.equal prior_turn turn_id -> identity
                  | None
                  | Some (_, (Recorded_trace _ | Unattributed_occurrence _), _) ->
                    Unattributed_occurrence position)
             in
             Some (execution, turn_id)
         in
         let next_previous =
           Option.map (fun (execution, turn) -> keeper, execution, turn) key
         in
         next_previous, (position + 1, (position, key, row) :: acc))
      (None, (0, []))
      rows
  in
  List.rev (snd rev_rows)
;;

let equal_turn_key (exec_l, turn_l) (exec_r, turn_r) =
  equal_execution_identity exec_l exec_r && Int.equal turn_l turn_r
;;

let drop_clipped_leading_turn rows =
  match List.find_map (fun (_, key, _) -> key) rows with
  | None -> rows
  | Some clipped ->
    List.filter
      (fun (_, key, _) -> not (Option.equal equal_turn_key key (Some clipped)))
      rows
;;

let turns_of_rows ~keeper_name ~max_turns ~window_saturated rows =
  if max_turns <= 0
  then []
  else (
    let rows = rows_with_turn_keys rows in
    let rows = if window_saturated then drop_clipped_leading_turn rows else rows in
    (* One pass in persisted order builds each turn's call list; the turn order
       is then the order the turns first appeared, so both stay source order
       without a sort. *)
    let rev_order, calls_by_turn =
      List.fold_left
        (fun (rev_order, calls_by_turn) (source_position, key, row) ->
           match string_field "keeper" row, key, call_of_row ~source_position row with
           | Some k, Some turn_id, Some call when String.equal k keeper_name ->
             (match Turn_key_map.find_opt turn_id calls_by_turn with
              | None ->
                ( turn_id :: rev_order
                , Turn_key_map.add turn_id [ call ] calls_by_turn )
              | Some existing ->
                ( rev_order
                , Turn_key_map.add turn_id (call :: existing) calls_by_turn ))
           | _ -> rev_order, calls_by_turn)
        ([], Turn_key_map.empty)
        rows
    in
    let ordered = List.rev rev_order in
    let keep = max 0 (List.length ordered - max_turns) in
    ordered
    |> List.filteri (fun i _ -> i >= keep)
    |> List.map (fun turn_id ->
      let rev_calls =
        Option.value ~default:[] (Turn_key_map.find_opt turn_id calls_by_turn)
      in
      { turn_id = snd turn_id; calls = List.rev rev_calls }))
;;

(* The salience problem this answers: a 12-turn window renders as a hundred
   or more one-line calls in which a handful of refusals sit buried, and the
   keeper repeats the rejected call anyway (2026-08-28: a keeper re-read the
   same nonexistent paths every autonomous turn, 61 distinct paths over a
   day, while every one of those refusals was already inside this window).
   The digest lifts the failures out deduped: one row per distinct rejected
   (tool, input, provenance), counted, with the newest refusal's detail. *)
type failure_digest =
  { failure_tool : string
  ; failure_input : input
  ; failure_count : int
  ; failure_detail : string option
  ; failure_provenance : provenance
  ; failure_last_turn : int
  }

type failure_accumulator =
  { acc_tool : string
  ; acc_input : input
  ; acc_provenance : provenance
  ; acc_count : int
  ; acc_detail : string option
  ; acc_last_turn : int
  ; acc_last_position : int
  }

let digest_failures ?(limit = 8) (turns : turn list) : failure_digest list =
  (* Grouped turns can interleave in the original log. The source ordinal,
     not traversal order or trace-local turn number, owns recency. *)
  let _, by_key =
    List.fold_left
      (fun (position, by_key) (turn : turn) ->
         let by_key =
           List.fold_left
             (fun by_key (call : call) ->
                match call.outcome with
                | Ok_call | Deferred_call | Unrecorded_call -> by_key
                | Failed_call detail ->
                  let unknown_turn =
                    match call.provenance.task_id, call.provenance.trace_id with
                    | Some _, Some _ -> None
                    | None, _ | _, None -> Some position
                  in
                  let key = call.tool, call.input, call.provenance, unknown_turn in
                  let updated =
                    match Failure_key_map.find_opt key by_key with
                    | None ->
                      { acc_tool = call.tool
                      ; acc_input = call.input
                      ; acc_provenance = call.provenance
                      ; acc_count = 1
                      ; acc_detail = detail
                      ; acc_last_turn = turn.turn_id
                      ; acc_last_position = call.source_position
                      }
                    | Some prior ->
                      if call.source_position > prior.acc_last_position
                      then
                        { prior with
                          acc_count = prior.acc_count + 1
                        ; acc_detail = detail
                        ; acc_last_turn = turn.turn_id
                        ; acc_last_position = call.source_position
                        }
                      else { prior with acc_count = prior.acc_count + 1 }
                  in
                  Failure_key_map.add key updated by_key)
             by_key
             turn.calls
         in
         position + 1, by_key)
      (0, Failure_key_map.empty)
      turns
  in
  Failure_key_map.fold
    (fun _key entry acc ->
       ( entry.acc_last_position
       , { failure_tool = entry.acc_tool
         ; failure_input = entry.acc_input
         ; failure_count = entry.acc_count
         ; failure_detail = entry.acc_detail
         ; failure_provenance = entry.acc_provenance
         ; failure_last_turn = entry.acc_last_turn
         } )
       :: acc)
    by_key
    []
  |> List.sort (fun left right -> Int.compare (fst right) (fst left))
  |> List.filteri (fun index _ -> index < limit)
  |> List.map snd
;;

let collect ~keeper_name ~max_turns =
  if max_turns <= 0
  then Ok []
  else begin
    (* One turn's worth of slack, so discarding the clipped group still leaves
       [max_turns] whole ones. *)
    let n = (max_turns + 1) * typical_calls_per_turn in
    Result.map
      (fun rows ->
         (* Short of the window means the store held nothing older, so nothing
            was cut. *)
         turns_of_rows
           ~keeper_name ~max_turns
           ~window_saturated:(List.length rows >= n)
           rows)
      (Keeper_tool_call_log.read_recent ~keeper_name ~n ())
  end
;;

let externalize_failures ~base_path ~keeper_name ~tools turns =
  match Keeper_recovery_transmission.require_reader tools with
  | Error _ -> turns
  | Ok _ ->
    let store = Tool_blob_store.create ~base_path in
    let externalize text =
      match Tool_output.decode_from_agent_core text with
      | Tool_output.Decoded _ | Tool_output.Invalid_marker _ -> text
      | Tool_output.Not_marker ->
        let stored = Tool_blob_store.put store ~bytes:text ~mime:"text/plain" in
        let marker = Tool_output.encode_for_agent_core stored in
        (* The briefing is transmitted inside a JSON string. A reference must
           reduce those exact encoded bytes, not just the unescaped body. *)
        let encoded_bytes text = String.length (Yojson.Safe.to_string (`String text)) in
        if encoded_bytes marker < encoded_bytes text then marker else text in
    let failed = ref 0 in
    let turns = List.map (fun (turn : turn) ->
      let calls = List.map (fun (call : call) ->
        match call.outcome, call.input with
        | (Ok_call | Deferred_call | Unrecorded_call),
          (Arguments _ | Artifact_reference | Unstated_input) -> call
        (* Neither such an input nor its refusal text is rendered, so nothing
           is stored for them. *)
        | Failed_call _, (Artifact_reference | Unstated_input) -> call
        | Failed_call detail, Arguments text ->
          (try
             let input = Arguments (externalize text) in
             let detail = Option.map externalize detail in
             {call with input; outcome=Failed_call detail}
           with Sys_error _ -> incr failed; call)) turn.calls in
      {turn with calls}) turns in
    if !failed > 0 then Log.Keeper.warn ~keeper_name
      "action briefing retained original failed-call payloads: storage failed for %d calls" !failed;
    turns
;;
