module Draft = Artifact_draft
module Store = Artifact_draft_store
module Scope = Keeper_artifact_draft_scope
module Discovery = Keeper_artifact_discovery
open Result.Syntax
type command =
  | Draft_command of Draft.command
  | Read of Draft.target
  | Leave of Draft.target
  | Find of Discovery.query
  | Published of string
  | Checkpoint of { target : Draft.target; expected_sequence : int; revision : int }

let checkpoint_of_json = function
  | `Assoc fields ->
    let names = List.map fst fields in
    if List.length names <> List.length (List.sort_uniq String.compare names)
       || List.exists (fun name -> not (List.mem name ["action"; "target"; "expected_sequence"; "revision"])) names
    then Error "duplicate or unknown checkpoint field"
    else
      let* target = match List.assoc_opt "target" fields with
        | Some json -> Draft.target_of_json json
        | None -> Error "checkpoint requires target" in
      let safe minimum = function
        | Some (`Int n) when n >= minimum && Int64.of_int n <= 9_007_199_254_740_991L -> Ok n
        | _ -> Error "checkpoint requires a valid sequence and revision" in
      let* expected_sequence = safe 0 (List.assoc_opt "expected_sequence" fields) in
      let* revision = safe 1 (List.assoc_opt "revision" fields) in
      Ok (Checkpoint { target; expected_sequence; revision })
  | _ -> Error "expected a checkpoint object"

let parse json =
  let action = match json with `Assoc fields -> List.assoc_opt "action" fields | _ -> None in
  match action with
  | Some (`String "find") ->
    let* query = Discovery.query_of_json json in Ok (Find query)
  | Some (`String "published") ->
    let* id = Discovery.published_id_of_json json in Ok (Published id)
  | Some (`String "checkpoint") -> checkpoint_of_json json
  | Some (`String ("read" | "leave" as action)) ->
    (match json with
     | `Assoc fields when List.length fields = 2 && List.mem_assoc "action" fields && List.mem_assoc "target" fields ->
       let* target = Draft.target_of_json (List.assoc "target" fields) in
       Ok (if action = "read" then Read target else Leave target)
     | _ -> Error "read/leave requires only action and target")
  | _ ->
    let* command = Draft.command_of_json json in match command with
    | Draft.Merge _ -> Error "Keeper edits use selected text, not CRDT wire updates"
    | Open _ | Select _ | Resolve _ | Edit _ | Discuss _ -> Ok (Draft_command command)
let fail class_ message = Keeper_tool_execution.failure ~class_ ~effect_disposition:Tool_result.Proven_pre_effect message
let refused = function
  | Store.Invalid message -> fail Tool_result.Policy_rejection message
  | Missing | Generation_conflict _ | Discussion_conflict _ as error -> fail Tool_result.Workflow_rejection (Store.error_message error)
  | Transform_error { kind = (Invalid_request | Invalid_document | Invalid_selection); message } -> fail Tool_result.Policy_rejection message
  | Transform_error { kind = Changed_selection; message } -> fail Tool_result.Workflow_rejection message
  | Commit_uncertain draft -> Keeper_tool_execution.failure_data ~class_:Tool_result.Runtime_failure
      ~effect_disposition:Tool_result.Effect_outcome_unknown
      ~message:"The draft write may have committed. Read the current draft before retrying."
      (`Assoc ["target", Draft.target_to_json draft.target; "attempted_sequence", `Int draft.sequence])
  | Artifact_error (Published_artifact_store.Commit_uncertain { id; revision; message }) ->
      Keeper_tool_execution.failure_data ~class_:Tool_result.Runtime_failure
        ~effect_disposition:Tool_result.Effect_outcome_unknown ~message
        (`Assoc ["artifact_id", `String id; "revision", `Int revision])
  | Artifact_error (Published_artifact_store.Invalid message) -> fail Tool_result.Policy_rejection message
  | Artifact_error (Published_artifact_store.Missing | Conflict _) as error -> fail Tool_result.Workflow_rejection (Store.error_message error)
  | Artifact_error (Published_artifact_store.Unavailable _) | Transform_error { kind = Unavailable; _ } | Unavailable _ as error ->
      fail Tool_result.Runtime_failure (Store.error_message error)
let data (view : Store.view) ~present =
  `Assoc ["target", Draft.target_to_json view.draft.target;
    "base_revision", `Int view.draft.base_revision; "base_sha256", `String view.draft.base_sha256;
    "sequence", `Int view.draft.sequence; "updated_by", `String view.draft.updated_by;
    "updated_at", `String view.draft.updated_at; "content", `String view.content;
    "presence_active", `Bool present;
    "next_request_id", `String (Random_id.uuid_v7 ());
    "discussion_receipts", Artifact_discussion.events_to_json view.draft.discussion;
    "threads", `List (List.map Artifact_discussion.thread_to_json (Artifact_discussion.threads view.draft.discussion |> Result.get_ok));
    "selection", (match view.selection with None -> `Null | Some (selection, _, _) -> Draft.selection_to_json selection);
    "range", (match view.selection with None -> `Null | Some (_, anchor, head) -> `Assoc ["anchor", `Int anchor; "head", `Int head])]
let result ~base_path start_time data =
  let result = Tool_result.make_ok ~tool_name:"keeper_artifact_draft" ~start_time ~data () in
  match Tool_bridge.attach_artifact_manifest ~projection:Tool_output.Inline_with_reference ~base_path result with
  | Ok result -> Keeper_tool_execution.of_tool_result result
  | Error _ -> Keeper_tool_execution.failure_data ~class_:Tool_result.Runtime_failure
      ~effect_disposition:Tool_result.Proven_post_effect
      ~message:"The draft operation completed, but its result manifest could not be stored. Read the current draft before retrying."
      data
let handle ?runner ~scope ~base_path ~keeper ~turn_ref ~args () =
  let start_time = Tool_timing.start () in
  match parse args with
  | Error message -> fail Tool_result.Policy_rejection message
  | Ok command ->
    match Scope.admit scope ~base_path ~keeper ~turn_ref with
    | Error _ -> fail Tool_result.Runtime_failure "The owning Keeper turn has ended or does not match this call."
    | Ok () ->
      let read target =
        let* view = Store.read ?runner ~base_path ~artifact_id:target.Draft.artifact_id () in
        if view.draft.target = target then Ok view else Error (Store.Generation_conflict view.draft.target) in
      match command with
      | Find query -> Discovery.find ~base_path query
      | Published id -> Discovery.published ~base_path ~id
      | Checkpoint { target; expected_sequence; revision } ->
        (match Store.checkpoint ?runner ~base_path ~actor:keeper ~target ~expected_sequence ~revision () with
         | Error (Store.Draft_error error) -> refused error
         | Error (Store.Sequence_conflict _ | Store.Draft_snapshot_changed | Store.Published_content_mismatch
                 | Store.Published_base_mismatch | Store.Published_format_mismatch as error) ->
           fail Tool_result.Workflow_rejection (Store.checkpoint_error_message error)
         | Ok outcome ->
           let view, status = match outcome with
             | Store.Checkpointed view -> view, "checkpointed"
             | Store.Already_current view -> view, "already_current" in
           Eio.Cancel.protect (fun () ->
             let present = Result.is_ok (Scope.present scope ~turn_ref view) in
             let payload = match data view ~present with
               | `Assoc fields -> `Assoc (("checkpoint", `String status) :: fields)
               | other -> other in
             result ~base_path start_time payload))
      | Leave target ->
        Scope.leave scope ~target;
        Keeper_tool_execution.success_data (`Assoc ["target", Draft.target_to_json target; "presence_active", `Bool false])
      | Read target ->
        (match read target with Error error -> refused error | Ok view ->
          Eio.Cancel.protect (fun () ->
            let present = Result.is_ok (Scope.present scope ~turn_ref view) in
            result ~base_path start_time (data view ~present)))
      | Draft_command command ->
        match Store.execute ?runner ~base_path ~actor:keeper command with
        | Error error -> refused error
        | Ok view ->
          (* A suspended operation can commit while its owner ends. Preserve
             its committed result without recreating ended-turn presence. *)
          Eio.Cancel.protect (fun () ->
            let present = Result.is_ok (Scope.present scope ~turn_ref view) in
            result ~base_path start_time (data view ~present))
