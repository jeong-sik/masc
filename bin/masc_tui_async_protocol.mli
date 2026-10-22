(** Async reply contracts shared by the TUI producers and result application.
    Request/generation identities and dispatch acknowledgements travel in the
    payload. Mutable UI state, enqueue clocks and fibers remain in the loop. *)

open Masc_tui_types

type task_cancel_outcome =
  | Task_cancel_confirmed of string
  | Task_cancel_refused of string
  | Task_cancel_unconfirmed of string

type ask_followup_read = private {
  afr_request : Snapshot_read.request;
  afr_submission : ask_submission;
  afr_origin : Masc_tui_observation_origin.t;
  afr_admission_started_ns : int64;
  afr_admission_capture : Masc_tui_observation_store.admission_capture option;
}
val capture_ask_followup_read :
  origin:Masc_tui_observation_origin.t -> request:Snapshot_read.request ->
  submission:ask_submission -> admission_started_ns:int64 ->
  admission_capture:Masc_tui_observation_store.admission_capture option -> ask_followup_read
(** Assemble original immutable provenance and its capture receipt after the
    caller captures that origin and records this admission, before dispatch.
    [None] retains that no configured store was attempted. UI, producers and late
    cleanup consume the same capsule, not replacement state or a later receipt. *)

type approval_observation = {
  ao_ticket: Masc_tui_operator_projection.Listing_order.ticket;
  ao_result: (approval_snapshot, string) result;
}

type http_read_requests = {
  hrr_authority: workspace_authority;
  hrr_approval: Masc_tui_operator_projection.Listing_order.ticket option;
  hrr_asks: Snapshot_read.request option;
  hrr_roster: Snapshot_read.request option;
  hrr_surfaces: Surface_read_context.t;
}

type http_initial_identity_read = {
  hir_ticket: Http_refresh_order.ticket;
  hir_authority: workspace_authority;
  hir_identity: Masc.Tui_decode.server_identity;
  hir_needs: surface_needs;
  hir_surface_context: Surface_read_context.t;
  hir_acknowledge: http_read_requests option Eio.Promise.u;
}
(** The UI may admit a cold matching probe before collection, then issue fresh
    source requests under the successor workspace authority. [None] retains
    terminal admission; it grants no new authority to the worker. *)

type early_approval_observation = {
  eap_ticket: Http_refresh_order.ticket;
  eap_authority: workspace_authority;
  eap_identity: Masc.Tui_decode.server_identity;
  eap_observation: approval_observation;
}

(* Each value settles one independently owned dataset. Board's two datasets
   share a logical source, while neither delivery consumes its sibling. *)
type http_dataset =
  | Dataset_transport of (Masc.Tui_decode.transport_health, string) result
  | Dataset_board_posts of board_posts_receipt
  | Dataset_board_hearths of ((string * int) list, string) result
  | Dataset_planning of (planning_snapshot, string) result
  | Dataset_system_logs of (system_log_snapshot, string) result
  | Dataset_fleet_safety of (Masc.Tui_decode.fleet_safety_reading, string) result
  | Dataset_runtime_quota of
      (Masc.Tui_decode.runtime_option list, string) result
      * (Masc.Tui_decode_usage.provider_usage_windows, string) result
  | Dataset_keeper_usage of (Masc.Tui_decode_usage.keeper_usage_window, string) result
  | Dataset_provider_history of
      int * (Masc.Tui_decode_usage.provider_usage_history, string) result
  | Dataset_overview_goals of (Masc.Tui_decode.overview_goal list, string) result
  | Dataset_account_emails of ((string * string) list * int, string) result

type early_http_dataset = {
  ed_ticket: Http_refresh_order.ticket;
  ed_authority: workspace_authority;
  ed_request: Surface_read_order.request;
  ed_identity: Masc.Tui_decode.server_identity;
  ed_dataset: http_dataset;
}

val http_dataset_key : http_dataset -> Surface_read_order.dataset
val http_dataset_received : http_dataset -> bool

(* Collection has no identity authority of its own. The enclosing full or
   scoped request owns the before/after probes and binds the final identity
   only after its entire read interval has settled. [unit] readings cannot
   be sent as [Http_scoped_refresh_done] or applied as a verified bundle. *)
type 'identity http_scoped_surface_readings = {
  http_refresh_ticket: Http_refresh_order.ticket;
  http_surface_request: Surface_read_order.request;
  http_scoped_server_identity: 'identity;
  http_transport: (Masc.Tui_decode.transport_health, string) result option;
  http_approvals: approval_observation option;
  (* [None] on surfaces that do not draw them. Each is read by one surface, and
     leaving it out keeps whatever that surface last observed rather than
     dropping it. *)
  http_asks: asks_observation option;
  http_board: board_posts_receipt option;
  (* Listing and census are requested together under one Board request. Early
     delivery settles each dataset independently; the prior census remains
     available while its fresh reader is pending or failed. *)
  http_board_hearths: ((string * int) list, string) result option;
  http_planning: (planning_snapshot, string) result option;
  http_system_logs: (system_log_snapshot, string) result option;
  http_fleet_safety: (Masc.Tui_decode.fleet_safety_reading, string) result option;
  (* [None] on surfaces that do not read the roster or its Candle summary;
     leaving it out keeps the observation until a relevant refresh. *)
  http_keeper_roster: keeper_roster_observation option;
  (* [None] off Dashboard and Usage. One fetch, two readings: the runtime
     rows and the provider usage windows. *)
  http_runtime_quota:
    ((Masc.Tui_decode.runtime_option list, string) result
    * (Masc.Tui_decode_usage.provider_usage_windows, string) result)
    option;
  http_keeper_usage: (Masc.Tui_decode_usage.keeper_usage_window, string) result option;
  http_provider_history:
    (int * (Masc.Tui_decode_usage.provider_usage_history, string) result) option;
  (* [None] off the Overview, the one surface that draws the GOALS section. *)
  http_overview_goals: (Masc.Tui_decode.overview_goal list, string) result option;
  (* [None] off Usage, the surface that draws account emails. *)
  http_account_emails: ((string * string) list * int, string) result option;
}

type http_scoped_surface_results =
  (Masc.Tui_decode.server_identity, string) result http_scoped_surface_readings

type http_surface_results = {
  http_overview: (overview_snapshot, string) result;
  http_approvals: approval_observation option;
  http_scoped: http_scoped_surface_results;
  (* Mandatory on every refresh: the same endpoint may name a different
     server after a restart, without a failed request reaching this process. *)
  http_server_identity: (Masc.Tui_decode.server_identity, string) result;
}

(* What one full refresh came back with. A booting server answers the probe
   and nothing else, so there are no surfaces to carry. *)
type http_refresh_outcome =
  | Refresh_surfaces of http_surface_results
  | Refresh_workspace_unconfirmed of
      { refresh_ticket : Http_refresh_order.ticket; detail : string; unreachable : bool;
        approval_ticket : Masc_tui_operator_projection.Listing_order.ticket option;
        latest_identity : (Masc.Tui_decode.server_identity, string) result
        (* The identity read after the surfaces; it may name a workspace. *) }
  | Refresh_server_booting of
      { refresh_ticket : Http_refresh_order.ticket
      ; identity : (Masc.Tui_decode.server_identity, string) result
      ; (* The ticket [start_http_refresh] took before the probe went
           out. Carried so the approvals panel learns why its rows are stale,
           the same way a failed refresh tells it. *)
        approval_ticket : Masc_tui_operator_projection.Listing_order.ticket option
      }

type play_sink = Play_chat of string option
  | Play_collab of { owner : unit ref; mutation : Masc_tui_collab.mutation }
type play_list_sink = Play_chat_list of string option | Play_collab_list of Masc_tui_collab.read

type preset_sink =
  | Preset_to_chat of string option
  | Preset_to_pane

(* The UI domain owns these refs. A posted tick is a mutation: closing its
   view invalidates presentation, never cancels or retries the request. Keep
   the pending request until its terminal mailbox result, even across reopen. *)
type msx_poll_request = { poll_view : unit ref; poll_port : int; poll_authority : Masc_tui_types.workspace_authority; poll_reading : unit ref }

(* A DOS read changes nothing on the server. The current view owns one read;
   reopening may start another without waiting for an old view's HTTP timeout.
   Only the owning request may clear its state slot or draw its answer. *)

type lane_addons_failure = [ `Inventory of string | `Detail of string | `Request of string ]

type lane_addons_reply = {
  lar_snapshot : Masc_tui_lane_addons.snapshot option;
  lar_receipt : Yojson.Safe.t option;
  lar_action : Masc.Lane_addon_action.receipt option;
  lar_diagnostic : Masc_tui_lane_addons.diagnostic option;
  lar_inventory_read : [ `Unchanged | `Read | `Failed of string ];
}


type 'a play_mutation =
  | Play_answered of ('a, string) result
  | Play_refused of string
  | Play_not_dispatched of string
  | Play_unanswered of string

type play_revoke =
  | Play_revoke_absent
  | Play_revoke_release_failed of string
      (** The invite was already gone; the server answered that the DOS
          controller it held could not be released. *)
  | Play_revoke_result of Masc.Tui_decode.play_invite_revoked play_mutation

type currency_authority_request = {
  car_generation : int;
  car_identity : Masc.Tui_decode.server_identity option;
}

(* What the resume preflight learned about the Keeper's owner before the queue
   snapshot is read. *)
type resume_confirmation =
  | Owner_resumed
  | Owner_already_active

type async_msg =
  | Chat_search_finished of int * bool * Masc_tui_render_chat.chat_search_plan
      * (Masc_tui_render_chat.chat_search_work * Masc_tui_render_chat.chat_search_match, string) result
  | Workspace_scoped of workspace_authority * unit ref option * async_msg
  | Workspace_operation of async_msg
  | Chat_command_read_completed of unit ref * async_msg
  | Workspace_identity_unconfirmed of
      { detail : string
      ; latest : (Masc.Tui_decode.server_identity, string) result
        (* The identity the refusing probe read; it may name a workspace. *)
      ; prior_contact : Masc_tui_server_lifecycle.contact
      ; refresh_ticket : Http_refresh_order.ticket }
  | Schedule_form_authority_refused of
      { action : string; detail : string; workspace : workspace_input_identity option }
      (** A schedule create/modify form refused by the workspace guard: the
          guard's withdrawal, then the refusal kept on the Schedules surface. *)
  | Lane_package_catalog_loaded of int * string option * (Yojson.Safe.t, string) result
  | Lane_package_preview_loaded of int * string * (Yojson.Safe.t, string) result
  | Keeper_queue_resume_confirmed of string * int * resume_confirmation
  | Keeper_queue_loaded of string * int option * Masc_tui_queue_inspection.action * (string list * (string list, string) result, string) result
  | Lane_addons_loaded of int * Masc_tui_lane_addons.read_target * (lane_addons_reply, lane_addons_failure) result
  | Lane_application_loaded of Masc_tui_lane_application.ticket
      * (Masc_tui_lane_addons.configuration, string) result
  | Lane_subscriptions_loaded of int * (Masc_tui_lane_subscriptions.snapshot,string) result
  | Lane_declaration_loaded of int * Masc_tui_lane_declaration.request * bool * string option
      * (Masc_tui_lane_declaration.response, string) result
  | Keeper_deletions_loaded of int * (Masc_tui_keeper_control.deletion_inventory, string) result
  | Msx_tick_withdrawn of msx_poll_request * string
  | Keeper_deletion_retry_done of string * (unit, string) result
  | Msx_frame_loaded of msx_poll_request
      * (Masc_tui_msx_tick.response, string) result
  | Msx_activity_loaded of msx_poll_request
      * (Masc_tui_msx_tick.activity * (Masc_tui_machine_live.answer * Masc_tui_machine_live.activity, string) result, string) result
  | Msx_live_loaded of machine_live_request
      * (Masc_tui_machine_live.answer * Masc_tui_machine_live.activity, string) result
  | Dos_live_loaded of machine_live_request
      * (Masc_tui_machine_live.answer * Masc_tui_machine_live.activity, string) result
  (* A microphone capture, from the fiber that runs it. The keeper is carried
     on every one of these rather than read from the state at delivery: the
     roster cursor moves under a refresh, and a transcript that took several
     seconds would otherwise land on whoever happens to be selected when it
     arrives. *)
  (* The wizard's replies carry the save they answer, and
     [Masc_tui_voice_wizard_session.voice_wizard_after_save] and its two siblings drop one the
     open session is not waiting on. *)
  | Voice_wizard_saved of int * Masc_tui_voice_wizard_session.voice_wizard_save_reply
  (* The keeper-voice screen: the voices its endpoint answers to, and what
     the setup route said about the one line it writes. *)
  | Voice_agent_voices_loaded of (Yojson.Safe.t, string) result
  | Voice_agent_voice_saved of (Yojson.Safe.t, string) result
  | Voice_wizard_probed of int * (Yojson.Safe.t, string) result
  | Voice_wizard_reread of int * (string, string) result
  | Voice_config_loaded of
      (Yojson.Safe.t, string) result
      * (Yojson.Safe.t, string) result
      * string option
  | Voice_calibrated of { keeper : string; floor : float option }
  | Voice_level of { keeper : string; level : Masc.Voice_bridge.capture_level }
  | Voice_transcribed of { keeper : string; text : string }
  | Voice_silent of { keeper : string; reason : string }
  (* The operator abandoned a recording that had speech in it. Its own row
     rather than a silence: the microphone worked. *)
  | Voice_discarded of { keeper : string; reason : string }
  | Voice_failed of { keeper : string; error : string }
  (** A verified read-only preview. It does not finish the full refresh or
      grant workspace authority; the terminal bundle still owns both. *)
  | Http_overview_loaded of overview_preview
  (** Verified questions may settle their own read before the full bundle. *)
  | Http_asks_loaded of early_asks_observation
  | Http_approvals_loaded of early_approval_observation
  | Ask_answer_receipt_ready of ask_submission
      (** The original submission owns the published receipt; this message only
          asks the loop to observe it. *)
  | Ask_followup_observed of ask_followup_read * Masc.Tui_decode_asks.ask_followup_event * int64
  | Ask_followup_finished of ask_followup_read * Masc_tui_ask_projection.followup_result
  (** A workspace-bound roster can settle before unrelated readers. *)
  | Http_keeper_roster_loaded of early_keeper_roster_observation
  | Http_dataset_loaded of early_http_dataset
  (** Diagnostic reader status; it grants no data or action authority. *)
  | Http_surface_read_completed of Surface_read_context.t * async_msg
  | Http_initial_identity_read of http_initial_identity_read
  | Http_refresh_done of http_refresh_outcome
  | Http_refresh_failed of
      string * Masc_tui_operator_projection.Listing_order.ticket option * Http_refresh_order.ticket
  | Approvals_listing_superseded
  | Approvals_summary_loaded of
      Masc_tui_types.Snapshot_read.request
      * Masc_tui_operator_projection.Listing_order.ticket
      * Masc.Tui_decode.server_identity
      * (approval_snapshot, string) result
  | Surface_composer_released
  | Http_scoped_refresh_done of workspace_authority * currency_authority_request * http_scoped_surface_results
  | Http_scoped_refresh_failed of
      workspace_authority * string * Masc_tui_operator_projection.Listing_order.ticket option * Http_refresh_order.ticket
      * (Masc.Tui_decode.server_identity, string) result option
        (* The last identity its probes read, if any. *)
      * Surface_read_order.request
  | Board_post_refresh_done of
      Masc_tui_board_detail.request * (board_post * board_comment list * string option, string) result
  | Approval_decision_done of
      approval_item
      * approval_decision
      * (Masc_tui_operator_projection.confirm_outcome, string) result
      * Masc_tui_operator_projection.Flow.generation
      * (approval_snapshot, string) result
  (* The answer that came back, and the list re-read behind it. The store
     settles on first write, so the response says what was actually recorded
     -- which may be someone else's answer. The submission carries the original
     workspace, Keeper, Ask and human label; none is recovered from prose. *)
  | Ask_answer_done of
      ask_submission
      * (Masc.Tui_decode_asks.answer_receipt, string) result
      * (Masc.Tui_decode_asks.asks_snapshot, string) result
  | Keeper_chat_dispatch_started of
      Masc_tui_keeper_chat_projection.request * bool * bool Eio.Promise.u
  | Keeper_chat_done of
      Masc_tui_keeper_chat_projection.request
      * bool
      * (Masc_tui_keeper_chat_projection.response, Masc_tui_keeper_chat_projection.error) result
      * unit Eio.Promise.u
  | Keeper_chat_stream_deltas of
      Masc_tui_keeper_chat_projection.request * Masc_tui_keeper_chat_live.observed_delta list
  | Keeper_chat_stream_unavailable of Masc_tui_keeper_chat_projection.request * string
  | Keeper_run_next_done of Masc_tui_keeper_chat_projection.request * (string, string) result
  | Keeper_observed_interrupt_done of
      string * string * int * (Masc_tui_interrupt_signal.interrupt_signal, string) result
  | Keeper_chat_interrupt_done of
      Masc_tui_keeper_chat_projection.request * int * (Masc_tui_interrupt_signal.interrupt_signal, string) result
  | Keeper_chat_history_loaded of
      Keeper_history_read.t * Keeper_history_read.source * Keeper_history_read.result
  | Keeper_chat_first_page_loaded of
      Keeper_history_read.t * Keeper_history_read.page_result
  | Keeper_chat_copy_loaded of
      int * string * (Masc_tui_keeper_chat_history.decoded, string) result
  | Keeper_chat_operation_loaded of
      { keeper_name : string
      ; operation_id : string
      ; operation_state : (Keeper_chat_operation.state, string) result
      }
  | Keeper_chat_journal_loaded of
      { keeper_name : string
      ; source : Masc_tui_keeper_chat_log.journal_source
      ; started_at : float
      ; terminal_replay : Masc_tui_keeper_chat_log.terminal_replay
      ; operation_state : (Keeper_chat_operation.state option, string) result
      ; journal :
          ( Masc.Keeper_chat_event_log.journaled_event list
          , Masc_tui_keeper_chat_log.events_error )
          result
      }
  | Keeper_native_tasks_loaded of
      string * (Masc_tui_native_tasks.t, Masc_tui_native_tasks.error) result
  | Keeper_preparation_loaded of
      Masc_tui_preparation_details.request * (Masc_tui_preparation_details.snapshot, string) result
  | Keeper_child_content_loaded of
      string * (Masc_tui_child_content.t, Masc_tui_child_content.error) result
  | Context_inspector_loaded of
      int * string * Masc_tui_context_inspector.reading
  | Context_inspector_part_loaded of
      Masc_tui_context_inspector.part_key Masc_tui_fetched.request
      * (string, string) result
  | Keeper_chat_older_loaded of
      int * string * string option * (Masc_tui_keeper_chat_history.page, Masc_tui_keeper_chat_history.page_error) result
  | Live_context_loaded of Masc_tui_context_state.request * int64
      * (Masc.Tui_decode.context_observation, string) result
  | Local_keepers_read of local_workspace_request * (Masc_tui_loader.local_keeper_reading, string) result
  | Local_workspace_read of local_workspace_request * (Masc_tui_loader.local_reading, string) result
  | Lanes_loaded of
      unit ref * ( Masc.Tui_decode.keeper_lanes_snapshot
        * Masc.Tui_decode.keeper_secret_projection list,
        string )
      result
  | Lane_inventory_loaded of
      int * (Masc.Tui_decode_lane_inventory.snapshot, string) result
  | Clients_loaded of
      int * (Masc.Tui_decode.clients_snapshot, string) result
  (* Keyed by the lane / run they answer for: an answer that lands after the
     operator left the list or the run is not this view's answer. *)
  | Lane_runs_loaded of
      Standalone_lane.t * int * (float * string) option *
      (Masc.Tui_decode.lane_run_page, string) result
  | Lane_run_detail_loaded of
      string * int * (Masc.Tui_decode.lane_run_detail, string) result
  | Measurement_artifact_loaded of
      string * int * (Measurement.t, string) result
  | Verification_loaded of (Masc.Tui_decode.verification_snapshot, string) result
  | Harness_loaded of (Masc.Tui_decode.harness_snapshot, string) result
  | Fusion_runs_loaded of
      unit Masc_tui_fetched.request * (Masc.Tui_decode_fusion.fusion_snapshot, string) result
  | Fusion_detail_loaded of
      int * string * (Masc.Tui_decode_fusion.fusion_detail, string) result
  | Fusion_historical_detail_loaded of
      int * Masc.Tui_decode_fusion.fusion_historical_evidence
      * (Masc.Tui_decode_fusion.fusion_historical_detail, string) result
  (* Both carry the launch generation: the answer to a read or a submit the
     operator already left must not open or close a form they are not in. *)
  | Fusion_launch_options_loaded of
      int * (Masc.Tui_decode_fusion.fusion_launch_options, string) result
  | Fusion_launched of int * (string, string) result
  | Repositories_loaded of (Masc.Tui_decode.repository_snapshot, string) result
  | Workspace_activity_loaded of string Masc_tui_fetched.request * (workspace_activity_read, string) result
  | Memory_loaded of (Masc.Tui_decode_memory_health.memory_health_snapshot, string) result
  | Memory_input_loaded of string Masc_tui_fetched.request
      * (Masc_tui_memory_usage.t, string) result
  (* Carries the request it answers: the browser can be closed or pointed at
     another keeper while a load is in flight, and a late answer for somebody
     else must be dropped, not filed under whoever is open. The answer is the
     facts and, for the "all keepers" merge, the keepers it could not read. *)
  | Memory_facts_loaded of
      string Masc_tui_fetched.request
      * (Masc.Tui_decode_memory_facts.memory_fact_snapshot * string option, string) result
  | Repository_changes_loaded of
      Masc.Tui_decode.repository_change_scope
      * (Masc.Tui_decode.repository_change_snapshot, string) result
  | Repository_changes_diff_loaded of
      repository_diff_request * (Masc.Tui_decode.git_diff, string) result
  (* Carries the keeper it was asked about. The surface can be pointed at a
     different keeper while a load is in flight, and an answer that did not
     say whose it was would be filed under whoever is selected when it
     lands. *)
  | File_changes_loaded of
      string * (Masc.Tui_decode.file_change_snapshot, string) result
  | Keeper_chat_file_changes_loaded of
      int * string * (Masc.Tui_decode.file_change_snapshot, string) result
      (** Generation and keeper-stamped answer for the chat-only cache. The
          Changes surface owns [File_changes_loaded] and is never populated by
          this response. *)
  (* Keyed by the path it answers for, for the same reason the file-change
     message carries a keeper: an answer for a file the operator has since
     left is not this view's answer. *)
  | Git_diff_loaded of string * (Masc.Tui_decode.git_diff, string) result
  | Browser_history_list_loaded of int * (Masc.Tui_decode.keeper_calls_snapshot, string) result
  | Browser_history_page_loaded of int * (Masc.Browser_observation.t, string) result
  | Browser_lane_clients_loaded of int * (Browser_lane_view.discovered, string) result
  | Browser_lane_loaded of
      int * (Browser_lane_view.reading, string) result
  | Browser_lane_action_done of int * (unit, string) result
  | Browser_lane_scene_loaded of int * (Browser_lane_view.scene, string) result
  | Browser_lane_follow_loaded of int *
      ((Masc_tui_http.browser_follow_receipt *
        (Browser_lane_view.scene, string) result), string) result
  | Browser_lane_screenshot_ready of {
      generation : int; image_generation : int;
      result : (Browser_lane_view.screenshot * string, string) result;
    }
  | Connectors_status_loaded of Connector_read.request * Masc.Tui_decode_connectors.connector_snapshot
  | Connectors_loaded of Connector_read.request * (Masc.Tui_decode_connectors.connector_snapshot, string) result
  | Connector_unbind_all_done of {
      keeper_name : string;
      results :
        (Masc_tui_connector_unbind.target * Masc_tui_connector_unbind.outcome)
        list;
    }
  | Runtime_surface_loaded of
      int * (Masc_tui_loader.runtime_surface_load, string) result
  | Tools_loaded of int * string option * (Masc.Tui_decode_tools.tool_snapshot, string) result
  | Skills_catalog_loaded of int * (Masc.Tui_decode_tools.skills_catalog, string) result
  | Skill_evidence_loaded of unit ref * string * (Yojson.Safe.t, string) result
  | Tools_async_observation_loaded of int * (Masc.Tui_decode.async_request_observation, string) result
  | Tools_async_detail_loaded of Masc_tui_types.tools_async_detail_request * (Masc.Tui_decode_async_request.reading, string) result
  | Task_document_prepared of Masc_tui_types.task_document_request * (string list, string) result
  | Tools_async_task_body_loaded of Masc_tui_types.tools_async_task_request * (Masc.Tui_decode_task_inspection.detail, string) result
  | Tools_async_task_history_loaded of Masc_tui_types.tools_async_task_source Masc_tui_types.task_history_request * (Masc.Tui_decode_task_inspection.history, string) result
  | Runtime_lane_slots_written of
      Masc_tui_types.runtime_lane_list
      * (Masc_tui_types.slot_editor_target * Masc_tui_types.slot_editor_identity * Masc_tui_types.slot_editor_identity) option
      * (Masc_tui_runtime_config_receipt.t, string) result
  | Runtime_catalog_loaded of
      runtime_catalog_request * ( Masc.Tui_decode.runtime_option list
        * Masc.Tui_decode.runtime_resolved_lane list
        * Masc.Tui_decode.runtime_assignment list
        * string option,
        string )
      result
  | Runtime_assignment_changed of runtime_assignment_request * runtime_assignment_status * int64
  | Keeper_chat_approval_answered of
      Masc_tui_keeper_chat_projection.request
      * string
      * bool
      * (Masc_tui_http.tool_approval_answer, string) result
  | Keeper_tool_approvals_loaded of
      Snapshot_read.request * Masc.Tui_decode.server_identity * (Masc.Tui_decode.keeper_tool_approval list, string) result
  | Sent_image_ready of {
      generation : int;
      view : surface;
      keeper_name : string option;
      name : string;
      skill_reference : Skill_reference.t option;
      result : (Masc_tui_image_cache.presentation, string) result;
    }
  | Image_render_ready of {
      title : string;
      caption : string list;
      page_url : string;
      image_url : string;
      result : (string, string) result;
    }
      (** A [v]-requested web image, downloaded and converted to PNG off the
          render loop. [result] is the PNG bytes ready to draw, or why they
          could not be produced. [title] is indented for the screen and is
          never a location. [image_url] is what was fetched; [page_url] is the
          link the operator chose, and the one a browser gets when drawing
          fails (see [Masc_tui_browser.browser_url]). *)
  | Keeper_turns_loaded of (string * int) list * (Masc.Tui_decode.keeper_turn_row list, string) result
  | Keeper_chat_control_received of string * int * string
      (** Which keepers are mid-turn right now, for the "answering now"
          badge drawn from every surface. *)
  | Gate_snapshot_loaded of Snapshot_read.request * Masc.Tui_decode.server_identity *
      (Masc.Tui_decode.gate_snapshot, string) result
      (** The durable Gate beside the held calls: pending approvals that
          survive nobody watching, and both lane modes. *)
  | Gate_approval_resolved of
      string * bool * Masc.Tui_decode.server_identity * (unit, string) result * Masc_tui_operator_projection.Flow.generation
      (** approval id, approve, the resolve result, and the in-flight
          generation this decision holds. Completion releases that slot, so
          the header stops drawing [submitting] and a second press is admitted
          again. *)
  | Gate_auto_judge_retried of
      string * Masc.Tui_decode.server_identity * (unit, string) result * Masc_tui_operator_projection.Flow.generation
      (** approval id, captured workspace, rearm outcome, and the action slot this explicit retry
          owns. The server accepts it only if every observed identity field
          still matches the blocked row. *)
  | Gate_mode_set of Masc_tui_palette.gate_lane * string * (unit, string) result
      (** The external-services lane the operator asked for, and whether the
          server took it. *)
  | Surface_tool_approval_answered of
      string
      * string
      * bool
      * (Masc_tui_http.tool_approval_answer, string) result
      * Masc_tui_operator_projection.Flow.generation
  (* Its own message rather than a field on the stance one: the two come from
     different endpoints and one failing must not blank the other. *)
  | Keeper_gate_settings_loaded of
      (((string * Masc.Tui_decode.gate_mode) list * Masc.Tui_decode.keeper_exact_lane_first list), string) result
  | Keeper_tool_modes_loaded of
      ((string * Masc.Keeper_tool_approval_mode.mode) list, string) result
      * Masc_tui_operator_projection.Listing_order.ticket
      (** The stance listing replaces the whole yolo set, so a fetch that
          started before an operator armed a gate would put the pre-press
          answer back. This no longer rides a generation that every reader
          advances for itself: that made two unrelated listings invalidate
          each other, so a tool-modes fetch racing any unrelated background
          poll (not only a press) was dropped even with no press ever armed
          (#37461). The generation carried here is only ever advanced by
          [Masc_tui_operator_projection.Flow.begin_action] (a press), and is observed -- not
          reserved -- at dispatch time, so [Masc_tui_operator_projection.Flow.is_current] at
          arrival answers exactly "did a press open since this fetch went
          out", including one that opened and closed in between (#37609
          review: a dispatch-time-only [action_inflight] check cannot see
          that). The ticket also numbers the fetch: a full and a scoped
          refresh each launch one, so two can be out at once and the older
          answer may land last (task-1672). *)
  | Keeper_tool_mode_set of
      string
      * Masc.Keeper_tool_approval_mode.mode
      * (unit, string) result
      * Masc_tui_operator_projection.Flow.generation
      (** keeper, tool call id, allow, and whether a wait was released — the
          Approvals-surface twin of [Keeper_chat_approval_answered], which
          needs the chat request this path does not have. *)
  | Keeper_chat_dispatch_blocked of Masc_tui_keeper_chat_projection.request * string
  | Keeper_logs_loaded of keeper_log_request * (Masc_tui_metrics_tail.snapshot, string) result
  | Keeper_settings_save_changed of keeper_settings_save_request * keeper_settings_save_status * int64
  | Runtime_form_save_changed of runtime_form_save_request * runtime_form_save_status * int64
  | Keeper_creation_changed of keeper_creation_request * keeper_creation_status
  | Keeper_action_done of
      Masc.Tui_decode.server_identity option
      * string
      * Masc_tui_keeper_control.action
      * (Masc_tui_keeper_control.outcome, string) result
  | Board_new_post_done of {
      reply_to : string option;
      sent_draft : string;
      sent_attachments : Masc_tui_types.board_staged_attachment list;
      result : (string, string) result;
    }
  | Board_vote_done of Masc_tui_types.board_vote_target * (string, string) result
  | Goal_transition_done of (string, string) result
  | Goal_confirmation_submitted of (string, string) result
  | Goal_confirmation_loaded of
      string Masc_tui_fetched.request * (Masc_tui_planning_detail.confirmation, string) result
  | Schedules_loaded of Snapshot_read.request * (schedule_snapshot, string) result
  (* Carries the schedule it was asked about: the reader can step to the next
     row or close the detail while a load is in flight, and an answer that did
     not say whose it was would be filed under whoever is open when it lands. *)
  | Schedule_wake_history_loaded of
      string * (schedule_wake_history, string) result
  (* Carries the keeper it was asked about: the roster cursor can move while a
     load is in flight, and an answer that did not say whose it was would be
     filed under whoever is selected when it lands. *)
  | Keeper_schedules_loaded of detail_read_request * (schedule_snapshot, string) result
  | System_logs_loaded of Surface_read_order.request * (system_log_snapshot, string) result
  | Schedule_cancel_done of string * (string, string) result
  (* (message, noop): [noop = true] says the verdict already stood. *)
  | Verification_verdict_done of (string * bool, string) result
  | Harness_label_done of (string, string) result
  | Chat_call_loaded of chat_call_request * (Masc.Tui_decode.keeper_call, string) result
  | Board_attachment_loaded of Masc_tui_board_reader.request * (Masc_tui_board_reader.content, string) result
  | Board_attachment_prepared of Masc_tui_board_reader.preparation_request * (Masc_tui_detail_reading.row list, string) result
  | Board_attachment_saved of Masc_tui_board_reader.request * (string, string) result
  | Keeper_calls_loaded of
      int * string * (Masc.Tui_decode.keeper_calls_snapshot, string) result
  | Goal_timeline_loaded of
      string Masc_tui_fetched.request * (Masc.Tui_decode.goal_timeline, string) result
  | Task_history_loaded of
      string Masc_tui_types.task_history_request * (Masc.Tui_decode_task_inspection.history, string) result
  | Task_cancel_done of string * Masc.Tui_decode.server_identity * task_cancel_outcome
  | Verification_evidence_loaded of
      Masc_tui_types.verification_evidence_request * (Masc_tui_evidence_picture.evidence,
                Masc_tui_types.Verification_evidence_read.failure) result
  | Keeper_settings_editor_loaded of Masc_tui_types.keeper_settings_request *
      (Masc_tui_types.keeper_settings_snapshot, string) result
  | Keeper_config_view_loaded of Masc_tui_types.detail_read_request * (string list, string) result
  | Keeper_items_loaded of
      Masc_tui_types.detail_read_request * (string option * Masc_tui_keeper_items.t, string) result
  | Keeper_sandbox_view_loaded of
      Masc_tui_types.detail_read_request * (Masc_tui_keeper_sandbox.t, string) result
  | Keeper_sandbox_logs_loaded of
      string * int * (Masc_tui_keeper_sandbox.logs, string) result
  | Exact_activity_read of Masc_tui_exact_activity.request * (Masc_tui_exact_activity.document, string) result
  | Exact_activity_saved of Masc_tui_exact_activity.request * Masc_tui_exact_activity.write_result
  | Browser_activity_read of Masc_tui_browser_activity.request * (Masc_tui_browser_activity.document, string) result
  | Browser_activity_saved of Masc_tui_browser_activity.request * Masc_tui_browser_activity.write_result
  | Machine_activity_read of Masc_tui_machine_activity.request * (Masc_tui_machine_activity.reading, string) result
  | Machine_activity_saved of Masc_tui_machine_activity.request * Masc_tui_machine_activity.write_result
  | Runtime_config_view_loaded of
      int * string option * int64 * int64
      * (Masc_tui_runtime_config_snapshot.t, string) result
      (* Original read generation/model entry intent, request start and
         prepared-result clocks; neither clock proves UI paint. *)
  | Runtime_params_loaded of
      (Masc.Tui_decode.runtime_param_row list, string) result
  | Runtime_param_written of
      runtime_param_edit option * (string, string) result
  | Prompts_loaded of
      unit Masc_tui_fetched.request * (Masc.Tui_decode.prompts_snapshot, string) result
  | Keeper_board_quarantines_loaded of
      string Masc_tui_fetched.request
      * (Masc_tui_board_quarantine.t, string) result
  (* Keeper, partition, and what is known about the requeue's effect. *)
  | Board_quarantine_requeued of string * string * Masc_tui_http.post_outcome
  | Board_quarantines_bulk_progress of
      string * int * int * int * int * int
  | Board_quarantines_bulk_requeued of
      string * (string * Masc_tui_http.post_outcome) list
  (* Where a preset answer goes: the chat pane that typed the command, or
     the Config pane that pressed the key. *)
  | Presets_listed of preset_sink * (Masc.Tui_decode.presets_snapshot, string) result
  | Preset_detail_loaded of
      string Masc_tui_fetched.request * (Masc.Tui_decode.preset_detail, string) result
  (* The chat answer to [/preset show]. The pane's own detail rides on
     [Preset_detail_loaded] with a cursor key; this one has a sink because a
     typed command answers where it was typed. *)
  | Preset_contents_shown of preset_sink * (Masc.Tui_decode.preset_detail, string) result
  | Preset_saved of preset_sink * (Masc.Tui_decode.preset_manifest, string) result
  | Preset_restored of preset_sink * (Masc.Tui_decode.preset_restore_report, string) result
  | Preset_deleted of preset_sink * (string, string) result
  | Play_room_received of Masc_tui_play_room.request * (string * Masc.Play_room.snapshot, string) result
  | Play_invites_listed of play_list_sink * (Masc.Tui_decode.play_invite_row list, string) result
  | Play_invite_issued of Masc_tui_types.play_change_request * play_sink * Masc.Tui_decode.play_invite_issued play_mutation
  | Play_invite_revoked of Masc_tui_types.play_change_request * play_sink * string * play_revoke
  | Librarian_input_loaded of string * (string list, string) result
  | Artifact_checks_loaded of unit Masc_tui_fetched.request
      * (Masc_tui_artifact_checks.inventory, string) result
  | Artifact_check_changed of Masc_tui_artifact_check_action.request
      * (Masc.Published_artifact_check.t, string) result
  | Resources_listed of
      unit ref * (Masc_tui_resource_catalog.listing, string) result
  (* The scope travels with the directory. Without it a reply names a
     relative path, which two scopes can both have, and the handler had no
     way to tell a late answer for the scope just left from an answer for the
     scope now open (#33946). *)
  | Code_catalog_loaded of
      (code_workspace_scope * string) Masc_tui_fetched.request
      * (Masc.Tui_decode.workspace_file_catalog, string) result
  | Code_finder_file_loaded of
      (code_workspace_scope * string) Masc_tui_fetched.request
      * (Masc.Tui_decode.workspace_file_source, string) result
  | Code_entries_loaded of
      (code_workspace_scope * string) Masc_tui_fetched.request
      * (Masc.Tui_decode.workspace_tree_node list, string) result
  | Code_draft_saved of code_save_request * Masc_tui_code_draft.outcome
  | Code_file_loaded of code_file_load_intent * string Masc_tui_fetched.request * (Masc.Tui_decode.workspace_file_source, string) result
  | Code_history_loaded of
      (code_workspace_scope * string) Masc_tui_fetched.request
      * (Masc_tui_types.code_history_listing, string) result
  | Code_diff_loaded of
      string Masc_tui_fetched.request * (Masc.Tui_decode.git_diff, string) result
  (* The Activity pane's Changes tab: the selected keeper's recorded file
     changes, stamped with the request so an answer for a keeper the
     cursor has left is dropped. *)
  | Acting_pane_changes_loaded of
      string Masc_tui_fetched.request
      * (Masc.Tui_decode.file_change_snapshot, string) result
  (* The path the margin describes; stamped so a late answer cannot caption
     another file. *)
  | Code_blame_loaded of
      string Masc_tui_fetched.request
      * (Masc.Tui_decode.blame_block list, string) result
  (* The path the note anchored to; success re-reads the listing. *)
  (* (question, symbol, answer) — the note the pane shows names both. *)
  | Code_lsp_answered of
      Masc_tui_types.code_lsp_query Masc_tui_fetched.request
      * (Masc.Tui_decode.lsp_answer, string) result
  | Resource_read of
      Masc_tui_resource_catalog.read_request * (Masc_tui_resource_catalog.reading, string) result
  | Github_identity_view_loaded of Masc_tui_types.detail_read_request * (string list, string) result
  | Identity_providers_loaded of
      Masc_tui_types.detail_read_request * (Masc_tui_identity_model.identity_provider list, string) result
      * (identity_login_expectation * (Masc_tui_identity_model.identity_login_status, string) result) list
  | Identity_switch_set of
      string * string * bool * (unit, string) result
      (** keeper, provider, the state the operator asked for, and whether
          the server took it. *)
  | Identity_login_started of identity_login_request * Masc_tui_identity_model.identity_login_result
  | Identity_refreshed of string * (unit, string) result
  | Identity_app_saved of string option * string * (int, string) result
      (** presentation Keeper, provider id, then recorded scope count *)
  | Identity_disconnected of string * string * (Yojson.Safe.t, string) result
      (** keeper, provider, then the server's receipt: what was deleted, and
          separately how the provider's revoke went. *)
  | Account_login_event of Masc_tui_account_login.t * int * Masc_tui_account_login.event
  | Account_login_json of Masc_tui_account_login.t * int * Masc_tui_account_login.action * (Yojson.Safe.t, string) result
  (* A removal's answer keeps what is known about its effect: removed, declined
     by the server in its own words, or unknown. *)
  | Account_login_removal of Masc_tui_account_login.t * int * Masc_tui_account_login.provider * string option
      * Masc_tui_http.post_outcome
  | Github_login_lines of string * string list
  | Github_login_finished of string * (unit, string) result
  | Github_token_saved of string * (Yojson.Safe.t, string) result
  | Observer_opened of {
      session_id : string;
      handshake : (Sse_wire.observer_handshake option, string) result;
    }
  | Observer_received of string option * Masc_tui_observer.delivery list
  | Observer_closed of (unit, Masc_tui_http.observer_error) result
  | Original_task_read_done of Masc_tui_types.task_inspection_request
      * (Masc_tui_original_task_read.task_snapshot, Masc_tui_original_task_read.error) result
  | Original_task_history_done of Masc_tui_types.task_inspection_request
      * (Masc_tui_original_task_read.history_snapshot, Masc_tui_original_task_read.error) result
  | Original_task_evidence_done of Masc_tui_types.task_inspection_request
      * (Masc_tui_original_task_read.evidence_snapshot, Masc_tui_original_task_read.error) result
  | Task_dispatch_completed of Masc_tui_types.task_dispatch_request
  | Task_creation_read_done of Masc_tui_types.task_inspection_request
      * (Masc_tui_original_task_read.receipt, Masc_tui_original_task_read.error) result

(* Every async result carries the instant it was ready, so the loop can say
   how long it sat in the mailbox. A result that arrived in a second and was
   applied ten seconds later names the loop, not the request (RFC-0429
   §3.0). The instant is read off [Mtime_clock.elapsed_ns] so that a clock
   correction landing between the two reads cannot fabricate the wait or
   erase it. *)
type 'a mailed = {
  ready_at_ns : int64;
  message : 'a;
}

val capture_workspace_message : state -> (async_msg -> async_msg)
(** Capture the original workspace authority/read epoch now; envelope formation
    later never borrows a successor workspace. Operation projection/admission
    remains with the existing UI consumer. No enqueue or effect occurs here. *)

val ask_answer_completion_message :
  ask_submission -> Ask_answer_completion.observation -> async_msg
(** The outcome [collect_owned_results] mails for one finished Ask answer,
    scoped to the workspace authority and reading that sent it. *)

val collect_owned_results : state -> async_msg mailed list
(** Capture one finite observation of the pending owners. Newly published
    results belong to a later round; original receipts remain request-owned. *)

module Delivery_round : sig
  type 'a t
  val empty : 'a t
  (** Drain the captured shared FIFO prefix before collecting a finite set of
      owned results. A paused round retains that prefix or result remainder. *)
  val take : 'a t -> can_take:(unit -> bool) -> queued:(unit -> int) ->
    take_shared:(unit -> 'a option) -> collect_owned:(unit -> 'a list) ->
    'a option * 'a t
end

val workspace_message_is_read : async_msg -> bool
val workspace_message_admitted :
  state -> authority:workspace_authority -> reading:unit ref option -> async_msg -> bool
(** A stale read never re-enters a reconfirmed workspace. Admitted operation
    and chat receipts keep their original workspace authority. *)

val account_login_action_is_read : Masc_tui_account_login.action -> bool

val retired_operation_observation
  : state
  -> authority:workspace_authority
  -> reading:unit ref option
  -> async_msg
  -> Masc_tui_types.retired_operation_observation option
(** Capture a matching admitted effect's retired read before its receipt settles
    the operation owner. The caller applies the receipt before retaining or
    dispatching this observation; the effect itself is never repeated. *)

val project_workspace_operation_reply : state -> authority:workspace_authority -> reading:unit ref option -> async_msg -> async_msg
(** Preserve operation receipts while rejecting any separately fetched
    observation whose read epoch has retired, including queued completions. *)
