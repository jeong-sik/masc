(** Tool_task_args — task-tool argument parsing helpers.

    Pure JSON parsers and per-action argument predicates. No [context],
    no IO. Returns [Result] / [option] values that the caller (the
    {!Tool_task} facade) folds into the dispatch pipeline.

    @since God file decomposition — extracted from tool_task.ml *)

let parse_task_contract args =
  match Json_util.assoc_member_opt "contract" args with
  | None | Some `Null -> Ok None
  | Some (`Assoc _ as json) -> (
      match Masc_domain.task_contract_of_yojson json with
      | Ok contract -> Ok (Some contract)
      | Error error ->
          Error
            (Printf.sprintf "Invalid contract payload: %s" error))
  | Some other ->
      Error
        (Printf.sprintf
           "contract must be an object when provided (received %s)"
           (Json_util.kind_name other))

let is_internal_marker key =
  String.length key > 0 && Char.equal key.[0] '_'

let unknown_args ~valid_keys args =
  match args with
  | `Assoc kvs ->
      kvs
      |> List.filter (fun (key, _) ->
             (not (is_internal_marker key)) && not (List.mem key valid_keys))
      |> List.map fst
  | _ -> []

(* Synthesize a summary from sibling [notes] / [reason] transition args
   when [handoff_context.summary] is empty. Agent runtimes frequently send
   a non-empty [reason] or [notes] but forget the nested summary field —
   rejecting the call in that case burned 76/132 masc_transition calls
   on 2026-04-17/18 (see memory/handoff-2026-04-18-masc-tool-failure-
   investigation.md). Prefer [notes] when present (it's the canonical
   done-note) then fall back to [reason] (release blocker note). Truncate
   to keep the synthesized summary single-line. *)
let synthesize_summary_from_siblings args =
  let pick key =
    match Json_util.assoc_member_opt key args with
    | Some (`String s) ->
        let trimmed = String.trim s in
        if String.equal trimmed "" then None else Some trimmed
    | _ -> None
  in
  let first_line s =
    match String.index_opt s '\n' with
    | Some i -> String.sub s 0 i
    | None -> s
  in
  let truncate ~max_len s =
    if String.length s <= max_len then s
    else String.sub s 0 max_len ^ "…"
  in
  match pick "notes" with
  | Some s -> Some (truncate ~max_len:240 (first_line s))
  | None ->
      match pick "reason" with
      | Some s -> Some (truncate ~max_len:240 (first_line s))
      | None -> None

(* A transition's [handoff_context.summary] is only meaningful when the
   action represents a *work-state exit* — the agent is reporting the
   outcome of work it did. Pure ownership transitions (Claim, Start)
   have no outcome to summarize yet, so requiring a summary just makes
   the LLM either invent one (degrading audit signal) or fail the call
   entirely (the 2026-05-17 nick0cave production case).

   Exit-class actions:
     Done_action / Cancel / Release / Submit_for_verification /
     Approve_verification / Reject_verification
   Entry-class actions (no summary required):
     Claim / Start

   This split is exhaustive over [Masc_domain.task_action]; adding a
   new variant forces a compile-time decision here, not a runtime
   permissive default. *)
let transition_action_requires_summary : Masc_domain.task_action -> bool =
  function
  | Masc_domain.Done_action
  | Masc_domain.Cancel
  | Masc_domain.Release
  | Masc_domain.Submit_for_verification
  | Masc_domain.Approve_verification
  | Masc_domain.Reject_verification ->
    true
  | Masc_domain.Claim | Masc_domain.Start ->
    false

let parse_handoff_context ~(agent_name : string)
    ~(action : Masc_domain.task_action) args =
  let summary_required = transition_action_requires_summary action in
  match Json_util.assoc_member_opt "handoff_context" args with
  | None | Some `Null ->
    (* No handoff_context object provided. For entry-class actions this
       is the expected shape; for exit-class actions the caller's
       strict-release / contract checks downstream will surface the
       missing summary if the task contract demands it. We do not
       fabricate an empty handoff_context here. *)
    Ok None
  | Some (`Assoc _ as json) -> (
      match Masc_domain.task_handoff_context_of_yojson json with
      | Error error ->
          Error
            (Printf.sprintf "Invalid handoff_context payload: %s" error)
      | Ok handoff_context ->
          let summary = String.trim handoff_context.summary in
          let summary =
            if String.equal summary "" then
              Option.value ~default:"" (synthesize_summary_from_siblings args)
            else summary
          in
          if String.equal summary "" then
            if summary_required then
              Error
                (Printf.sprintf
                   "handoff_context.summary is required for action=%s \
                    (non-empty string). Example: {\"summary\": \"tests \
                    green, local proof saved\", \"next_step\": \"wait \
                    for CI\", \"evidence_refs\": [\".masc/harness-evidence/proof.json\"]}. \
                    Alternatively pass a non-empty top-level 'notes' or \
                    'reason' and it will be synthesized into summary \
                    automatically."
                   (Masc_domain.task_action_to_string action))
            else
              (* Entry-class action (claim/start) with an empty
                 handoff_context object. The summary is meaningless at
                 work entry; treat the empty context as absent rather
                 than failing the call. *)
              Ok None
          else
            Ok
              (Some
                 {
                   handoff_context with
                   summary;
                   evidence_refs =
                     Tool_task_completion_review.non_empty_trimmed_strings
                       handoff_context.evidence_refs;
                   updated_at = Some (Masc_domain.now_iso ());
                   updated_by = Some agent_name;
                 }))
  | Some other ->
      Error
        (Printf.sprintf
           "handoff_context must be an object when provided (received %s)"
           (Json_util.kind_name other))

let transition_known_args =
  [
    "task_id";
    "action";
    "notes";
    "reason";
    "expected_version";
    "agent_name";
    "force";
    "completion_contract";
    "evaluator_runtime";
    "handoff_context";
  ]
