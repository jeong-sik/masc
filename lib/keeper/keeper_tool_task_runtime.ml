open Keeper_meta_contract
open Keeper_tool_shared_runtime

let workflow_rejection_error_json
      ?(rule_id = "keeper_task_argument_rejected")
      ?(typed_outcome : Keeper_tool_outcome.t option)
      message
  =
  (* RFC-0239 / audit D1: [typed_outcome] carries a top-level
     [typed_outcome] field (extracted by the PostToolUse hook into
     [tool_call_detail.typed_outcome]) so a rejected completion is seen
     as no-progress by the loop detector rather than counted as
     evidence by tool name alone. *)
  let extra_fields =
    match typed_outcome with
    | Some outcome -> [ "typed_outcome", Keeper_tool_outcome.to_json outcome ]
    | None -> []
  in
  Masc_task_handlers.Workflow_rejection_payload.payload
    ~rule_id
    ~extra_fields
    message
  |> Yojson.Safe.to_string
;;

let keeper_tool_result_json
      ?(typed_outcome = (None : Keeper_tool_outcome.t option))
      (result : Tool_result.result)
  =
  let has_json_field name fields =
    List.exists (fun (field, _) -> String.equal field name) fields
  in
  let message = Tool_result.message result in
  let disposition_field =
    "disposition", `String (Tool_result.string_of_disposition result)
  in
  let failure_class_fields =
    match result with
    | Tool_result.Failed { class_ = cls; _ } ->
      [
        ( "failure_class"
        , `String (Tool_result.tool_failure_class_to_string cls) );
      ]
    | Tool_result.Completed _ | Tool_result.Deferred _ -> []
  in
  let typed_outcome_fields =
    match typed_outcome with
    | Some outcome -> [ "typed_outcome", Keeper_tool_outcome.to_json outcome ]
    | None -> []
  in
  match Tool_result.data result with
  | `Assoc payload_fields ->
    let payload_fields =
      List.fold_left
        (fun acc (key, value) ->
           if has_json_field key acc then acc else acc @ [ key, value ])
        payload_fields
        (disposition_field :: failure_class_fields @ typed_outcome_fields)
    in
    Yojson.Safe.to_string (`Assoc payload_fields)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) ->
    Yojson.Safe.to_string
      (`Assoc
         ([ disposition_field
          ; (match result with
             | Tool_result.Completed _ | Tool_result.Deferred _ ->
               "result", `String message
             | Tool_result.Failed _ -> "error", `String message)
          ]
          @ failure_class_fields
          @ typed_outcome_fields))
;;

(* Caller-input validation errors carry [Tool_result.Policy_rejection], matching
   the schema-layer [Tool_input_validation] producer. The typed failure class is
   observational metadata; dispatch returns the producer payload unchanged. *)
let validation_error_json message =
  Yojson.Safe.to_string
    (`Assoc
       [ "ok", `Bool false
       ; "error", `String message
       ; ( "failure_class"
         , `String
             (Tool_result.tool_failure_class_to_string
                Tool_result.Policy_rejection) )
       ])
;;

(* [Workspace_task.add_task_error] mixes two different failure shapes:
   caller-input workflow violations and file-IO/exception failures. They
   route to different [Tool_result.tool_failure_class] values -- folding
   both into [Workflow_rejection] would make
   [Tool_result.log_level_of_failure_class] demote a durability incident to
   WARN (only [Runtime_failure] logs ERROR) and would misroute the
   terminal-effect buckets in [Keeper_runtime_failure_route]. Matched
   exhaustively (no catch-all) so a future [add_task_error] variant forces a
   classification decision here rather than defaulting into one bucket.

   [keeper_task_create] never threads [predecessor_task_id] (RFC-0323 W2
   scopes that arg to [masc_add_task]), so [Unknown_predecessor] /
   [Predecessor_not_terminal] cannot be produced through this tool's live
   args today. Exposed (like [validation_error_json] above) so the route
   split can be tested directly against all variants without depending
   on that unreachable path. *)
type task_create_failure_route =
  | Task_create_workflow_rejection
  | Task_create_runtime_failure

let task_create_failure_route : Workspace_task.add_task_error -> task_create_failure_route
  = function
  | Workspace_task.Unknown_goal _
  | Workspace_task.Ambiguous_goal _
  | Workspace_task.Goal_closed _
  | Workspace_task.Unknown_predecessor _
  | Workspace_task.Predecessor_not_terminal _ -> Task_create_workflow_rejection
  | Workspace_task.Goal_source_unavailable _
  | Workspace_task.Goal_lock_failed _
  | Workspace_task.Backlog_read_failed _
  | Workspace_task.Goal_link_write_failed _
  | Workspace_task.Backlog_write_failed _
  | Workspace_task.Unexpected_error _ -> Task_create_runtime_failure
;;


let find_task_goal_id config task_id =
  let index = Workspace_goal_index.build_task_goal_map_for_config config in
  (* Match the list directly instead of [List.hd]: the builder appends every
     goal id, and returning the first preserves persisted link order. *)
  match Workspace_goal_index.Task_id_map.find_opt task_id index with
  | Some (goal_id :: _) -> Some goal_id
  | Some [] | None -> None
;;

let sync_keeper_meta_current_task
    ~(config : Workspace.config)
    ~(meta : keeper_meta)
    ~(task_id : string)
  =
  (* Reconcile against authoritative backlog ownership with revision verification
     at the owner boundary so a concurrent release or cancellation cannot be
     overwritten by a delayed claim projection, and never assert the old claim
     when the authoritative backlog read fails. *)
  match Keeper_id.Task_id.of_string task_id with
  | Error msg ->
    Log.Keeper.warn ~keeper_name:meta.name
      "could not sync claimed task %s into current_task_id: %s"
      task_id msg
  | Ok preferred_task_id ->
    (match Workspace.read_prepared_backlog_r config with
     | Error msg ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string ReconcileFailures)
         ~labels:[ "keeper", meta.name; "phase", "claim_task_id_read" ]
         ();
       Log.Keeper.warn
         ~keeper_name:meta.name
         "skipping current_task_id sync for claimed task %s because backlog read failed: %s"
         task_id
         msg
     | Ok prepared ->
       let authoritative_task_id =
         match
           Workspace_backlog.Task_id_map.find_opt
             task_id
             prepared.active_assignees_by_task_id
         with
         | Some assignee
           when Workspace.same_task_actor config assignee meta.name ->
           Ok (Some preferred_task_id)
         | Some _ | None ->
           (match
              List.nth_opt
                (Workspace.active_owned_task_ids_for_agent
                   config
                   ~agent_name:meta.name
                   prepared.backlog)
                0
            with
            | None -> Ok None
            | Some active_id ->
              Result.map Option.some (Keeper_id.Task_id.of_string active_id))
       in
       match authoritative_task_id with
       | Error msg ->
         Log.Keeper.warn ~keeper_name:meta.name
           "could not sync claimed task %s into current_task_id: %s"
           task_id msg
       | Ok desired ->
         (match
            Keeper_current_task_reconcile.apply_current_task_if_revision
              ~config
              ~meta
              ~preferred_task_id
              ~backlog_revision:prepared.backlog.version
              ~desired
              ()
          with
          | Error msg ->
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string ReconcileFailures)
              ~labels:[ "keeper", meta.name; "phase", "claim_task_id_recheck" ]
              ();
            Log.Keeper.warn
              ~keeper_name:meta.name
              "skipping current_task_id sync for claimed task %s because backlog recheck failed: %s"
              task_id
              msg
          | Ok (_effective_desired, Ok (Some _)) -> ()
          | Ok (_effective_desired, Ok None) ->
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string WriteMetaFailures)
              ~labels:[ "keeper", meta.name; "phase", "claim_task_id" ]
              ();
            Log.Keeper.warn
              ~keeper_name:meta.name
              "owner removed metadata while syncing claimed current_task_id=%s"
              task_id
          | Ok (_effective_desired, Error error) ->
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string WriteMetaFailures)
              ~labels:[ "keeper", meta.name; "phase", "claim_task_id" ]
              ();
            Log.Keeper.warn
              ~keeper_name:meta.name
              "failed to persist claimed current_task_id=%s: %s"
              task_id
              (Keeper_owner_registry.command_error_to_string error)))
;;

(* Row shape of a [Tasks_list] page. [Compact] is the default: identity,
   ordering and claim state only ([Masc_domain.task_compact_to_yojson]).
   [Full] is the whole record, for the task(s) a keeper is about to work on.
   The argument is decoded once here; an unknown value is a validation error,
   not a silent fallback to either shape. *)
type task_projection =
  | Compact
  | Full

let task_projection_of_args args : (task_projection, string) result =
  match Safe_ops.json_string_opt "projection" args with
  | None | Some "compact" -> Ok Compact
  | Some "full" -> Ok Full
  | Some other ->
    Error
      (Printf.sprintf
         "projection must be \"compact\" or \"full\", got %S"
         other)
;;

let task_projection_to_string = function
  | Compact -> "compact"
  | Full -> "full"
;;

(* Entry validity is a parse fact and is rejected here. A missing or empty
   evidence_refs list proceeds to the Task transition, which decides
   completion. *)
let parse_keeper_task_done_evidence_refs args =
  match args with
  | `Assoc fields ->
    (match List.assoc_opt "evidence_refs" fields with
     | None -> Ok []
     | Some (`List refs) ->
       let rec collect acc = function
         | [] -> Ok (List.rev acc)
         | `String ref_ :: rest ->
           if Task.Completion_review.blank_evidence_ref ref_
           then Error "evidence_refs must contain only non-empty strings."
           else if Task.Completion_review.unresolvable_evidence_ref ref_
           then
             (* The masc_transition boundary refuses the same entries; this
                parser states it in keeper vocabulary. Without it the store
                snapshots a payload-free invalid reference and the reviewer
                rejects for missing evidence, which reads as a verdict on the
                work rather than on the reference form. *)
             Error
               (Printf.sprintf
                  "evidence_refs entries must be %s. Nothing else can be read \
                   back at review. Wrap a commit, a URL, or \
                   any narrative as %s."
                  Task.Completion_review.resolvable_evidence_ref_forms
                  Task.Completion_review.note_evidence_ref_form)
           else collect (String.trim ref_ :: acc) rest
         | _ :: _ -> Error "evidence_refs must be an array of non-empty strings."
       in
       collect [] refs
     | Some _ -> Error "evidence_refs must be an array of non-empty strings.")
  | _ -> Error "keeper_task_done arguments must be an object."
;;

(* Where an evidence artifact lives depends on the producer's sandbox
   profile, and that policy sits above the store's library. An
   endpoint-owned tree (microvm, remote-ssh) keeps its files inside the
   guest's work volume, which only the sandbox backend can read -- the
   store's direct host read reached the bookkeeping bundle instead and
   recorded every artifact as unreadable (live capture 2026-09-02 onward,
   #33745). A shared-mount (Docker) tree stays on the host playground the
   store already reads, so that keeper keeps the direct read. [None] means
   "no reader: read the host directly", which is also the store's default. *)
let evidence_artifact_reader ~config ~(meta : keeper_meta) () =
  match
    Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile
  with
  | Keeper_types_profile_sandbox.Endpoint_owned ->
      Some
        (fun ~worker ~relative ->
           let module Store = Workspace_verification_store in
           match Keeper_sandbox_read_backend.read_complete_file ~config ~meta
               ~host_path:relative ~timeout_sec:30. () with
           | Error reason -> Error (Store.Evidence_read_error
               (Printf.sprintf "sandbox_backend_read: %s: %s" worker reason))
           | Ok content -> Store.payload_of_complete_bytes ~path:relative content)

  | Keeper_types_profile_sandbox.Shared_mount -> None

let handle_keeper_task_tool_with_outcome
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  match Keeper_tooling.Name.of_string name with
  | None ->
    Keeper_tool_execution.failure
      ~class_:Tool_result.Policy_rejection
      (error_json ~fields:[ "tool", `String name ] "unknown_task_tool")
  | Some op ->
    match op with
    | Keeper_tooling.Name.Tasks_list ->
    let limit = Safe_ops.json_int ~default:50 "limit" args |> max 1 |> min 100 in
    let projection_and_revision =
      match task_projection_of_args args,
            Snapshot_protocol.if_revision args, Keeper_tasks_list_query.of_args args with
      | Error message, _, _ | _, Error message, _ | _, _, Error message -> Error message
      | Ok projection, Ok if_revision, Ok selection ->
        Keeper_tasks_list_query.lifecycle_filter_of_args ~selection args
        |> Result.map (fun lifecycle -> lifecycle, projection, if_revision, selection)
    in
    (match projection_and_revision with
     | Error message ->
       Keeper_tool_execution.failure
         ~class_:Tool_result.Policy_rejection
         (validation_error_json message)
     | Ok (lifecycle, projection, if_revision, selection) ->
       let call_filter =
         { Keeper_tasks_list_cursor.lifecycle
         ; projection = task_projection_to_string projection
         ; selection
         }
       in
       (* A cursor names the row the previous page ended on and the filter it
          was issued under. Anything else -- a string this runtime did not
          issue, a non-string, a cursor from another filter -- is refused as a
          rejected argument; it never falls back to the first page, which the
          caller would read as the whole backlog (#29101). *)
       let cursor =
         match Safe_ops.safe_member "cursor" args with
         | `Null -> Ok None
         | `String raw ->
           Result.map Option.some (Keeper_tasks_list_cursor.of_string ~call:call_filter raw)
         | _ -> Error Keeper_tasks_list_cursor.Cursor_unparseable
       in
       (match cursor with
        | Error error ->
          let data = Keeper_tasks_list_cursor.rejection_json error in
          Keeper_tool_execution.failure_data
            ~class_:Tool_result.Policy_rejection
            ~message:(Yojson.Safe.to_string data)
            data
        | Ok cursor ->
       let goal_task_ids =
         match selection.goal_id with
         | None -> Ok None
         | Some goal_id ->
           Workspace_goal_index.read_goal_task_links_authoritative_r config
           |> Result.map (fun links ->
             Some (Option.value ~default:[] (List.assoc_opt goal_id links)))
       in
       match goal_task_ids, Workspace.read_prepared_backlog_observation_with_source_r config with
     | Error message, _ | _, Error message ->
       let data =
         `Assoc
           [ "ok", `Bool false
           ; "error", `String message
           ; ( "failure_class"
             , `String
                 (Tool_result.tool_failure_class_to_string
                    Tool_result.Runtime_failure) )
           ]
       in
       Keeper_tool_execution.failure_data
         ~class_:Tool_result.Runtime_failure
         ~message:(Yojson.Safe.to_string data)
         data
     | Ok goal_task_ids, Ok { Workspace.observed_prepared = prepared; recovered_from } ->
       let page_key (task : Masc_domain.task) =
         { Keeper_tasks_list_cursor.priority = task.priority
         ; created_at = task.created_at
         ; id = task.id
         }
       in
       (* [prepared.priority_ordered_tasks] is already ordered by
          [(priority, created_at, id)] — identical to
          [Keeper_tasks_list_cursor.compare_key] — so filtering preserves the
          exact cursor order without re-sorting on every page read. *)
       let matching =
         prepared.priority_ordered_tasks
         |> List.filter (Keeper_tasks_list_query.matches_lifecycle lifecycle)
         |> List.filter (Keeper_tasks_list_query.matches selection ~goal_task_ids)
       in
       let matching_count = List.length matching in
       let row_to_yojson =
         match projection with
         | Compact -> Masc_domain.task_compact_to_yojson
         | Full -> Masc_domain.task_to_yojson
       in
       (* New tasks are the ones a caller most needs to see and the ones the
          claim-order page pushes furthest back: within a priority the page is
          oldest-first, so a task created minutes ago sorts behind every older
          sibling and falls past [limit]. The page order stays the claim order
          (#29101); this section names the newest visible rows beside it so a
          fresh task is never invisible on the first call. *)
       let new_task_window = 10 in
       let newest_first (left : Masc_domain.task) (right : Masc_domain.task) =
         match String.compare right.created_at left.created_at with
         | 0 -> String.compare right.id left.id
         | order -> order
       in
       let newest =
         match cursor with
         | Some _ -> []
         | None ->
           matching
           |> List.sort newest_first
           |> List.filteri (fun index _ -> index < new_task_window)
       in
       (* The order is total -- priority, then created_at, then id -- so a page
          is "the first [limit] rows after the cursor's key" and the same row
          never appears on two pages nor vanishes between them. Eight tasks
          once stayed invisible across nineteen todo listings because the
          caller read the first page as the whole backlog (#29101); the page
          now names the row it ended on, and the next call starts there. *)
       let after_cursor =
         match cursor with
         | None -> matching
         | Some (cursor : Keeper_tasks_list_cursor.t) ->
           List.filter
             (fun task -> Keeper_tasks_list_cursor.compare_key (page_key task) cursor.after > 0)
             matching
       in
       let tasks = after_cursor |> List.filteri (fun index _ -> index < limit) in
       let remaining = List.length after_cursor - List.length tasks in
       let next_cursor =
         match remaining > 0, List.rev tasks with
         | true, last :: _ ->
           Some
             (Keeper_tasks_list_cursor.to_string
                { Keeper_tasks_list_cursor.after = page_key last; filter = call_filter })
         | true, [] | false, _ -> None
       in
       let tasks_json = `List (List.map row_to_yojson tasks) in
       (* Discovery belongs to the first page. Repeating the newest window
          on every continuation made a 530-row walk carry 100 extra rows
          for the same ten tasks. Continuations retain the complete ordered
          page stream; a fresh first-page read discovers later arrivals.
          Within the first page, do not repeat a row in both sections. *)
       let new_tasks =
         let module Ids = Set.Make (String) in
         let on_page =
           Ids.of_list (List.map (fun (task : Masc_domain.task) -> task.id) tasks)
         in
         List.filter
           (fun (task : Masc_domain.task) -> not (Ids.mem task.id on_page))
           newest
       in
       let new_tasks_json = `List (List.map row_to_yojson new_tasks) in
       let revision =
         Snapshot_protocol.revision_of_json
           ~namespace:"tasks"
           (`Assoc
             [ ( "backlog_authority"
               , `String
                   (if Option.is_none recovered_from
                    then "primary"
                    else "recovery_non_authoritative") )
             ; "lifecycle", Keeper_tasks_list_query.lifecycle_filter_to_yojson lifecycle
             ; "limit", `Int limit
             ; "projection", `String (task_projection_to_string projection)
             ; "selection", Keeper_tasks_list_query.to_yojson selection
               (* The backlog size is part of the answer, not only the page:
                  matching_count travels in every snapshot and truncated is
                  derived from it. Without it in the hash, tasks appearing or
                  leaving beyond the page kept the revision stable and an
                  if_revision caller polled `unchanged` while the backlog
                  moved — the #29101 blindness rebuilt on the conditional-read
                  path. With it, `unchanged` states that the whole response —
                  rows and statistics — is the one the caller already holds. *)
             ; "matching_count", `Int matching_count
               (* A later page is a different answer from the first one even
                  when the backlog is the same, so the cursor it was read
                  through is part of the revision. *)
             ; ( "cursor_after"
               , match cursor with
                 | None -> `Null
                 | Some cursor -> Keeper_tasks_list_cursor.to_yojson cursor )
             ; "snapshot", tasks_json
               (* A fresh task changes this section even when the page rows do
                  not, so an if_revision caller is not told `unchanged` while a
                  new task sits outside its page. *)
             ; "new_tasks", new_tasks_json
             ])
       in
       let response =
         match recovered_from with
         | None -> Snapshot_protocol.respond ~revision ~if_revision tasks_json
         | Some _ -> Snapshot_protocol.Snapshot { revision; value = tasks_json }
       in
       let data =
         match Snapshot_protocol.to_yojson response with
         | `Assoc fields ->
           let provenance =
             [ ( "backlog_authority"
               , `String
                   (if Option.is_none recovered_from
                    then "primary"
                    else "recovery_non_authoritative") )
             ; "degraded", `Bool (Option.is_some recovered_from)
             ; "projection", `String (task_projection_to_string projection)
             ]
           in
           (* Row statistics describe the rows travelling in this response.
              An [unchanged] response carries no rows, so echoing the
              snapshot-path statistics produced a self-contradiction —
              `truncated:true, returned_count:N` beside zero rows — that
              models resolved by re-issuing the identical call (211 identical
              back-to-back pairs on 2026-09-01 alone). Because the revision
              hash covers [matching_count] alongside the page rows, an
              [unchanged] response guarantees the caller's cached statistics
              are still exact — omitting them here loses nothing. *)
           let row_stats =
             match response with
             | Snapshot_protocol.Snapshot _ ->
               [ "matching_count", `Int matching_count
               ; "returned_count", `Int (List.length tasks)
               ; "truncated", `Bool (remaining > 0)
               ; "new_tasks_count", `Int (List.length new_tasks)
               ; "new_tasks", new_tasks_json
               ]
               @ (match next_cursor with
                  | Some next_cursor -> [ "next_cursor", `String next_cursor ]
                  | None -> [])
             | Snapshot_protocol.Unchanged _ -> []
           in
           `Assoc (provenance @ row_stats @ fields)
         | payload -> payload
       in
       Keeper_tool_execution.success_data data))
    | Keeper_tooling.Name.Tasks_audit ->
    let limit = Safe_ops.json_int ~default:20 "limit" args |> max 1 |> min 50 in
    let orphans =
      Workspace.audit_orphan_tasks config
      |> List.filter (fun (_, assignee) -> assignee <> meta.name)
    in
    let orphans = List.filteri (fun i _ -> i < limit) orphans in
    let items =
      List.map
        (fun (task, assignee) ->
           let task : Masc_domain.task = task in
           `Assoc
             [ "task_id", `String task.id
             ; "title", `String task.title
             ; "assignee", `String assignee
             ; "status", `String (Masc_domain.string_of_task_status task.task_status)
             ])
        orphans
    in
    Keeper_tool_execution.success
      (Yojson.Safe.to_string
         (`Assoc
            [ "orphan_count", `Int (List.length orphans)
            ; "orphans", `List items
            ; ( "typed_outcome"
              , Keeper_tool_outcome.to_json
                  (if orphans = []
                   then Keeper_tool_outcome.No_progress { reason = No_work_available }
                   else Keeper_tool_outcome.Progress) )
            ]))
    | Keeper_tooling.Name.Broadcast ->
    let message = Safe_ops.json_string ~default:"" "content" args |> String.trim in
    let task_cache_signal_result = Workspace_broadcast.task_cache_signal_of_args args in
    if message = ""
    then
      Keeper_tool_execution.failure
        ~class_:Tool_result.Policy_rejection
        (error_json (Tool_guidance.to_string Tool_guidance.Broadcast_content_required))
    else (
      match task_cache_signal_result with
      | Error detail ->
        Keeper_tool_execution.failure
          ~class_:Tool_result.Policy_rejection
          (error_json detail)
      | Ok task_cache_signal ->
      match
        (* A Keeper calling keeper_broadcast is speaking to the workspace,
           so this reaches every Keeper's conversation window. *)
        Workspace.broadcast
          ?task_cache_signal
          ~audience:Workspace_broadcast.Fleet_conversation
          config
          ~from_agent:(keeper_agent_sender ~meta)
          ~content:message
      with
      | Error (Workspace_broadcast.Broadcast_policy_rejected detail) ->
        Keeper_tool_execution.failure
          ~class_:Tool_result.Policy_rejection
          (error_json ("broadcast rejected: " ^ detail))
      | Error
          (( Workspace_broadcast.Broadcast_not_persisted _
           | Workspace_broadcast.Broadcast_dependency_unavailable _ ) as error) ->
        Keeper_tool_execution.failure
          ~class_:Tool_result.Runtime_failure
          (error_json
             ("broadcast was not persisted: "
              ^ Workspace.broadcast_error_to_string error))
      | Ok delivery ->
        let data = Workspace_broadcast.broadcast_delivery_to_yojson delivery in
        (match delivery.mention_delivery with
         | Workspace_broadcast.Passive
         | Workspace_broadcast.Accepted
         | Workspace_broadcast.Already_accepted ->
           Keeper_tool_execution.success_data data
         | Workspace_broadcast.Pending
         | Workspace_broadcast.Deferred _ ->
           Keeper_tool_execution.deferred_data
             ~effect_disposition:Tool_result.Proven_post_effect data
         | Workspace_broadcast.Rejected _ ->
           Keeper_tool_execution.failure_data
             ~class_:Tool_result.Workflow_rejection
             ~effect_disposition:Tool_result.Proven_post_effect
             ~message:
               (Tool_guidance.to_string
                  (Tool_guidance.Broadcast_delivery_rejected
                     { request_id = delivery.request_id }))
             data))
    | Keeper_tooling.Name.Task_create ->
    let title = Safe_ops.json_string ~default:"" "title" args |> String.trim in
    let description = Safe_ops.json_string ~default:"" "description" args |> String.trim in
    let priority = Safe_ops.json_int ~default:3 "priority" args |> max 1 |> min 5 in
    if title = ""
    then
      Keeper_tool_execution.failure
        ~class_:Tool_result.Policy_rejection
        (validation_error_json "title is required. Provide a clear, actionable task title.")
    else if description = ""
    then
      Keeper_tool_execution.failure
        ~class_:Tool_result.Policy_rejection
        (validation_error_json
           "description is required. Explain what needs to be done and why.")
    else (
      let goal_id =
        Safe_ops.json_string_opt "goal_id" args
        |> Workspace_task_classify.trim_opt
      in
          (* De-duplicated: this keeper-internal path now shares the canonical
             [Task.Args.parse_task_contract] used by the public
             masc_task_create facade. The previous local copy
             [parse_task_contract_arg] had regressed — it rejected an OMITTED
             optional [contract] via a catch-all that conflated None(omitted)
             with a wrong-typed value, which falsely failed keeper_task_create.
             Same lib, no
             dependency wall; the canonical parser handles [None | Some `Null]. *)
          (match Task.Args.parse_task_contract args with
           | Error message ->
             Keeper_tool_execution.failure
               ~class_:Tool_result.Policy_rejection
               (validation_error_json message)
           | Ok contract ->
             (match
                Masc_task_handlers.Task_goal_assignment.add_task_with_result
                  ?contract
                  ?goal_id
                  config
                  ~title
                  ~priority
                  ~description
                    (* The author is a fact on the Task row; the cancellation
                       notice to the creating Keeper reads it. *)
                  ~created_by:meta.name
              with
              | Ok created ->
                Keeper_tool_execution.success
                  (Yojson.Safe.to_string
                     (`Assoc
                        [
                          "ok", `Bool true;
                          "result", `String created.summary;
                          "goal_id", Json_util.string_opt_to_json created.goal_id;
                          ( "typed_outcome"
                          , Keeper_tool_outcome.to_json Keeper_tool_outcome.Progress );
                        ]))
              | Error err ->
                (* RFC-0239 / audit D1 shape (Task_done, above): a task-creation
                   failure is not progress, regardless of failure class.
                   Previously [Workspace_task.add_task] folded [Error err] into
                   a string and this branch always returned [ok:true,
                   typed_outcome:Progress] regardless -- the keeper could not
                   distinguish a durable write from a failed one. Class split
                   is [task_create_failure_route] above. *)
                let message = Workspace_task.add_task_error_to_string err in
                let typed_outcome = Keeper_tool_outcome.Error { reason = message } in
                (match task_create_failure_route err with
                 | Task_create_workflow_rejection ->
                   (* Same payload shape as the rejected-transition branches
                      in [Task_done] below. *)
                   Keeper_tool_execution.failure
                     ~class_:Tool_result.Workflow_rejection
                     (workflow_rejection_error_json ~typed_outcome message)
                 | Task_create_runtime_failure ->
                   (* Same failure class as the broadcast-persistence-failure
                      branch above (this file, [Broadcast] case). *)
                   Keeper_tool_execution.failure
                     ~class_:Tool_result.Runtime_failure
                     (error_json
                        ~fields:
                          [ "ok", `Bool false
                          ; ( "failure_class"
                            , `String
                                (Tool_result.tool_failure_class_to_string
                                   Tool_result.Runtime_failure) )
                          ; "typed_outcome", Keeper_tool_outcome.to_json typed_outcome
                          ]
                        message)))))
    | Keeper_tooling.Name.Task_claim ->
    let requested_task_id =
      Safe_ops.json_string ~default:"" "task_id" args |> String.trim
    in
    let explicit_claim_result () =
      match
        Workspace.claim_task_with_details_r
          config
          ~agent_name:meta.name
          ~task_id:requested_task_id
          ~auto_start:true
          ()
      with
      | Ok (task, message) ->
        Workspace.Claim_next_claimed
          { task_id = requested_task_id
          ; title = task.title
          ; priority = task.priority
          ; message
          }
      | Error e when Masc_domain.is_task_not_found e ->
        Workspace.Claim_next_error
          (Printf.sprintf "unknown task_id: %s" requested_task_id)
      | Error e -> Workspace.Claim_next_error (Masc_domain.masc_error_to_string e)
    in
    let claim_requested_task () =
      if requested_task_id <> "" then
        explicit_claim_result ()
      else
        Workspace.claim_next_r config ~agent_name:meta.name
          ~auto_start:true
          ()
    in
    let result = claim_requested_task () in
    (match result with
     | Workspace.Claim_next_claimed { task_id; _ } ->
       sync_keeper_meta_current_task ~config ~meta ~task_id
     | Workspace.Claim_next_no_unclaimed
     | Workspace.Claim_next_error _ -> ());
    let message =
      match result with
      | Workspace.Claim_next_claimed { message; _ } -> message
      | Workspace.Claim_next_no_unclaimed -> "No unclaimed tasks."
      | Workspace.Claim_next_error e -> Printf.sprintf "Error: %s" e
    in
    let claimed_task_fields =
      match result with
      | Workspace.Claim_next_claimed
          { task_id; title; priority; _ } ->
          let matched_goal_id = find_task_goal_id config task_id in
          [
            ( "claim_observation",
              Task.Tool.build_claim_observation_payload
                ~now:(Time_compat.now ()) ~agent_name:meta.name
                ~task_id );
            ( "claimed_task",
              `Assoc
                [
                  ("task_id", `String task_id);
                  ("title", `String title);
                  ("priority", `Int priority);
                  ("goal_id", Json_util.string_opt_to_json matched_goal_id);
                ] );
          ]
      | Workspace.Claim_next_no_unclaimed
      | Workspace.Claim_next_error _ -> []
    in
    let typed_outcome_field =
      match result with
      | Workspace.Claim_next_no_unclaimed ->
        Some
          ( "typed_outcome"
          , Keeper_tool_outcome.to_json
              (Keeper_tool_outcome.No_progress
                 { reason = Keeper_tool_outcome.No_work_available }) )
      | Workspace.Claim_next_error e ->
        Some
          ( "typed_outcome"
          , Keeper_tool_outcome.to_json
              (Keeper_tool_outcome.Error
                 { reason = Printf.sprintf "keeper_task_claim rejected: %s" e }) )
      (* A claimed task carries no typed_outcome field, and adding the field
         here would change the tool payload. *)
      | Workspace.Claim_next_claimed _ -> None
    in
    let payload =
      Yojson.Safe.to_string
        (`Assoc
           ([
              ("result", `String message);
            ]
             @ (match typed_outcome_field with
                | Some field -> [ field ]
                | None -> [])
           @ claimed_task_fields))
    in
    (match result with
     | Workspace.Claim_next_error _ ->
       Keeper_tool_execution.failure ~class_:Tool_result.Workflow_rejection payload
     | Workspace.Claim_next_claimed _
     | Workspace.Claim_next_no_unclaimed -> Keeper_tool_execution.success payload)
    | Keeper_tooling.Name.Task_release ->
    let task_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
    let summary = Safe_ops.json_string ~default:"" "summary" args |> String.trim in
    let optional_field name =
      match Safe_ops.json_string ~default:"" name args |> String.trim with
      | "" -> []
      | value -> [ name, `String value ]
    in
    if task_id = ""
    then
      Keeper_tool_execution.failure
        ~class_:Tool_result.Workflow_rejection
        (workflow_rejection_error_json
           ~typed_outcome:
             (Keeper_tool_outcome.Error
                { reason = "keeper_task_release rejected: task_id required" })
           "task_id is required.")
    else (
      let evidence_refs_field =
        match Json_util.assoc_member_opt "evidence_refs" args with
        | None -> []
        | Some refs -> [ "evidence_refs", refs ]
      in
      let args_for_transition =
        [ "task_id", `String task_id
        ; "action", `String "release"
        ; ( "handoff_context"
          , `Assoc
              (("summary", `String summary)
               :: (optional_field "reason" @ optional_field "next_step"
                   @ evidence_refs_field)) )
        ]
      in
      let transition_result =
        Task.Tool.handle_transition
          ~tool_name:"keeper_task_release"
          ~start_time:(Tool_timing.start ())
          { Task.Tool.config
          ; agent_name = keeper_agent_sender ~meta
          ; sw = Eio_context.get_switch_opt ()
          }
          (`Assoc args_for_transition)
      in
      let payload =
        keeper_tool_result_json
          ~typed_outcome:
            (match transition_result with
             | Tool_result.Completed _ -> Some Keeper_tool_outcome.Progress
             | Tool_result.Deferred _ -> None
             | Tool_result.Failed _ ->
               (* A refused release (not the owner, stale version) left the
                  keeper holding the task, so it is not progress. *)
               Some
                 (Keeper_tool_outcome.Error
                    { reason = Tool_result.message transition_result }))
          transition_result
      in
      match transition_result with
      | Tool_result.Completed _ -> Keeper_tool_execution.success payload
      | Tool_result.Deferred { metadata; _ } ->
        Keeper_tool_execution.deferred_data ?metadata (Tool_result.data transition_result)
      | Tool_result.Failed { class_; _ } ->
        Keeper_tool_execution.failure ~class_ payload)
    | Keeper_tooling.Name.Task_cancel ->
    let task_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
    let reason = Safe_ops.json_string ~default:"" "reason" args |> String.trim in
    if task_id = ""
    then
      Keeper_tool_execution.failure
        ~class_:Tool_result.Workflow_rejection
        (workflow_rejection_error_json
           ~typed_outcome:
             (Keeper_tool_outcome.Error
                { reason = "keeper_task_cancel rejected: task_id required" })
           "task_id is required.")
    else (
      let args_for_transition =
        [ "task_id", `String task_id
        ; "action", `String "cancel"
        ; "reason", `String reason
        ]
      in
      let transition_result =
        Task.Tool.handle_transition
          ~tool_name:"keeper_task_cancel"
          ~start_time:(Tool_timing.start ())
          { Task.Tool.config
          ; agent_name = keeper_agent_sender ~meta
          ; sw = Eio_context.get_switch_opt ()
          }
          (`Assoc args_for_transition)
      in
      let payload =
        keeper_tool_result_json
          ~typed_outcome:
            (match transition_result with
             | Tool_result.Completed _ -> Some Keeper_tool_outcome.Progress
             | Tool_result.Deferred _ -> None
             | Tool_result.Failed _ ->
               Some
                 (Keeper_tool_outcome.Error
                    { reason = Tool_result.message transition_result }))
          transition_result
      in
      match transition_result with
      | Tool_result.Completed _ -> Keeper_tool_execution.success payload
      | Tool_result.Deferred { metadata; _ } ->
        Keeper_tool_execution.deferred_data ?metadata (Tool_result.data transition_result)
      | Tool_result.Failed { class_; _ } ->
        Keeper_tool_execution.failure ~class_ payload)
    | Keeper_tooling.Name.Task_done ->
    let task_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
    let result_text = Safe_ops.json_string ~default:"" "result" args |> String.trim in
    (* Preserve the optional handoff note independently of the result summary.
       A present note, including an empty string, is never replaced. *)
    let notes =
      match Json_field.string args "notes" with
      | Json_field.Found text -> Ok [ "notes", `String text ]
      | Json_field.Field_absent -> Ok []
      | Json_field.Wrong_shape { expected; got } ->
        Error (Printf.sprintf "notes must be %s, got %s" expected got)
    in
    (match notes with
    | Error message ->
      Keeper_tool_execution.failure
        ~class_:Tool_result.Workflow_rejection
        (workflow_rejection_error_json
           ~typed_outcome:(Keeper_tool_outcome.Error { reason = message })
           message)
    | Ok notes ->
    if task_id = ""
    then
      Keeper_tool_execution.failure
        ~class_:Tool_result.Workflow_rejection
        (workflow_rejection_error_json
           ~typed_outcome:
             (Keeper_tool_outcome.Error
                { reason = "keeper_task_done rejected: task_id required" })
           "task_id is required.")
    else if result_text = ""
    then
      (* Schema (config/tools/keeper_task_done.toml) declares [result] as a
         required, minLength:1 field. Other agents verify completion
         from this field, so an empty result hides the audit trail.
         Previously the handler accepted an empty result and either
         (a) silently passed non-strict tasks done with no summary or
         (b) deferred the rejection to parse_handoff_context for
         strict-contract tasks (where keepers received the confusing
         "handoff_context.summary is required" message instead of a
         keeper-vocabulary error). Enforce the schema here so the
         error names the field the keeper actually sent. *)
      Keeper_tool_execution.failure
        ~class_:Tool_result.Workflow_rejection
        (workflow_rejection_error_json
           ~typed_outcome:
             (Keeper_tool_outcome.Error
                { reason = "keeper_task_done rejected: result required" })
           "result is required. Audit trail: describe what you completed. \
            Example: result='Refactored module X, all tests green, no flake'.")
    else (
      match parse_keeper_task_done_evidence_refs args with
      | Error message ->
        Keeper_tool_execution.failure
          ~class_:Tool_result.Workflow_rejection
          (workflow_rejection_error_json
             ~typed_outcome:
               (Keeper_tool_outcome.Error
                  { reason = "keeper_task_done rejected: evidence_refs required" })
             message)
      | Ok evidence_refs ->(
      (* A Keeper submits evidence; only the completion authority can issue the
         terminal verdict. *)
      let action = "submit_for_verification" in
      let args_for_transition =
        [
          "task_id", `String task_id;
          "action", `String action;
          ( "handoff_context",
            `Assoc
              [ "summary", `String result_text
              ; "evidence_refs", Json_util.json_string_list evidence_refs
              ] );
        ] @ notes
      in
      let transition_result =
        Task.Tool.handle_transition
          ~tool_name:"keeper_task_done"
          ~start_time:(Tool_timing.start ())
          {
            Task.Tool.config;
            agent_name = keeper_agent_sender ~meta;
            sw = Eio_context.get_switch_opt ();
          }
          (`Assoc args_for_transition)
      in
      let payload =
        keeper_tool_result_json
          ~typed_outcome:
            (match transition_result with
             | Tool_result.Completed _ -> Some Keeper_tool_outcome.Progress
             | Tool_result.Deferred _ -> None
             | Tool_result.Failed _ ->
               (* RFC-0239 / audit D1: a rejected completion (wrong owner, stale
                  or invalid transition) is not progress. Emit a typed Error so the
                  no-progress detector demotes it instead of counting the tool name
                  as evidence. *)
               Some
                 (Keeper_tool_outcome.Error
                    { reason = Tool_result.message transition_result }))
          transition_result
      in
      match transition_result with
      | Tool_result.Completed _ -> Keeper_tool_execution.success payload
      | Tool_result.Deferred { metadata; _ } ->
        Keeper_tool_execution.deferred_data ?metadata (Tool_result.data transition_result)
      | Tool_result.Failed { class_; _ } ->
        Keeper_tool_execution.failure ~class_ payload)))
;;

let handle_keeper_task_tool ~config ~meta ~name ~args =
  (handle_keeper_task_tool_with_outcome ~config ~meta ~name ~args).raw_output
;;
