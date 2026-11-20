(** Runtime catalogue lane/slot editing and Keeper runtime assignment picker. *)

module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Admission = Masc_tui_transport.Workspace_admission

(* Fetch the runtime catalogue and assignments for the picker. *)
(* Append one runtime to a lane's candidate order. Appending rather than
   replacing is the whole point: a lane whose two slots share a provider has
   no next candidate when that provider is down, and the fix is one more candidate
   from somewhere else, not a different single one. The server previews the
   resulting runtime.toml and refuses an unknown id, so this sends and reads
   the verdict rather than validating here. *)
(* One lane write off the render loop. Every lane edit -- a pick, a removed
   or moved candidate, a removed lane -- answers through the same message,
   naming the list it changed so that list is the one re-read. *)
let launch_runtime_lane_write ?replacement_selection (state : T.state) ~mailbox ~written write =
  let host = Admission.server_peer_host in
  let port = state.port in
  state.runtime_lane_write <- Masc_tui_types.Lane_write_posting;
  state.runtime_lane_replacement_selection <- None;
  Admission.launch_guarded_request state ~mailbox ~boundary_error:(fun detail -> T.Request_failed detail)
    ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
    ~deliver:(fun result -> P.Runtime_msg (P.Runtime_lane_slots_written (written, replacement_selection, result)))
    (fun () -> write ~host ~port |> Result.map_error (fun detail -> T.Request_failed detail))

;;

(* [e] opens the runtime picker on the Runtime lanes reading, and the same
   key closes it. Inside a typed filter it is a letter. *)
let runtime_picker_close_keys = [ "e"; "E" ]

let launch_runtime_default_route (state : T.state) ~mailbox route_id =
  if T.runtime_lane_write_busy state then
    state.runtime_lane_notice <- Some Masc_tui_types.Lane_write_pending
  else
    launch_runtime_lane_write state ~mailbox
      ~written:Masc_tui_types.Runtime_surface_list (fun ~host ~port ->
        Masc_tui_http.set_runtime_default ~host ~port ~route_id:(Some route_id))
;;

let launch_runtime_lane_pick (state : T.state) ~mailbox ~(pick : Masc_tui_types.runtime_lane_pick)
    ~(runtime : Masc.Tui_decode.runtime_option) ~existing =
  let runtime_id = runtime.Masc.Tui_decode.ro_id in
  let lane = Masc_tui_types.runtime_lane_pick_name pick in
  let written =
    match pick with
    | Masc_tui_types.Pick_exact_lane _ | Masc_tui_types.Pick_exact_lane_replacement _ ->
      Masc_tui_types.Standalone_lanes_list
    | Masc_tui_types.Pick_conversation_lane _ | Masc_tui_types.Pick_new_lane _
    | Masc_tui_types.Pick_media_failover | Masc_tui_types.Pick_route_default ->
        Masc_tui_types.Runtime_surface_list
  in
  match Masc_tui_types.runtime_pick_availability pick runtime with
  | Masc_tui_types.Pick_refused refusal ->
    (* Drawn disabled in the picker; the writer would refuse it anyway. *)
    state.runtime_lane_notice <-
      Some
        (Masc_tui_types.Lane_write_refused
           (Masc_tui_types.Runtime_pick_refused (refusal, runtime)))
  | Masc_tui_types.Pick_available ->
  if T.runtime_lane_write_busy state then
    (* A conversation lane's write is [existing] plus the pick, and
       [existing] is the order the list last read; writing it before the
       previous write is read back would undo that write. *)
    state.runtime_lane_notice <- Some Masc_tui_types.Lane_write_pending
  else
    match
      ( Masc_tui_types.runtime_lane_pick_sends_whole_order pick
      , Masc_tui_types.runtime_lane_candidate_write_refusal state )
    with
    | true, Some notice -> state.runtime_lane_notice <- Some notice
    | true, None | false, (Some _ | None) ->
    match pick with
    | Masc_tui_types.Pick_exact_lane_replacement (lane, slot, group) ->
        let kind = match group with
          | Masc.Tui_decode.Exact_http_slots -> Masc_tui_types.Catalog_slot
          | Masc.Tui_decode.Exact_cli_slots -> Masc_tui_types.Official_client_slot
          | Masc.Tui_decode.Exact_output_unsupported -> Masc_tui_types.Media_route_slot in
        let replacement_selection =
          (Masc_tui_types.Exact_lane_slots lane,
           { Masc_tui_types.si_kind = kind; si_slot = slot },
           { Masc_tui_types.si_kind = kind; si_slot = runtime_id }) in
        launch_runtime_lane_write ~replacement_selection state ~mailbox ~written (fun ~host ~port ->
          Masc_tui_http.replace_exact_lane_slot ~host ~port ~lane
            ~runtime_id:slot ~replacement_runtime_id:runtime_id)
    | Masc_tui_types.Pick_route_default ->
        (* One entry, replaced rather than joined, so [existing] is not a list
           this write extends and a stale reading of it cannot be undone. *)
        launch_runtime_default_route state ~mailbox runtime_id
    | Masc_tui_types.Pick_conversation_lane _ | Masc_tui_types.Pick_exact_lane _
    | Masc_tui_types.Pick_new_lane _ | Masc_tui_types.Pick_media_failover ->
        (* Which of these a stale list can undo is
           [runtime_lane_pick_sends_whole_order]'s to say, above, rather than
           a second list of constructors here. *)
        if List.exists (String.equal runtime_id) existing then
          state.runtime_lane_notice <-
            Some
              (Masc_tui_types.Lane_write_refused
                 (Masc_tui_types.Already_a_candidate { runtime_id; lane }))
        else
          launch_runtime_lane_write state ~mailbox ~written (fun ~host ~port ->
            match pick with
            | Masc_tui_types.Pick_conversation_lane lane ->
                Masc_tui_http.set_runtime_lane_slots ~host ~port ~lane
                  ~expected_runtime_ids:existing
                  ~runtime_ids:(existing @ [ runtime_id ])
            | Masc_tui_types.Pick_exact_lane lane ->
                (* Only the one slot is sent: the server appends it to the order
                   the file declares, so a declared slot the registry dropped is
                   kept. [existing] is used above only to refuse an id the lane
                   already names. *)
                Masc_tui_http.append_exact_lane_slot ~host ~port ~lane ~runtime_id
            | Masc_tui_types.Pick_exact_lane_replacement (lane, slot, _) ->
                Masc_tui_http.replace_exact_lane_slot ~host ~port ~lane
                  ~runtime_id:slot ~replacement_runtime_id:runtime_id
            | Masc_tui_types.Pick_new_lane lane ->
                Masc_tui_http.create_runtime_lane ~host ~port ~lane
                  ~runtime_ids:[ runtime_id ]
            | Masc_tui_types.Pick_media_failover ->
                Masc_tui_http.set_media_failover ~host ~port
                  ~runtime_ids:(existing @ [ runtime_id ])
            | Masc_tui_types.Pick_route_default ->
                (* Answered by its own arm above, which does not reach here. *)
                Masc_tui_http.set_runtime_default ~host ~port
                  ~route_id:(Some runtime_id))
;;

(* Apply a slot-editor key. The plan decides; this only sends it. An exact
   lane's edits name one slot and let the writer read the declared order under
   its lock; the media_failover route has no per-entry action, so its whole
   order is sent -- which the plan allows only while boot dropped none of it. *)
let handle_slot_edit (state : T.state) ~mailbox edit =
  match Masc_tui_types.plan_slot_edit state edit with
  | Masc_tui_types.Refuse_slot_edit notice -> state.runtime_lane_notice <- Some notice
  | Masc_tui_types.Send_slot_write { target; slot; request } ->
      Masc_tui_types.dismiss_runtime_lane_notice state;
      state.runtime_lane_cursor_after_write <- None;
      let written =
        match target with
        | Masc_tui_types.Exact_lane_slots _ -> Masc_tui_types.Standalone_lanes_list
        | Masc_tui_types.Media_failover_slots -> Masc_tui_types.Runtime_surface_list
      in
      launch_runtime_lane_write state ~mailbox ~written (fun ~host ~port ->
        match request, target with
        | Masc_tui_types.Drop_declared_slot, Masc_tui_types.Exact_lane_slots lane ->
            Masc_tui_http.drop_exact_lane_slot ~host ~port ~lane ~runtime_id:slot
        | Masc_tui_types.First_declared_slot, Masc_tui_types.Exact_lane_slots lane ->
            Masc_tui_http.move_exact_lane_slot ~host ~port ~lane ~runtime_id:slot
              ~move:Masc_tui_http.Move_slot_first
        | Masc_tui_types.Move_declared_slot move, Masc_tui_types.Exact_lane_slots lane ->
            Masc_tui_http.move_exact_lane_slot ~host ~port ~lane ~runtime_id:slot
              ~move:
                (match move with
                 | Masc_tui_types.Move_up -> Masc_tui_http.Move_slot_up
                 | Masc_tui_types.Move_down -> Masc_tui_http.Move_slot_down)
        | Masc_tui_types.Write_route_order order, Masc_tui_types.Media_failover_slots ->
            Masc_tui_http.set_media_failover ~host ~port ~runtime_ids:order
        | ( (Masc_tui_types.Drop_declared_slot | Masc_tui_types.First_declared_slot | Masc_tui_types.Move_declared_slot _)
          , Masc_tui_types.Media_failover_slots )
        | Masc_tui_types.Write_route_order _, Masc_tui_types.Exact_lane_slots _ ->
            (* [plan_slot_edit] pairs each request with its target; this arm
               is the pairing the plan does not produce. *)
            Error "the slot editor built a write its target does not take")

(* Apply a lane-editing key. [Masc_tui_types.plan_runtime_lane_edit] decides
   what it does; each write sends the lane's whole order and the server decides
   whether the result is a lane it can load -- an emptied lane or a lane still
   in use is refused there, with the reason drawn on the refusal row. *)
let handle_runtime_lane_edit (state : T.state) ~mailbox edit =
  match Masc_tui_types.plan_runtime_lane_edit state edit with
  | Masc_tui_types.Open_lane_rename_field lane ->
      state.runtime_lane_name_draft <-
        Some (Masc_tui_types.Renaming_lane { lane; draft = lane });
      Masc_tui_types.dismiss_runtime_lane_notice state
  | Masc_tui_types.Open_lane_name_field ->
      state.runtime_lane_name_draft <- Some (Masc_tui_types.Naming_new_lane "");
      Masc_tui_types.dismiss_runtime_lane_notice state;
      Chat_journals.launch_runtime_catalog_load state ~mailbox
  | Masc_tui_types.Arm_lane_removal lane ->
      state.runtime_lane_remove_armed <- Some lane;
      Masc_tui_types.dismiss_runtime_lane_notice state
  | Masc_tui_types.Send_lane_write { lane; request; cursor_after } ->
      let expected_runtime_ids = Masc_tui_types.conversation_lane_candidates state lane in
      (match request with
       | Masc_tui_types.Write_lane_removal -> state.runtime_lane_remove_armed <- None
       | Masc_tui_types.Write_lane_order _ -> ());
      state.runtime_lane_cursor_after_write <- cursor_after;
      launch_runtime_lane_write state ~mailbox
        ~written:Masc_tui_types.Runtime_surface_list (fun ~host ~port ->
        match request with
        | Masc_tui_types.Write_lane_order runtime_ids ->
            Masc_tui_http.set_runtime_lane_slots ~host ~port ~lane
              ~expected_runtime_ids ~runtime_ids
        | Masc_tui_types.Write_lane_removal ->
            Masc_tui_http.remove_runtime_lane ~host ~port ~lane)
  | Masc_tui_types.Refuse_lane_edit notice -> state.runtime_lane_notice <- Some notice

(* The Keeper runtime picker has no close key of its own: Esc closes it,
   after dropping a filter. The shared list already steps on the wheel. *)
let keeper_runtime_picker_action (list : Masc_tui_pick_list.t) key =
  Masc_tui_pick_list.action_of_key ~close_keys:[] list key

(* Back to the Keeper list, with the picker's cursor and filter dropped: a
   picker opened again starts at the top with no filter. *)
let close_keeper_runtime_pick (state : T.state) =
  state.runtime_pick_keeper <- None;
  state.runtime_pick_list <- Masc_tui_pick_list.closed;
  state.detail_focus_recovery <- None;
  T.transition_keeper_view state (T.Keepers T.Keeper_list)

let launch_runtime_assignment_set (state : T.state) ~keeper_name ~runtime_id =
  match T.begin_runtime_assignment_save state ~keeper_name ~runtime_id ~started_ns:(Mtime_clock.elapsed_ns ()) with
  | Error detail -> Masc_tui_loader.report_action state "error" detail; false
  | Ok request ->
      let host = Admission.server_peer_host and port = state.port in
      let prepared = ref None and sent = ref false in
      let publish status =
        let observed_ns = Mtime_clock.elapsed_ns () in
        if T.publish_runtime_assignment request ~observed_ns status then
          Log.Transport.info "tui_runtime_assignment keeper=%s started_ns=%Ld observed_ns=%Ld worker_phase=%s"
            request.T.ras_key.T.ksk_keeper request.T.ras_started_ns observed_ns (T.runtime_assignment_phase status) in
      let finish outcome = publish (T.Assignment_finished (!prepared,outcome)) in
      let interrupted detail = if !sent then T.Assignment_unconfirmed detail else T.Assignment_not_sent detail in
      let check () = if T.runtime_assignment_current state request then Ok ()
        else Error "Original workspace or read authority withdrew before assignment dispatch" in
      let run () =
        let outcome = try
          let open Result.Syntax in
          let prepare () =
            let* () = check () in
            publish T.Assignment_reading;
            let* snapshot = Masc_tui_http.fetch_keeper_config_snapshot ~host ~port ~keeper_name:request.T.ras_key.T.ksk_keeper in
            let* revision = Masc_tui_response_decode.run ~name:"keeper.runtime_assignment.decode_wait"
              (fun () -> Masc_tui_keeper_config.expected_runtime_assignment_revision snapshot) in
            let source = { T.rap_snapshot = snapshot; rap_expected_revision = revision } in
            prepared := Some source;
            let* () = check () in
            Ok source in
          match prepare () with
          | Error detail -> T.Assignment_not_sent detail
          | Ok source ->
              sent := true;
              publish (T.Assignment_posting source);
              match Masc_tui_http.post_runtime_assignment ~host ~port ~keeper_name:request.T.ras_key.T.ksk_keeper
                ~runtime_id:request.T.ras_runtime_id ~expected_assignment_revision:source.T.rap_expected_revision with
              | Ok write -> T.Assignment_answered write
              | Error (Masc_tui_keeper_config.Assignment_revision_conflict response) -> T.Assignment_conflict response
              | Error (Masc_tui_keeper_config.Assignment_auth_refused { status; body }) ->
                  T.Assignment_refused (Masc_tui_http.named_refusal "runtime assignment" ~status ~body)
              | Error (Masc_tui_keeper_config.Assignment_outcome_unconfirmed detail) -> T.Assignment_unconfirmed detail
        with
        | Eio.Cancel.Cancelled _ as exn -> finish (interrupted "Assignment worker interrupted"); raise exn
        | exn -> interrupted (Printexc.to_string exn) in
        finish outcome in
      Log.Transport.info "tui_runtime_assignment keeper=%s started_ns=%Ld phase=checking"
        request.T.ras_key.T.ksk_keeper request.T.ras_started_ns;
      (match Eio_context.get_switch_opt () with
       | None -> finish (T.Assignment_not_sent "Eio switch is unavailable")
       | Some sw ->
           (* This launcher holds no mailbox to report a refused precondition
              to, so its requests go out unscoped as before. *)
           (match Masc_tui_workspace_job.fork state ~sw
             ~on_withdrawn:(fun () -> finish (interrupted "Workspace withdrew before worker entry")) run with
            | () -> ()
            | exception (Eio.Cancel.Cancelled _ as exn) -> finish (interrupted "Assignment worker interrupted"); raise exn
            | exception exn -> finish (interrupted (Printexc.to_string exn))));
      true

(* One key on the Keeper runtime picker, read against the list it draws: the
   declared lanes, then the whole catalogue. Enter assigns the row under the
   cursor to the Keeper the picker was opened for; Esc with no filter closes
   it. *)
let keeper_runtime_pick_key (state : T.state) ~terminal_rows key =
  match keeper_runtime_picker_action state.runtime_pick_list key with
  | None -> ()
  | Some action -> (
      match
        Masc_tui_pick_list.apply
          ~page:(Masc_tui_types.keeper_runtime_picker_page state ~terminal_rows)
          ~label:Masc_tui_types.runtime_pick_label
          (Masc_tui_types.runtime_picker_items state)
          state.runtime_pick_list action
      with
      | Masc_tui_pick_list.Stay list -> state.runtime_pick_list <- list
      | Masc_tui_pick_list.Chosen item ->
          (match state.runtime_pick_keeper with
           | Some keeper_name ->
               if launch_runtime_assignment_set state ~keeper_name
                    ~runtime_id:(Some (Masc_tui_types.runtime_pick_item_id item))
               then close_keeper_runtime_pick state
           | None -> close_keeper_runtime_pick state)
      | Masc_tui_pick_list.Dismissed -> close_keeper_runtime_pick state)
