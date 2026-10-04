(** Async reply contracts shared by the TUI producers and result application.
    Request/generation identities and dispatch acknowledgements travel in the
    payload. Mutable UI state, enqueue clocks and fibers remain in the loop. *)

open Masc_tui_types

type approval_observation = {
  ao_ticket: Masc_tui_operator_projection.Listing_order.ticket;
  ao_result: (approval_snapshot, string) result;
}

type http_scoped_surface_results = {
  http_refresh_ticket: Http_refresh_order.ticket;
  http_scoped_server_identity: (Masc.Tui_decode.server_identity, string) result;
  http_transport: (Masc.Tui_decode.transport_health, string) result option;
  http_approvals: approval_observation option;
  (* [None] on surfaces that do not draw them. Each is read by one surface, and
     leaving it out keeps whatever that surface last observed rather than
     dropping it. *)
  http_asks: (Masc.Tui_decode_asks.asks_snapshot, string) result option;
  http_board: (board_post list, string) result option;
  (* The board's hearth census rides with its listing: the two are read for
     one surface and a cycle keyed on a census the listing has outgrown walks
     names that are no longer there. *)
  http_board_hearths: ((string * int) list, string) result option;
  http_planning: (planning_snapshot, string) result option;
  http_system_logs: (system_log_snapshot, string) result option;
  http_fleet_safety: (Masc.Tui_decode.fleet_safety_reading, string) result option;
  (* [None] on surfaces that do not read the roster or its Candle summary;
     leaving it out keeps the observation until a relevant refresh. *)
  http_keeper_roster:
    (Masc_tui_keeper_control.roster * (Candle_observation.t, string) result,
     Masc_tui_keeper_control.roster_failure) result option;
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
        approval_ticket : Masc_tui_operator_projection.Listing_order.ticket option }
  | Refresh_server_booting of
      { refresh_ticket : Http_refresh_order.ticket
      ; identity : (Masc.Tui_decode.server_identity, string) result
      ; (* The ticket [start_http_refresh] took before the probe went
           out. Carried so the approvals panel learns why its rows are stale,
           the same way a failed refresh tells it. *)
        approval_ticket : Masc_tui_operator_projection.Listing_order.ticket option
      }

type preset_sink =
  | Preset_to_chat of string option
  | Preset_to_pane

(* The UI domain owns these refs. A posted tick is a mutation: closing its
   view invalidates presentation, never cancels or retries the request. Keep
   the pending request until its terminal mailbox result, even across reopen. *)
type msx_poll_request = { poll_view : unit ref; poll_port : int }

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
  | Play_unanswered of string

type play_revoke =
  | Play_revoke_absent
  | Play_revoke_result of Masc.Tui_decode.play_invite_revoked play_mutation

type currency_authority_request = {
  car_generation : int;
  car_identity : Masc.Tui_decode.server_identity option;
}

type async_msg =
  | Workspace_scoped of workspace_authority * async_msg
  | Workspace_identity_unconfirmed of string
  | Lane_package_preview_loaded of int * string * (Yojson.Safe.t, string) result
  | Keeper_queue_loaded of string * int option * Masc_tui_queue_inspection.action * (string list, string) result
  | Lane_addons_loaded of int * (string * string) option * (lane_addons_reply, lane_addons_failure) result
  | Lane_subscriptions_loaded of int * (Masc_tui_lane_subscriptions.snapshot,string) result
  | Lane_declaration_loaded of int * Masc_tui_lane_declaration.request * bool
      * (Masc_tui_lane_declaration.response, string) result
  | Keeper_deletions_loaded of int * (Masc_tui_keeper_control.deletion_inventory, string) result
  | Msx_frame_loaded of msx_poll_request
      * (Masc_tui_types.msx_frame option * Masc_tui_machine_live.mark option, string) result
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
  | Voice_level of { keeper : string; db : float }
  | Voice_transcribed of { keeper : string; text : string }
  | Voice_silent of { keeper : string; reason : string }
  (* The operator abandoned a recording that had speech in it. Its own row
     rather than a silence: the microphone worked. *)
  | Voice_discarded of { keeper : string; reason : string }
  | Voice_failed of { keeper : string; error : string }
  | Http_refresh_done of http_refresh_outcome
  | Http_refresh_failed of
      string * Masc_tui_operator_projection.Listing_order.ticket option * Http_refresh_order.ticket
  | Surface_composer_released
  | Http_scoped_refresh_done of workspace_authority * currency_authority_request * http_scoped_surface_results
  | Http_scoped_refresh_failed of
      workspace_authority * string * Masc_tui_operator_projection.Listing_order.ticket option * Http_refresh_order.ticket
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
     -- which may be someone else's answer. The first field is the human
     confirmation label (the Keeper and what was chosen), built at submit time
     from the labels the operator saw rather than the ask's opaque id. *)
  | Ask_answer_done of
      string
      * (Yojson.Safe.t, string) result
      * (Masc.Tui_decode_asks.asks_snapshot, string) result
  | Keeper_chat_dispatch_started of
      Masc_tui_keeper_chat_projection.request * bool * bool Eio.Promise.u
  | Keeper_chat_done of
      Masc_tui_keeper_chat_projection.request
      * bool
      * (Masc_tui_keeper_chat_projection.response, Masc_tui_keeper_chat_projection.error) result
      * unit Eio.Promise.u
  | Keeper_chat_stream_deltas of
      Masc_tui_keeper_chat_projection.request * (int option * Masc_tui_keeper_chat_live.delta) list
  | Keeper_chat_stream_unavailable of Masc_tui_keeper_chat_projection.request * string
  | Keeper_run_next_done of Masc_tui_keeper_chat_projection.request * (string, string) result
  | Keeper_observed_interrupt_done of
      string * string * int * (Masc_tui_interrupt_signal.interrupt_signal, string) result
  | Keeper_chat_interrupt_done of
      Masc_tui_keeper_chat_projection.request * int * (Masc_tui_interrupt_signal.interrupt_signal, string) result
  | Keeper_chat_history_loaded of
      int
      * string
      * (Masc_tui_keeper_chat_history.decoded, string) result
      * (Masc_tui_keeper_chat_history.decoded, string) result
  | Keeper_chat_copy_loaded of
      int * string * (Masc_tui_keeper_chat_history.decoded, string) result
  | Keeper_chat_journal_loaded of
      { keeper_name : string
      ; operation_id : string
      ; started_at : float
      ; journal :
          ( Masc.Keeper_chat_event_log.journaled_event list
          , Masc_tui_keeper_chat_log.events_error )
          result
      }
  | Context_inspector_loaded of
      int * string * Masc_tui_context_inspector.reading
  | Keeper_chat_older_loaded of
      int * string * float * (Masc_tui_keeper_chat_history.page, string) result
  | Lanes_loaded of
      unit ref * ( Masc.Tui_decode.keeper_lanes_snapshot
        * Masc.Tui_decode.keeper_secret_projection list,
        string )
      result
  | Standalone_lanes_loaded of
      int * (Masc.Tui_decode.standalone_lanes_snapshot, string) result
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
  | Browser_lane_clients_loaded of int * (Browser_lane_view.client list, string) result
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
  | Connectors_loaded of unit ref * (Masc.Tui_decode_connectors.connector_snapshot, string) result
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
  | Tools_async_observation_loaded of int * (Masc.Tui_decode.async_request_observation, string) result
  | Runtime_lane_slots_written of
      Masc_tui_types.runtime_lane_list
      * (Masc_tui_types.slot_editor_target * Masc_tui_types.slot_editor_identity * Masc_tui_types.slot_editor_identity) option
      * (unit, string) result
  | Runtime_catalog_loaded of
      int * ( Masc.Tui_decode.runtime_option list
        * Masc.Tui_decode.runtime_resolved_lane list
        * Masc.Tui_decode.runtime_assignment list
        * string option,
        string )
      result
  | Runtime_assignment_set of
      string
      * string option
      * (Masc_tui_http.runtime_assignment_write_result, string) result
      (** keeper, the runtime it was pointed at ([None] = back to default),
          and whether the server took it. *)
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
      result : (string, string) result;
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
      (((string * string) list * Masc.Tui_decode.keeper_exact_lane_first list), string) result
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
  | Keeper_action_done of
      Masc.Tui_decode.server_identity option
      * string
      * Masc_tui_keeper_control.action
      * (Masc_tui_keeper_control.outcome, string) result
  | Board_new_post_done of {
      reply_to : string option;
      sent_draft : string;
      result : (string, string) result;
    }
  | Board_vote_done of (string, string) result
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
  | System_logs_loaded of (system_log_snapshot, string) result
  | Schedule_cancel_done of string * (string, string) result
  (* (message, noop): [noop = true] says the verdict already stood. *)
  | Verification_verdict_done of (string * bool, string) result
  | Harness_label_done of (string, string) result
  | Keeper_calls_loaded of
      int * string * (Masc.Tui_decode.keeper_calls_snapshot, string) result
  | Goal_timeline_loaded of
      string * (Masc.Tui_decode.goal_timeline, string) result
  | Task_history_loaded of
      string * (Masc.Tui_decode.task_history_event list, string) result
  | Task_cancel_done of string * Masc.Tui_decode.server_identity * (string, string) result
  | Verification_evidence_loaded of
      string * (Masc.Tui_decode.verification_evidence,
                Masc_tui_types.Verification_evidence_read.failure) result
  | Keeper_config_view_loaded of Masc_tui_types.detail_read_request * (string list, string) result
  | Keeper_items_loaded of
      Masc_tui_types.detail_read_request * (string option * Masc_tui_keeper_items.t, string) result
  | Keeper_sandbox_view_loaded of
      Masc_tui_types.detail_read_request * (Masc_tui_keeper_sandbox.t, string) result
  | Keeper_sandbox_logs_loaded of
      string * int * (Masc_tui_keeper_sandbox.logs, string) result
  | Runtime_config_view_loaded of
      int * string option
      * (string * string list * Masc_tui_runtime_config_view.metadata, string) result
      (* Read generation and captured runtime ID to edit; [None] is a source
         refresh without a model-settings entry request. *)
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
  | Play_invites_listed of string option * (Masc.Tui_decode.play_invite_row list, string) result
  | Play_invite_issued of string option * Masc.Tui_decode.play_invite_issued play_mutation
  | Play_invite_revoked of string option * string * play_revoke
  | Librarian_input_loaded of string * (string list, string) result
  | Resources_listed of (Masc_tui_mcp.resource list, string) result
  (* The scope travels with the directory. Without it a reply names a
     relative path, which two scopes can both have, and the handler had no
     way to tell a late answer for the scope just left from an answer for the
     scope now open (#33946). *)
  | Code_entries_loaded of
      (code_workspace_scope * string) Masc_tui_fetched.request
      * (Masc.Tui_decode.workspace_tree_node list, string) result
  | Code_file_loaded of string Masc_tui_fetched.request * (string, string) result
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
      string * (Masc_tui_mcp.resource_content list, string) result
  | Github_identity_view_loaded of Masc_tui_types.detail_read_request * (string list, string) result
  | Identity_providers_loaded of
      Masc_tui_types.detail_read_request * (Masc_tui_identity_model.identity_provider list, string) result
  | Identity_switch_set of
      string * string * bool * (unit, string) result
      (** keeper, provider, the state the operator asked for, and whether
          the server took it. *)
  | Identity_login_started of identity_login_request * Masc_tui_identity_model.identity_login_result
  | Identity_refreshed of string * (unit, string) result
  | Identity_app_saved of string option * string * (int, string) result
      (** presentation Keeper, provider id, then recorded scope count *)
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
  | Task_dispatched of {
      expected_workspace : Masc.Tui_decode.server_identity;
      keeper : string;
      task_id : string;
      title : string;
      body : string;
    }
  | Task_dispatch_failed of {
      keeper : string;
      detail : string;
      original : string;
    }

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
