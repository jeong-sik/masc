(** Dashboard proof actors — actor contribution analysis for evidence-first
    collaboration proof projection. *)

include Dashboard_proof_helpers

let known_session_actor_names = function
  | Some session -> Team_session_types.planned_participant_names session
  | None -> []

let actor_role_lookup (session : Team_session_types.session option) actor =
  match session with
  | None -> None
  | Some session when String.equal actor session.created_by -> Some "supervisor"
  | Some session -> (
      session.Team_session_types.planned_workers
      |> List.find_map (fun worker ->
             match worker.Team_session_types.runtime_actor with
             | Some runtime_actor when String.equal runtime_actor actor ->
                 worker.spawn_role
                 |> Option.map String.trim
                 |> option_non_empty_trimmed
             | _ -> None)
      |> option_or_else (fun () ->
             if List.exists (String.equal actor) session.agent_names then
               Some "participant"
             else None))

let get_or_create_actor table session actor =
  match Hashtbl.find_opt table actor with
  | Some acc -> acc
  | None ->
      let acc =
        {
          actor;
          role = actor_role_lookup session actor;
          observed_event_count = 0;
          turn_count = 0;
          spawn_count = 0;
          tool_evidence_count = 0;
          interaction_count = 0;
          mention_count = 0;
          recent_input_preview = None;
          recent_output_preview = None;
          recent_event_summary = None;
          recent_tool_names = [];
          last_active_at = None;
          requested_by = None;
          recent_request_preview = None;
          recent_request_at = None;
        }
      in
      Hashtbl.replace table actor acc;
      acc

let tool_name_union xs ys =
  Team_session_types.dedup_strings (xs @ ys)

let worker_run_meta_jsons config = function
  | None -> []
  | Some session_id ->
      Team_session_store.list_worker_run_ids config session_id
      |> List.sort String.compare
      |> List.rev
      |> List.filter_map (fun worker_run_id ->
             let path =
               Team_session_store.worker_run_meta_path config session_id
                 worker_run_id
             in
             if Room_utils.path_exists config path then
               Some (Room_utils.read_json config path)
             else None)

let worker_run_trace_capability json =
  match U.member "trace_capability" json with
  | `String value -> Some value
  | _ -> None

let worker_run_trace_validated json =
  match U.member "validated" json with
  | `Bool value -> Some value
  | _ -> (
      match U.member "trace_validation" json |> U.member "ok" with
      | `Bool value -> Some value
      | _ -> None)

let session_conformance_failures json =
  match U.member "session_conformance" json |> U.member "checks" with
  | `List items ->
      items
      |> List.filter_map (fun item ->
             match U.member "name" item, U.member "passed" item with
             | `String name, `Bool false -> Some name
             | _ -> None)
  | _ -> []

let worker_run_validation_failures json =
  let trace_failures =
    match U.member "trace_validation" json |> U.member "checks" with
    | `List items ->
        items
        |> List.filter_map (fun item ->
               match U.member "name" item, U.member "passed" item with
               | `String name, `Bool false -> Some name
               | _ -> None)
    | _ -> []
  in
  Team_session_types.dedup_strings
    (trace_failures @ session_conformance_failures json)

let worker_run_summary_json json =
  let summary = U.member "trace_summary" json in
  `Assoc
    [
      ("worker_run_id", U.member "worker_run_id" json);
      ("cdal_run_id", U.member "cdal_run_id" json);
      ("contract_id", U.member "contract_id" json);
      ("result_status", U.member "result_status" json);
      ("worker_name", U.member "worker_name" json);
      ("status", U.member "status" json);
      ("mode", U.member "mode" json);
      ("wait_mode", U.member "wait_mode" json);
      ( "trace_capability",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          (worker_run_trace_capability json) );
      ( "trace_validated",
        Option.fold ~none:`Null ~some:(fun v -> `Bool v)
          (worker_run_trace_validated json) );
      ( "validation_failures",
        `List
          (List.map (fun item -> `String item)
             (worker_run_validation_failures json)) );
      ("success", U.member "success" json);
      ("execution_scope", U.member "execution_scope" json);
      ("requested_worker_class", U.member "requested_worker_class" json);
      ("requested_worker_size", U.member "requested_worker_size" json);
      ("resolved_runtime", U.member "resolved_runtime" json);
      ("resolved_model", U.member "resolved_model" json);
      ("routing_reason", U.member "routing_reason" json);
      ("tool_names", U.member "tool_names" json);
      ("tool_call_count", U.member "tool_call_count" json);
      ("output_preview", U.member "output_preview" json);
      ("record_count", U.member "record_count" summary);
      ("assistant_block_count", U.member "assistant_block_count" summary);
      ("final_text", if U.member "final_text" json <> `Null then U.member "final_text" json else U.member "final_text" summary);
      ("stop_reason", if U.member "stop_reason" json <> `Null then U.member "stop_reason" json else U.member "stop_reason" summary);
      ("failure_reason", U.member "failure_reason" json);
      ("error", if U.member "error" json <> `Null then U.member "error" json else U.member "error" summary);
      ("proof_present", U.member "proof_present" json);
      ("tool_trace_refs", U.member "tool_trace_refs" json);
      ("raw_evidence_refs", U.member "raw_evidence_refs" json);
      ("checkpoint_ref", U.member "checkpoint_ref" json);
      ("session_conformance", U.member "session_conformance" json);
      ("ts_iso", U.member "ts_iso" json);
    ]

let actor_activity_state (acc : actor_acc) =
  if acc.observed_event_count > 0 then
    "acted"
  else if acc.mention_count > 0 then
    "mentioned_only"
  else
    "planned_only"

let actor_status_detail (acc : actor_acc) =
  match actor_activity_state acc with
  | "acted" ->
      if acc.interaction_count > 0 then
        "실제 이벤트와 상호작용 흔적이 있습니다."
      else
        "실제 이벤트는 있으나 직접 응답/호출 연결은 약합니다."
  | "mentioned_only" ->
      if acc.mention_count = 1 then
        "호출되었지만 응답, 도구, 산출물 근거는 아직 없습니다."
      else
        Printf.sprintf "%d번 호출되었지만 응답, 도구, 산출물 근거는 아직 없습니다."
          acc.mention_count
  | _ -> "계획된 참여자로 보이지만 아직 남겨진 흔적이 없습니다."

let build_actor_contributions session events =
  let table = Hashtbl.create 16 in
  let known_names = known_session_actor_names session in
  let is_known_name actor =
    List.exists (String.equal actor) known_names
  in
  (match session with
  | Some current ->
      Team_session_types.planned_participant_names current
      |> List.iter (fun actor -> ignore (get_or_create_actor table session actor))
  | None -> ());
  List.iter
    (fun json ->
      match Dashboard_proof_events.event_actor json with
      | None -> ()
      | Some actor ->
          let acc = get_or_create_actor table session actor in
          acc.observed_event_count <- acc.observed_event_count + 1;
          let event_type = string_field "event_type" json |> Option.value ~default:"event" in
          if String.equal event_type "team_turn" then acc.turn_count <- acc.turn_count + 1;
          if String.equal event_type "team_step_spawn" then acc.spawn_count <- acc.spawn_count + 1;
          let tool_names = Dashboard_proof_events.event_tool_names json in
          if tool_names <> [] then acc.tool_evidence_count <- acc.tool_evidence_count + 1;
          if Option.is_some (Dashboard_proof_events.event_related_actor json) then
            acc.interaction_count <- acc.interaction_count + 1;
          acc.recent_tool_names <- tool_name_union acc.recent_tool_names tool_names;
          acc.recent_input_preview <-
            option_prefer_new acc.recent_input_preview (Dashboard_proof_events.event_input_preview json);
          acc.recent_output_preview <-
            option_prefer_new acc.recent_output_preview (Dashboard_proof_events.event_output_preview json);
          acc.recent_event_summary <- Some (Dashboard_proof_events.event_summary json);
          acc.last_active_at <- option_prefer_new acc.last_active_at (string_field "ts_iso" json);
          let request_preview =
            option_first_some (Dashboard_proof_events.event_output_preview json) (Some (Dashboard_proof_events.event_summary json))
          in
          let request_at = string_field "ts_iso" json in
          Dashboard_proof_events.mentioned_actors_of_event json
          |> List.iter (fun target ->
                 if not (String.equal target actor) && is_known_name target then
                   let target_acc = get_or_create_actor table session target in
                   target_acc.mention_count <- target_acc.mention_count + 1;
                   target_acc.requested_by <-
                     option_prefer_new target_acc.requested_by (Some actor);
                   target_acc.recent_request_preview <-
                     option_prefer_new target_acc.recent_request_preview request_preview;
                   target_acc.recent_request_at <-
                     option_prefer_new target_acc.recent_request_at request_at))
    events;
  Hashtbl.to_seq_values table
  |> List.of_seq
  |> List.sort (fun a b ->
         let activity_rank acc =
           match actor_activity_state acc with
           | "acted" -> 0
           | "mentioned_only" -> 1
           | _ -> 2
         in
         let by_rank = Int.compare (activity_rank a) (activity_rank b) in
         if by_rank <> 0 then
           by_rank
         else
           match
             option_first_some a.last_active_at a.recent_request_at,
             option_first_some b.last_active_at b.recent_request_at
           with
           | Some x, Some y -> String.compare y x
           | Some _, None -> -1
           | None, Some _ -> 1
           | None, None -> String.compare a.actor b.actor)

let actor_contributions_json contributions =
  contributions
  |> List.map (fun acc ->
         `Assoc
           [
             ("actor", `String acc.actor);
             ("role", match acc.role with Some value -> `String value | None -> `Null);
             ("activity_state", `String (actor_activity_state acc));
             ("activity_detail", `String (actor_status_detail acc));
             ("observed_event_count", `Int acc.observed_event_count);
             ("turn_count", `Int acc.turn_count);
             ("spawn_count", `Int acc.spawn_count);
             ("tool_evidence_count", `Int acc.tool_evidence_count);
             ("interaction_count", `Int acc.interaction_count);
             ("mention_count", `Int acc.mention_count);
             ( "recent_input_preview",
               match acc.recent_input_preview with
               | Some value -> `String value
               | None -> `Null );
             ( "recent_output_preview",
               match acc.recent_output_preview with
               | Some value -> `String value
               | None -> `Null );
             ( "recent_event_summary",
               match acc.recent_event_summary with
               | Some value -> `String value
               | None -> `Null );
             ( "requested_by",
               match acc.requested_by with
               | Some value -> `String value
               | None -> `Null );
             ( "recent_request_preview",
               match acc.recent_request_preview with
               | Some value -> `String value
               | None -> `Null );
             ( "recent_request_at",
               match acc.recent_request_at with
               | Some value -> `String value
               | None -> `Null );
             ("recent_tool_names", `List (List.map (fun value -> `String value) acc.recent_tool_names));
             ("last_active_at", match acc.last_active_at with Some value -> `String value | None -> `Null);
           ])
