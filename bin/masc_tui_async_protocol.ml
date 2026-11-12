(** Async reply contracts shared by the TUI producers and result application.
    Request/generation identities and dispatch acknowledgements travel in the
    payload. Mutable UI state, enqueue clocks and fibers remain in the loop. *)

open Masc_tui_types

type task_cancel_outcome =
  | Task_cancel_confirmed of string
  | Task_cancel_refused of string
  | Task_cancel_unconfirmed of string

type ask_followup_read = {
  afr_request : Snapshot_read.request;
  afr_submission : ask_submission;
  afr_origin : Masc_tui_observation_origin.t;
  afr_admission_started_ns : int64;
  afr_admission_capture : Masc_tui_observation_store.admission_capture option;
}
let capture_ask_followup_read ~origin ~request ~submission ~admission_started_ns ~admission_capture =
  {afr_request=request;afr_submission=submission;afr_admission_started_ns=admission_started_ns;
   afr_origin=origin;afr_admission_capture=admission_capture}

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

type early_approval_observation = {
  eap_ticket: Http_refresh_order.ticket;
  eap_authority: workspace_authority;
  eap_identity: Masc.Tui_decode.server_identity;
  eap_observation: approval_observation;
}

(* Each value settles one independently owned dataset. Board's two datasets
   share a logical source, while neither delivery consumes its sibling. *)

(* A provider history answer and the TUI clock when its request started. The
   next UTC day is counted from the start, so a request sent before midnight
   whose answer lands after it reads again at once. *)
type provider_history_reading = {
  phr_days : int;
  phr_requested_at : float;
  phr_result : (Masc.Tui_decode_usage.provider_usage_history, string) result;
}

(** A tool-call series answer cut to the buckets its period draws, and the
    period it was asked for. A reply to a period the operator has since left
    carries the old [tsl_days] and is dropped when it lands. *)
type tool_series_load = {
  tsl_days : int;
  tsl_result : (Masc_tui_usage_calls.t, string) result;
}

type http_dataset =
  | Dataset_transport of (Masc.Tui_decode.transport_health, string) result
  | Dataset_board_posts of board_posts_receipt
  | Dataset_board_hearths of ((string * int) list, string) result
  | Dataset_planning of (planning_snapshot, string) result
  | Dataset_runtime_quota of
      (Masc.Tui_decode.runtime_option list, string) result
      * (Masc.Tui_decode_usage.provider_usage_windows, string) result
  | Dataset_keeper_usage of (Masc.Tui_decode_usage.keeper_usage_window, string) result
  | Dataset_provider_history of provider_history_reading
  | Dataset_overview_goals of (Masc.Tui_decode.overview_goal list, string) result
  | Dataset_account_emails of ((string * string) list * int, string) result
  | Dataset_tool_series of tool_series_load

type early_http_dataset = {
  ed_ticket: Http_refresh_order.ticket;
  ed_authority: workspace_authority;
  ed_request: Surface_read_order.request;
  ed_identity: Masc.Tui_decode.server_identity;
  ed_dataset: http_dataset;
}

let http_dataset_key = function
  | Dataset_transport _ -> Surface_read_order.Transport_data
  | Dataset_board_posts _ -> Surface_read_order.Board_posts
  | Dataset_board_hearths _ -> Surface_read_order.Board_hearths
  | Dataset_planning _ -> Surface_read_order.Planning_data
  | Dataset_runtime_quota _ -> Surface_read_order.Runtime_quota_data
  | Dataset_keeper_usage _ -> Surface_read_order.Keeper_usage_data
  | Dataset_provider_history _ -> Surface_read_order.Provider_history_data
  | Dataset_overview_goals _ -> Surface_read_order.Overview_goals_data
  | Dataset_account_emails _ -> Surface_read_order.Account_emails_data
  | Dataset_tool_series _ -> Surface_read_order.Tool_series_data

let http_dataset_received = function
  | Dataset_transport result -> Result.is_ok result
  | Dataset_board_posts receipt -> Result.is_ok receipt.bpr_result
  | Dataset_board_hearths result -> Result.is_ok result
  | Dataset_planning result -> Result.is_ok result
  | Dataset_runtime_quota (runtimes, quota) -> Result.is_ok runtimes && Result.is_ok quota
  | Dataset_keeper_usage result -> Result.is_ok result
  | Dataset_provider_history reading -> Result.is_ok reading.phr_result
  | Dataset_overview_goals result -> Result.is_ok result
  | Dataset_account_emails result -> Result.is_ok result
  | Dataset_tool_series load -> Result.is_ok load.tsl_result

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
  http_provider_history: provider_history_reading option;
  (* [None] off Work, the one surface that reads the Goal measurement tree. *)
  http_overview_goals: (Masc.Tui_decode.overview_goal list, string) result option;
  (* [None] off Usage, the surface that draws account emails. *)
  http_account_emails: ((string * string) list * int, string) result option;
  (* [None] off Usage's Calls section, the one that draws the tool-call series. *)
  http_tool_series: tool_series_load option;
}

type http_scoped_surface_results =
  (Masc.Tui_decode.server_identity, string) result http_scoped_surface_readings

type http_surface_results = {
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

type board_attachment_action_result =
  | Board_saved_original of string
  | Board_image_open_ready of unit ref * Masc_tui_attachment_action.prepared
  | Board_image_open_failed of unit ref * string
  | Board_image_open_finished of unit ref * string
  | Board_image_open_retry of {attempt : unit ref; prepared : Masc_tui_attachment_action.prepared; opener : string}

type image_preparation =
  | Image_worker_busy
  | Image_prepared of (Masc_tui_image_cache.presentation * Masc_tui_pele.scene option, string) result

type observer_recovery_origin =
  | Observer_existing_workspace of Masc.Tui_decode.server_identity
  | Observer_initial_workspace of local_workspace_paths

(* The Tools screen's reads, one constructor for all of them: [async_msg]
   is at OCaml's limit of non-constant constructors. *)
type tools_read =
  | Tools_inventory_loaded of
      { generation : int
      ; keeper : string option
      ; result : (Masc.Tui_decode_tools.tool_snapshot, string) result
      }
  | Tools_catalog_loaded of
      { generation : int
      ; result : (Masc.Tui_decode_tools.skills_catalog, string) result
      }
  | Tools_activations_loaded of
      { generation : int
      ; keeper : string
      ; result : (Masc.Tui_decode_tools.skill_activation_projection, string) result
      }
  | Tools_usage_loaded of
      { generation : int
      ; keeper : string
      ; result : (Masc.Tui_decode_tools.keeper_skill_usage, string) result
      }

(* What a memory health read answered: the fleet, or one Keeper's row
   (RFC-0487). *)
type memory_health_read =
  | Fleet_health_read of (Masc.Tui_decode_memory_health.memory_health_snapshot, string) result
  | Row_health_read of
      { keeper : string
      ; result : (Masc.Tui_decode_memory_health.memory_health_row_answer, string) result
      }
  | Command_health_read of
      { keeper : string
      ; result : (Masc.Tui_decode_memory_health.memory_health_row_answer, string) result
      }

(* The answers of one domain share one type named after it, and [async_msg]
   carries that type in one constructor: [keeper_msg] in [Keeper_msg]. A
   domain whose module applies its own answers declares the type there, as
   [Code_msg] carries [Masc_tui_code_results.msg]. One variant takes at most
   244 constructors with arguments (#48617). A domain with a single answer
   keeps it in [async_msg], and so does a constructor that carries another
   [async_msg]. *)

type keeper_msg =
  | Keeper_queue_resume_confirmed of string * int * resume_confirmation * string list
  | Keeper_queue_action_received of string * string list
  | Keeper_queue_loaded of string * int option * Masc_tui_queue_inspection.action * (string list * (Masc_tui_queue_inspection.observation, string) result, string) result
  | Keeper_deletions_loaded of int * (Masc_tui_keeper_control.deletion_inventory, string) result
  | Keeper_deletion_retry_done of string * (unit, string) result
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
  | Keeper_chat_older_loaded of
      int * string * string option * (Masc_tui_keeper_chat_history.page, Masc_tui_keeper_chat_history.page_error) result
  | Keeper_composite_loaded of
      unit ref * string
      * ( Masc.Tui_decode.keeper_lane * Masc.Tui_decode.keeper_secret_projection option,
          string )
        result
  | Keeper_chat_file_changes_loaded of
      int * string * (Masc.Tui_decode.file_change_snapshot, string) result
      (** Generation and keeper-stamped answer for the chat-only cache. The
          Changes surface owns [File_changes_loaded] and is never populated by
          this response. *)
  | Keeper_chat_approval_answered of
      Masc_tui_keeper_chat_projection.request
      * string
      * bool
      * (Masc_tui_http.tool_approval_answer, string) result
  | Keeper_tool_approvals_loaded of
      Snapshot_read.request * Masc.Tui_decode.server_identity * (Masc.Tui_decode.keeper_tool_approval list, string) result
  | Keeper_tool_approval_answered of
      string
      * string
      * string
      * bool
      * (Masc_tui_http.tool_approval_answer, string) result
      * Masc_tui_operator_projection.Flow.generation
      (** keeper, tool call id, approval id, allow, what the server did with
          the answer, and the generation of the Approvals action slot the
          decision took. The Approvals-surface twin of
          [Keeper_chat_approval_answered], which needs the chat request this
          path does not have. *)
  | Keeper_roster_reloaded of keeper_roster_observation
  | Keeper_row_reloaded of keeper_row_observation
  | Keeper_turns_loaded of (string * int) list * keeper_waiting_snapshot * (int * int) option
      * (Masc.Tui_decode.keeper_turns_projection, string) result
  | Keeper_waiting_loaded of Keeper_waiting_read.request * keeper_waiting_snapshot
      * (Masc.Tui_decode.keeper_turns_projection, string) result
  | Keeper_chat_control_received of string * int * string
      (** Which keepers are mid-turn right now, for the "answering now"
          badge drawn from every surface. *)
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
  | Keeper_composer_released
  | Keeper_chat_dispatch_blocked of Masc_tui_keeper_chat_projection.request * string
  | Keeper_logs_loaded of keeper_log_request * (Masc_tui_metrics_tail.snapshot, string) result
  | Keeper_execute_streamed of keeper_execute_follow * keeper_execute_follow_event
  | Keeper_settings_save_changed of keeper_settings_save_request * keeper_settings_save_status * int64
  | Keeper_creation_changed of keeper_creation_request * keeper_creation_status
  | Keeper_memory_catch_up_done of
      { keeper : string
      ; workspace : Masc.Tui_decode.server_identity
      ; authority : workspace_authority
      ; outcome : Masc_tui_http.keeper_memory_catch_up_outcome
      }
  | Keeper_action_done of
      Masc.Tui_decode.server_identity option
      * string
      * Masc_tui_keeper_control.action
      * (Masc_tui_keeper_control.outcome, string) result
  (* Carries the keeper it was asked about: the roster cursor can move while a
     load is in flight, and an answer that did not say whose it was would be
     filed under whoever is selected when it lands. *)
  | Keeper_schedules_loaded of keeper_schedule_page_request * (schedule_snapshot, string) result
  (* The newest turns of the Keeper the Story window draws. The request names
     the Keeper: an answer for one the cursor has left is dropped. *)
  | Keeper_story_turns_loaded of
      string Masc_tui_fetched.request * (Masc_tui_keeper_turns.turn list, string) result
  | Keeper_memory_activity_loaded of string Masc_tui_fetched.request
      * (Masc.Keeper_memory_activity.t, string) result
  | Keeper_calls_loaded of
      int * string * (Masc.Tui_decode.keeper_calls_snapshot, string) result
  | Keeper_settings_editor_loaded of Masc_tui_types.keeper_settings_request *
      (Masc_tui_types.keeper_settings_snapshot, string) result
  | Keeper_config_view_loaded of Masc_tui_types.detail_read_request * (string list, string) result
  | Keeper_items_loaded of
      Masc_tui_types.detail_read_request * (string option * Masc_tui_keeper_items.t, string) result
  | Keeper_sandbox_view_loaded of
      Masc_tui_types.detail_read_request * Masc_tui_keeper_sandbox.load_result
  | Keeper_sandbox_logs_loaded of
      string * int * (Masc_tui_keeper_sandbox.logs, string) result
  | Keeper_board_quarantines_loaded of
      string Masc_tui_fetched.request
      * (Masc_tui_board_quarantine.t, string) result
  | Keeper_efficiency_loaded of
      string Masc_tui_fetched.request
      * (Masc.Tui_decode_keeper_efficiency.month_view, string) result

type chat_msg =
  | Chat_search_finished of int * bool * Masc_tui_render_chat.chat_search_plan
      * (Masc_tui_render_chat.chat_search_work * Masc_tui_render_chat.chat_search_match, string) result
  | Chat_call_loaded of chat_call_request * (Masc.Tui_decode.keeper_call, string) result

type workspace_msg =
  | Workspace_identity_unconfirmed of
      { detail : string
      ; latest : (Masc.Tui_decode.server_identity, string) result
        (* The identity the refusing probe read; it may name a workspace. *)
      ; prior_contact : Masc_tui_server_lifecycle.contact
      ; refresh_ticket : Http_refresh_order.ticket }
  | Workspace_activity_loaded of string Masc_tui_fetched.request * (workspace_activity_read, string) result

type schedule_msg =
  | Schedule_form_authority_refused of
      { action : string; detail : string; workspace : workspace_input_identity option }
  | Schedules_loaded of schedule_page_request * (schedule_snapshot, string) result
  (* Carries the schedule it was asked about: the reader can step to the next
     row or close the detail while a load is in flight, and an answer that did
     not say whose it was would be filed under whoever is open when it lands. *)
  | Schedule_wake_history_loaded of
      string * (schedule_wake_history, string) result
  | Schedule_cancel_done of string * (string, string) result

type lane_msg =
  | Lane_package_catalog_loaded of int * string option * (Yojson.Safe.t, string) result
  | Lane_package_preview_loaded of int * string * (Yojson.Safe.t, string) result
  | Lane_addons_loaded of int * Masc_tui_lane_addons.read_target * (lane_addons_reply, lane_addons_failure) result
  | Lane_application_loaded of Masc_tui_lane_application.ticket
      * (Masc_tui_lane_addons.configuration, string) result
  | Lane_subscriptions_loaded of int * (Masc_tui_lane_subscriptions.snapshot,string) result
  | Lane_declaration_loaded of int * Masc_tui_lane_declaration.request * bool * string option
      * (Masc_tui_lane_declaration.response, string) result
  | Lane_inventory_loaded of
      int * (Masc.Tui_decode_lane_inventory.snapshot, string) result
  (* Keyed by the lane / run they answer for: an answer that lands after the
     operator left the list or the run is not this view's answer. *)
  | Lane_runs_loaded of
      Lane_run_identity.t * int * (float * string) option *
      (Masc.Tui_decode.lane_run_page, string) result
  | Lane_run_detail_loaded of
      string * int * (Masc.Tui_decode.lane_run_detail, string) result

type msx_msg =
  | Msx_tick_withdrawn of msx_poll_request * string
  | Msx_frame_loaded of msx_poll_request
      * (Masc_tui_msx_tick.response, string) result
  | Msx_activity_loaded of msx_poll_request
      * (Masc_tui_msx_tick.activity * (Masc_tui_machine_live.answer * Masc_tui_machine_live.activity, string) result, string) result
  | Msx_live_loaded of machine_live_request
      * (Masc_tui_machine_live.answer * Masc_tui_machine_live.activity, string) result

type voice_msg =
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

type http_msg =
  (** Verified questions may settle their own read before the full bundle. *)
  | Http_asks_loaded of early_asks_observation
  | Http_approvals_loaded of early_approval_observation
  | Http_keeper_roster_loaded of early_keeper_roster_observation
  | Http_dataset_loaded of early_http_dataset
  | Http_initial_identity_read of http_initial_identity_read
  | Http_refresh_done of http_refresh_outcome
  | Http_refresh_failed of
      string * Masc_tui_operator_projection.Listing_order.ticket option * Http_refresh_order.ticket
  | Http_scoped_refresh_done of workspace_authority * currency_authority_request * http_scoped_surface_results
  | Http_scoped_refresh_failed of
      workspace_authority * string * Masc_tui_operator_projection.Listing_order.ticket option * Http_refresh_order.ticket
      * (Masc.Tui_decode.server_identity, string) result option
        (* The last identity its probes read, if any. *)
      * Surface_read_order.request

type ask_msg =
  | Ask_answer_receipt_ready of ask_submission
  | Ask_followup_observed of ask_followup_read * Masc.Tui_decode_asks.ask_followup_event * int64
  | Ask_followup_finished of ask_followup_read * Masc_tui_ask_projection.followup_result
  (* The answer that came back, and the list re-read behind it. The store
     settles on first write, so the response says what was actually recorded
     -- which may be someone else's answer. The submission carries the original
     workspace, asker, Ask and human label; none is recovered from prose. *)
  | Ask_answer_done of
      ask_submission
      * (Masc.Tui_decode_asks.answer_receipt, string) result
      * (Masc.Tui_decode_asks.asks_snapshot, string) result
  | Asks_reloaded of asks_observation

type approvals_msg =
  (* The confirm-queue read that rode a refresh was refused because the same
     pass confirmed the workspace identity first ([Approval.Flow.invalidate]
     runs inside [apply_server_identity_reading]). The surface that draws the
     count re-reads it now, on the same ticket-generation terms every other
     approval listing rides. *)
  | Approvals_listing_superseded
  | Approvals_summary_loaded of
      Masc_tui_types.Snapshot_read.request
      * Masc_tui_operator_projection.Listing_order.ticket
      * Masc.Tui_decode.server_identity
      * (approval_snapshot, string) result
  | Approval_decision_done of
      approval_item
      * approval_decision
      * (Masc_tui_operator_projection.confirm_outcome, string) result
      * Masc_tui_operator_projection.Flow.generation
      * (approval_snapshot, string) result

type board_msg =
  | Board_post_refresh_done of
      Masc_tui_board_detail.request * (board_post * board_comment list * string option, string) result
  | Board_publication_done of workspace_authority Masc_tui_board_publication.outcome
  | Board_comment_done of {
      request_id : board_comment_request_id;
      post_id : string;
      sent_draft : string;
      result : (string, string) result;
    }
  | Board_vote_done of board_vote_target * (string, string) result
  | Board_attachment_loaded of Masc_tui_board_reader.request * (Masc_tui_board_reader.content, string) result
  | Board_attachment_prepared of Masc_tui_board_reader.preparation_request * (Masc_tui_detail_reading.row list, string) result
  | Board_attachment_saved of Masc_tui_board_reader.request * (board_attachment_action_result, string) result
  (* Keeper, partition, and what is known about the requeue's effect. *)
  | Board_quarantine_requeued of string * string * Masc_tui_http.post_outcome
  | Board_quarantines_bulk_progress of
      string * int * int * int * int * int
  | Board_quarantines_bulk_requeued of
      string * (string * Masc_tui_http.post_outcome) list

type local_msg =
  | Local_keepers_read of local_workspace_request * (Masc_tui_loader.local_keeper_reading, string) result
  | Local_workspace_read of local_workspace_request * (Masc_tui_loader.local_reading, string) result
      (** Optional work/agent observation. Required metadata has its own typed reply. *)

type verification_msg =
  | Verification_loaded of (Masc.Tui_decode.verification_snapshot, string) result
  (* (message, noop): [noop = true] says the verdict already stood. *)
  | Verification_verdict_done of (string * bool, string) result
  | Verification_evidence_exported of Masc_tui_types.verification_export_request * (string, string) result
  | Verification_evidence_loaded of
      Masc_tui_types.verification_evidence_request * (Masc_tui_evidence_picture.evidence,
                Masc_tui_types.Verification_evidence_read.failure) result

type harness_msg =
  | Harness_loaded of (Masc.Tui_decode.harness_snapshot, string) result
  | Harness_label_done of (string, string) result

type fusion_msg =
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

type memory_msg =
  (* Carries the generation of the form that asked: the answer to a read the
     operator already left must not land on another form. *)
  | Memory_recall_standing_loaded of
      int * (Masc.Tui_decode_memory_recall.memory_recall_reading, string) result
  | Memory_loaded of memory_health_read
  | Memory_input_loaded of string Masc_tui_fetched.request
      * (Masc_tui_memory_usage.t, string) result
  (* The Memory screen's world read. It carries the request it answers: the
     workspace can change while the read is in flight, and a late answer for
     the old one must be dropped, not drawn as the new one's. *)
  | Memory_world_loaded of
      unit Masc_tui_fetched.request
      * (Masc.Tui_decode_workspace_memory.inventory, string) result
  (* Carries the request it answers: the browser can be closed or pointed at
     another keeper while a load is in flight, and a late answer for somebody
     else must be dropped, not filed under whoever is open. The answer is the
     facts and, for the "all keepers" merge, the keepers it could not read. *)
  | Memory_facts_loaded of
      string Masc_tui_fetched.request
      * (Masc.Tui_decode_memory_facts.memory_fact_snapshot * string option, string) result

type repository_msg =
  | Repositories_loaded of (Masc.Tui_decode.repository_snapshot, string) result
  | Repository_changes_loaded of
      Masc.Tui_decode.repository_change_scope
      * (Masc.Tui_decode.repository_change_snapshot, string) result
  | Repository_changes_diff_loaded of
      repository_diff_request * (Masc.Tui_decode.git_diff, string) result

type browser_msg =
  | Browser_history_list_loaded of int * (Masc.Tui_decode.keeper_calls_snapshot, string) result
  | Browser_history_page_loaded of int * (Masc.Browser_observation.t, string) result
  | Browser_lane_clients_loaded of int * (Browser_lane_view.discovered, string) result
  | Browser_lane_loaded of
      int * (Browser_lane_view.reading, string) result
  | Browser_lane_scene_loaded of int * (Browser_lane_view.scene, string) result
  | Browser_lane_follow_loaded of int *
      ((Masc_tui_http.browser_follow_receipt *
        (Browser_lane_view.scene, string) result), string) result
  | Browser_lane_screenshot_ready of {
      generation : int; image_generation : int;
      result : (Browser_lane_view.screenshot * string, string) result;
    }

type connectors_msg =
  | Connectors_status_loaded of Connector_read.request * Masc.Tui_decode_connectors.connector_snapshot
  | Connectors_loaded of Connector_read.request * (Masc.Tui_decode_connectors.connector_snapshot, string) result
  | Connector_unbind_all_done of {
      keeper_name : string;
      results :
        (Masc_tui_connector_unbind.target * Masc_tui_connector_unbind.outcome)
        list;
    }

type runtime_msg =
  | Runtime_surface_loaded of
      int * (Masc_tui_loader.runtime_surface_load, string) result
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
  | Runtime_form_save_changed of runtime_form_save_request * runtime_form_save_status * int64
  | Runtime_config_view_loaded of
      int * string option * int64 * int64
      * (Masc_tui_runtime_config_snapshot.t, string) result
      (* Original read generation/model entry intent, request start and
         prepared-result clocks; neither clock proves UI paint. *)
  | Runtime_params_loaded of
      (Masc.Tui_decode.runtime_param_row list, string) result
  | Runtime_param_written of
      runtime_param_edit option * (string, string) result

type tools_msg =
  | Tools_read_loaded of tools_read
  | Tools_async_observation_loaded of int * (Masc.Tui_decode.async_request_observation, string) result
  | Tools_async_detail_loaded of Masc_tui_types.tools_async_detail_request * (Masc.Tui_decode_async_request.reading, string) result
  | Tools_async_task_body_loaded of Masc_tui_types.tools_async_task_request * (Masc.Tui_decode_task_inspection.detail, string) result
  | Tools_async_task_history_loaded of Masc_tui_types.tools_async_task_source Masc_tui_types.task_history_request * (Masc.Tui_decode_task_inspection.history, string) result
  | Tools_volume_gc_reported of (Masc_tui_volume_gc.answer, string) result
  | Tools_volume_gc_reclaimed of string list * (Masc_tui_volume_gc.answer, string) result

type task_msg =
  | Task_document_prepared of Masc_tui_types.task_document_request * (string list, string) result
  | Task_history_loaded of
      string Masc_tui_types.task_history_request * (Masc.Tui_decode_task_inspection.history, string) result
  | Task_cancel_done of string * Masc.Tui_decode.server_identity * task_cancel_outcome
  | Task_dispatch_completed of Masc_tui_types.task_dispatch_request
  | Task_creation_read_done of Masc_tui_types.task_inspection_request
      * (Masc_tui_original_task_read.receipt, Masc_tui_original_task_read.error) result

type resource_msg =
  | Resource_diagram_ready of Masc_tui_resource_diagrams.request * string * Masc_tui_resource_diagrams.claim * (string, string) result
  | Resources_listed of
      unit ref * (Masc_tui_resource_catalog.listing, string) result
  | Resource_exported of string * (string, string) result
  | Resource_saved of Masc_tui_types.resource_save_request * Masc_tui_types.resource_save_outcome
  | Resource_share_changed of Masc_tui_types.resource_share_request * (Masc_tui_types.resource_share_outcome, Masc_tui_types.resource_share_failure) result
  | Resource_share_recovery_loaded of Masc_tui_types.resource_share_recovery_lookup * (Masc_tui_artifact_share_pending.entry option, string) result
  | Resource_read of
      Masc_tui_resource_catalog.read_request * (Masc_tui_resource_catalog.reading, string) result
      * Masc_tui_types.resource_share_journal_observation

type gate_msg =
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

type goal_msg =
  | Goal_transition_done of string * string * string * (string, string) result
  | Goal_confirmation_submitted of string * string * string * Masc_tui_planning_detail.receipt_authority * (string, string) result
  | Goal_confirmation_loaded of
      string Masc_tui_fetched.request * (Masc_tui_planning_detail.confirmation, Masc_tui_planning_detail.confirmation_read_error) result
  | Goal_timeline_loaded of
      string Masc_tui_fetched.request * (Masc.Tui_decode.goal_timeline, string) result
  | Goal_candle_loaded of
      string Masc_tui_fetched.request * (unit ref * (string * Candle_goal_observation.t, Masc_tui_types.goal_candle_failure) result, string) result

type exact_msg =
  | Exact_activity_read of Masc_tui_exact_activity.request * (Masc_tui_exact_activity.document, string) result
  | Exact_activity_saved of Masc_tui_exact_activity.request * Masc_tui_exact_activity.write_result

type machine_msg =
  | Machine_activity_read of Masc_tui_machine_activity.request * (Masc_tui_machine_activity.reading, string) result
  | Machine_activity_saved of Masc_tui_machine_activity.request * Masc_tui_machine_activity.write_result

type preset_msg =
  (* Where a preset answer goes: the chat pane that typed the command, or
     the Config pane that pressed the key. *)
  | Presets_listed of preset_sink * (Masc.Tui_decode.presets_snapshot, string) result
  | Preset_detail_loaded of
      string Masc_tui_fetched.request * (Masc.Tui_decode.preset_detail, string) result
  (* The chat answer to [/preset show]. The pane's own detail rides on
     [Preset_detail_loaded] with a cursor key; this one has a sink because a
     typed command answers where it was typed. *)
  | Preset_contents_shown of preset_sink * (Masc.Tui_decode.preset_detail, string) result
  | Preset_saved of preset_save_pending
      * (Masc.Tui_decode.preset_manifest, preset_save_failure) result
  | Preset_restored of preset_sink * (Masc.Tui_decode.preset_restore_report, string) result
  | Preset_deleted of preset_sink * (string, string) result

type play_msg =
  | Play_room_received of Masc_tui_play_room.request * (string * Masc.Play_room.snapshot, string) result
  | Play_invites_listed of play_list_sink * (Masc.Tui_decode.play_invites, string) result
  | Play_invite_issued of Masc_tui_types.play_change_request * play_sink * Masc.Tui_decode.play_invite_issued play_mutation
  | Play_invite_revoked of Masc_tui_types.play_change_request * play_sink * string * play_revoke

type artifact_msg =
  | Artifact_checks_loaded of unit Masc_tui_fetched.request
      * (Masc_tui_artifact_checks.inventory, string) result
  | Artifact_check_changed of Masc_tui_artifact_check_action.request
      * (Masc.Published_artifact_check.t, string) result

type github_msg =
  | Github_identity_view_loaded of Masc_tui_types.detail_read_request * (string list, string) result
  | Github_login_lines of string * string list
  | Github_login_finished of string * (unit, string) result
  | Github_token_saved of string * (Yojson.Safe.t, string) result

type identity_msg =
  | Identity_providers_loaded of
      Masc_tui_types.detail_read_request
      * ( Masc_tui_identity_model.identity_provider list
          * Masc_tui_identity_model.identity_callback option
        , string )
        result
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

type account_msg =
  | Account_login_event of Masc_tui_account_login.t * int * Masc_tui_account_login.event
  | Account_login_json of Masc_tui_account_login.t * int * Masc_tui_account_login.action * (Yojson.Safe.t, string) result
  (* A removal's answer keeps what is known about its effect: removed, declined
     by the server in its own words, or unknown. *)
  | Account_login_removal of Masc_tui_account_login.t * int * Masc_tui_account_login.provider * string option
      * Masc_tui_http.post_outcome

type observer_msg =
  | Observer_session_ready of string
  | Observer_opened of unit ref * string * Sse_wire.observer_handshake option
  | Observer_received of unit ref * (string option * Masc_tui_observer.delivery list)
  | Observer_closed of unit ref * Masc_tui_types.workspace_input_identity * (unit, Masc_tui_http.observer_error) result
  | Observer_retry_due of workspace_authority * unit ref
  | Observer_recovery_ready of workspace_authority * unit ref * string option
  | Observer_recovery_identity of workspace_authority * unit ref * bool ref * string * string
      * observer_recovery_origin * Sse_wire.observer_identity

type async_msg =
  | Chat_msg of chat_msg
  | Workspace_scoped of workspace_authority * unit ref option * async_msg
  | Workspace_operation of async_msg
  | Chat_command_read_completed of unit ref * async_msg
  | Workspace_msg of workspace_msg
  | Schedule_msg of schedule_msg
  | Lane_msg of lane_msg
  | Keeper_msg of keeper_msg
  | Msx_msg of msx_msg
  | Dos_live_loaded of machine_live_request
      * (Masc_tui_machine_live.answer * Masc_tui_machine_live.activity, string) result
  | Voice_msg of voice_msg
  | Http_msg of http_msg
  | Ask_msg of ask_msg
  | Http_surface_read_completed of Surface_read_context.t * async_msg
  | Approvals_msg of approvals_msg
  | Board_msg of board_msg
  | Context_msg of Masc_tui_context_results.msg
  | Live_context_loaded of Masc_tui_context_state.request * int64
      * (Masc.Tui_decode.context_observation, string) result
  | Local_msg of local_msg
  | Clients_loaded of
      int * (Masc.Tui_decode.clients_snapshot, string) result
  | Measurement_artifact_loaded of
      string * int * (Measurement.t, string) result
  | Verification_msg of verification_msg
  | Harness_msg of harness_msg
  | Overview_loaded of (overview_snapshot, string) result
  | Fusion_msg of fusion_msg
  | Memory_msg of memory_msg
  | Repository_msg of repository_msg
  (* Carries the keeper it was asked about. The surface can be pointed at a
     different keeper while a load is in flight, and an answer that did not
     say whose it was would be filed under whoever is selected when it
     lands. *)
  | File_changes_loaded of
      string * (Masc.Tui_decode.file_change_snapshot, string) result
  (* Keyed by the path it answers for, for the same reason the file-change
     message carries a keeper: an answer for a file the operator has since
     left is not this view's answer. *)
  | Git_diff_loaded of string * (Masc.Tui_decode.git_diff, string) result
  | Browser_msg of browser_msg
  | Connectors_msg of connectors_msg
  | Runtime_msg of runtime_msg
  | Tools_msg of tools_msg
  | Skill_evidence_loaded of unit ref * string * (Yojson.Safe.t, string) result
  | Task_msg of task_msg
  | Listen_prepared of listen_request * (Masc_tui_attachment_action.prepared, string) result
  | Resource_msg of resource_msg
  | Sent_image_ready of {
      request : sent_image_read;
      result : image_preparation;
    }
  | Image_render_ready of {
      request : sent_image_read;
      title : string;
      caption : string list;
      page_url : string;
      image_url : string;
      result : (Masc_tui_image_cache.remote_image, string) result;
    }
      (** A [v]-requested or /image-requested web image, downloaded and
          converted to PNG off the render loop. [request] is the exact pending
          image owner captured before dispatch; a superseded or dismissed
          request cannot paint, notify another pane, or open its fallback.
          An explicit remote URL belongs to its workspace, independently of
          unrelated peer resource readings.
          [result] holds the prepared PNG or character frame, or why it could
          not be produced. [title] is what
          the screen shows: [v] indents a display title, /image passes the URL
          itself. [image_url] is what was fetched; [page_url] is the link the
          operator chose, and the one a browser gets when drawing fails
          (see [Masc_tui_browser.browser_url]). *)
  | Gate_msg of gate_msg
  | Goal_msg of goal_msg
  | System_log_streamed of system_log_follow * system_log_follow_event
  | Exact_msg of exact_msg
  | Machine_msg of machine_msg
  | Prompts_loaded of
      unit Masc_tui_fetched.request * (Masc.Tui_decode.prompts_snapshot, string) result
  | Preset_msg of preset_msg
  | Play_msg of play_msg
  | Librarian_input_loaded of string * (string list, string) result
  | Artifact_msg of artifact_msg
  | Code_msg of Masc_tui_code_results.msg
  (* The Activity pane's Changes tab: the selected keeper's recorded file
     changes, stamped with the request so an answer for a keeper the
     cursor has left is dropped. *)
  | Acting_pane_changes_loaded of
      Masc_tui_types.acting_pane_key Masc_tui_fetched.request
      * (Masc.Tui_decode.file_change_snapshot, string) result
  | Github_msg of github_msg
  | Identity_msg of identity_msg
  | Account_msg of account_msg
  | Observer_msg of observer_msg
  | Fleet_msg of Masc_tui_fleet_results.msg
  | Original_msg of Masc_tui_original_results.msg

(* Every async result carries the instant it was ready, so the loop can say
   how long it awaited UI application, whether queued or request-owned.
   A result that arrived in a second and was
   applied ten seconds later names the loop, not the request (RFC-0429
   §3.0). The instant is read off [Mtime_clock.elapsed_ns] so that a clock
   correction landing between the two reads cannot fabricate the wait or
   erase it. *)
type 'a mailed = {
  ready_at_ns : int64;
  message : 'a;
}

let capture_workspace_message state =
  let authority = state.workspace_authority in
  let reading = if server_authority_ready state then Some state.workspace_read_authority else None in
  fun message -> Workspace_scoped (authority,reading,message)

(* Snapshot authority is withdrawn independently of admitted effects. Keep
   this match exhaustive: a new reply must choose whether it is a replaceable
   observation or the outcome of an operation already sent. *)
let account_login_action_is_read = function
  | Masc_tui_account_login.Inventory | Refresh_saved _ | Refresh_retry | Recover | Discover | Preview_removal _
  | Refresh_removed _ | Refresh_list _ -> true
  | Activate_saved _ | Select_existing _ | Start _ | Input _
  | Cancel | Prepare _ | Save _ | Close | Nothing | Remove _ -> false

let ask_answer_completion_message (submission : ask_submission)
    (completion : Ask_answer_completion.observation) =
  Workspace_scoped (submission.as_authority, submission.as_reading,
    Ask_msg (Ask_answer_done (submission, completion.receipt, completion.asks)))

(* One finite observation of the actual pending owners, not a live priority
   scan after each application. New publications belong to a later round.
   Reserve final Ask transport offers here; their raw facts stay in history. *)
let collect_owned_results state =
  let history = match state.msg_history_inflight with
    | None -> []
    | Some request ->
        let scoped message = Workspace_scoped (Keeper_history_read.authority request,
          Some (Keeper_history_read.reading request), message) in
        let rows = List.map (fun (source, (observation : Keeper_history_read.observation)) ->
          {ready_at_ns=observation.ready_at_ns;
           message=scoped (Keeper_msg (Keeper_chat_history_loaded (request, source, observation.result)))})
          (Keeper_history_read.take_ready request) in
        let page = Option.to_list (Option.map
          (fun (observation : Keeper_history_read.page_observation) ->
            {ready_at_ns=observation.ready_at_ns;
             message=scoped (Keeper_msg (Keeper_chat_first_page_loaded (request, observation.result)))})
          (Keeper_history_read.take_page_ready request)) in
        rows @ page in
  let receipts = List.map (fun (submission, (observation : Ask_answer_receipt.observation)) ->
    {ready_at_ns=observation.observed_ns; message=Ask_msg (Ask_answer_receipt_ready submission)})
      (pending_ask_answer_receipts state) in
  let completions = List.map (fun (submission, (completion : Ask_answer_completion.observation)) ->
    {ready_at_ns=completion.observed_ns;
     message=ask_answer_completion_message submission completion})
      (take_pending_ask_answer_completions state) in
  let runtime_forms = List.map (fun (request,status,ready_at_ns) ->
    {ready_at_ns;message=Runtime_msg (Runtime_form_save_changed (request,status,ready_at_ns))})
      (pending_runtime_form_save_receipts state) in
  let settings = List.map (fun (request,status,ready_at_ns) ->
    {ready_at_ns;message=Keeper_msg (Keeper_settings_save_changed (request,status,ready_at_ns))})
      (pending_keeper_settings_save_receipts state) in
  let assignments = List.map (fun (request,status,ready_at_ns) ->
    {ready_at_ns;message=Runtime_msg (Runtime_assignment_changed (request,status,ready_at_ns))})
      (pending_runtime_assignment_receipts state) in
  let creations = List.map (fun (request,status,ready_at_ns) ->
    {ready_at_ns;message=Keeper_msg (Keeper_creation_changed (request,status))})
      (pending_keeper_creation_receipts state) in
  let tasks = List.map (fun (request, (completion : Masc_tui_task_dispatch.completion)) ->
    {ready_at_ns=completion.ready_at_ns;message=Task_msg (Task_dispatch_completed request)})
      (pending_task_dispatch_completions state) in
  List.concat [receipts;completions;runtime_forms;settings;assignments;creations;tasks;history]

module Delivery_round : sig
  type 'a t
  val empty : 'a t
  (** Capture the actual queued prefix, apply it in FIFO order, then collect
      and deliver one finite set of owned results. A completed round returns
      [None] even if new shared traffic is queued. [can_take] uses the caller's
      existing deadline; a paused round retains its exact prefix/remainder. *)
  val take : 'a t -> can_take:(unit -> bool) -> queued:(unit -> int) ->
    take_shared:(unit -> 'a option) -> collect_owned:(unit -> 'a list) ->
    'a option * 'a t
end = struct
  type 'a t = Await_prefix | Shared_prefix of int | Owned_results of 'a list
  let empty = Await_prefix
  let rec take round ~can_take ~queued ~take_shared ~collect_owned =
    if not (can_take ()) then None, round
    else match round with
    | Await_prefix ->
        take (Shared_prefix (queued ())) ~can_take ~queued ~take_shared ~collect_owned
    | Shared_prefix remaining when remaining > 0 ->
        (match take_shared () with
         | Some ready -> Some ready, Shared_prefix (remaining-1)
         | None ->
             take (Owned_results (collect_owned ()))
               ~can_take ~queued ~take_shared ~collect_owned)
    | Shared_prefix _ ->
        take (Owned_results (collect_owned ()))
          ~can_take ~queued ~take_shared ~collect_owned
    | Owned_results (ready :: rest) -> Some ready, Owned_results rest
    | Owned_results [] -> None, Await_prefix
end

let rec workspace_message_is_read = function
  | Code_msg answer ->
      (match Masc_tui_code_results.answer_kind answer with
       | Masc_tui_code_results.Read -> true
       | Masc_tui_code_results.Save -> false)
  | Context_msg answer ->
      (match Masc_tui_context_results.answer_kind answer with
       | Masc_tui_context_results.Read -> true)
  | Fleet_msg answer ->
      (match Masc_tui_fleet_results.answer_kind answer with
       | Masc_tui_fleet_results.Read -> true)
  | Original_msg answer ->
      (match Masc_tui_original_results.answer_kind answer with
       | Masc_tui_original_results.Read -> true)
  | Board_msg (Board_attachment_saved _) | Resource_msg (Resource_exported _ | Resource_saved _ | Resource_share_changed _) | Verification_msg (Verification_evidence_exported _) -> false
  | (Keeper_msg (Keeper_logs_loaded _ | Keeper_execute_streamed _)) -> true
  | Chat_msg (Chat_search_finished _) -> true
  | Workspace_scoped (_, _, message)
  | Chat_command_read_completed (_, message) -> workspace_message_is_read message
  | Workspace_operation _ -> false
  | Keeper_msg (Keeper_queue_action_received _) -> false
  | Keeper_msg (Keeper_queue_loaded (_, _, action, _)) ->
    (match action with Masc_tui_queue_inspection.Inspect | Inspect_peers _ -> true
     | Pause | Resume | Clear | Cancel _ | Move_to_end _ | Run_next _ | Edit _
     | Cancel_event _ | Prioritize_event _ -> false)
  (* A room read is retired with its reading and released by
     [suspend_workspace_readings]; a send or leave keeps its receipt. *)
  | Play_msg (Play_room_received (request, _)) -> Masc_tui_play_room.is_read request
  (* A roster observation cannot release retained input after its read epoch
     retires. A completed resume POST still owns its mutation receipt. *)
  | Keeper_msg (Keeper_queue_resume_confirmed (_, _, Owner_already_active, _)) -> true
  | Keeper_msg (Keeper_queue_resume_confirmed (_, _, Owner_resumed, _)) -> false
  | Lane_msg (Lane_declaration_loaded (_, request, _, _, _)) ->
    (match request with Masc_tui_lane_declaration.Read _ -> true | Save _ -> false)
  | Account_msg (Account_login_json (_, _, action, _)) -> account_login_action_is_read action
  | Workspace_msg (Workspace_identity_unconfirmed _)
  | Keeper_msg (Keeper_chat_operation_loaded _)
  | Lane_msg (Lane_application_loaded _
  | Lane_package_catalog_loaded _
  | Lane_package_preview_loaded _
  | Lane_addons_loaded _
  | Lane_subscriptions_loaded _)
  | Keeper_msg (Keeper_deletions_loaded _)
  | Msx_msg (Msx_activity_loaded _
  | Msx_live_loaded _)
  | Dos_live_loaded _
  | Voice_msg (Voice_agent_voices_loaded _
  | Voice_wizard_reread _
  | Voice_config_loaded _
  | Voice_wizard_probed _)
  | Board_msg (Board_post_refresh_done _)
  | Keeper_msg (Keeper_chat_first_page_loaded _
  | Keeper_chat_history_loaded _
  | Keeper_chat_copy_loaded _
  | Keeper_native_tasks_loaded _
  | Keeper_child_content_loaded _
  | Keeper_preparation_loaded _
  | Keeper_chat_journal_loaded _)
  | Keeper_msg (Keeper_chat_older_loaded _)
  | Local_msg (Local_workspace_read _
  | Local_keepers_read _)
  | Live_context_loaded _
  | Keeper_msg (Keeper_composite_loaded _)
  | Lane_msg (Lane_inventory_loaded _)
  | Clients_loaded _
  | Lane_msg (Lane_runs_loaded _
  | Lane_run_detail_loaded _)
  | Measurement_artifact_loaded _
  | Verification_msg (Verification_loaded _)
  | Harness_msg (Harness_loaded _)
  | Overview_loaded _
  | Fusion_msg (Fusion_runs_loaded _
  | Fusion_detail_loaded _
  | Fusion_historical_detail_loaded _
  | Fusion_launch_options_loaded _)
  | Memory_msg (Memory_recall_standing_loaded _)
  | Repository_msg (Repositories_loaded _)
  | Workspace_msg (Workspace_activity_loaded _)
  | Memory_msg (Memory_loaded _
  | Memory_input_loaded _
  | Memory_world_loaded _
  | Memory_facts_loaded _)
  | Repository_msg (Repository_changes_loaded _
  | Repository_changes_diff_loaded _)
  | File_changes_loaded _
  | Keeper_msg (Keeper_chat_file_changes_loaded _)
  | Git_diff_loaded _
  | Browser_msg (Browser_history_list_loaded _
  | Browser_history_page_loaded _
  | Browser_lane_clients_loaded _
  | Browser_lane_loaded _
  | Browser_lane_scene_loaded _
  | Browser_lane_screenshot_ready _)
  | Connectors_msg (Connectors_status_loaded _
  | Connectors_loaded _)
  | Runtime_msg (Runtime_surface_loaded _)
  | Tools_msg (Tools_read_loaded _)
  | Skill_evidence_loaded _
  | Tools_msg (Tools_async_observation_loaded _)
  | ((Tools_msg (Tools_async_detail_loaded _) | Task_msg (Task_document_prepared _)) | Tools_msg (Tools_async_task_body_loaded _ | Tools_async_task_history_loaded _ | Tools_volume_gc_reported _))
  | Runtime_msg (Runtime_catalog_loaded _)
  | Keeper_msg (Keeper_tool_approvals_loaded _)
  | Ask_msg (Asks_reloaded _) | Keeper_msg (Keeper_roster_reloaded _ | Keeper_row_reloaded _)
  | Approvals_msg (Approvals_summary_loaded _)
  | Listen_prepared _
  | Sent_image_ready _
  | Keeper_msg (Keeper_turns_loaded _ | Keeper_waiting_loaded _)
  | Gate_msg (Gate_snapshot_loaded _)
  | Keeper_msg (Keeper_gate_settings_loaded _
  | Keeper_tool_modes_loaded _)
  | Goal_msg (Goal_confirmation_loaded _)
  | Schedule_msg (Schedules_loaded _
  | Schedule_wake_history_loaded _)
  | Keeper_msg (Keeper_schedules_loaded _ | Keeper_story_turns_loaded _ | Keeper_memory_activity_loaded _)
  | System_log_streamed _
  | Ask_msg (Ask_followup_observed _ | Ask_followup_finished _)
  | Board_msg (Board_attachment_loaded _ | Board_attachment_prepared _) | Chat_msg (Chat_call_loaded _) | Task_msg (Task_creation_read_done _) | Keeper_msg (Keeper_calls_loaded _)
  | Goal_msg (Goal_timeline_loaded _ | Goal_candle_loaded _)
  | Task_msg (Task_history_loaded _)
  | Verification_msg (Verification_evidence_loaded _)
  | Keeper_msg (Keeper_settings_editor_loaded _
  | Keeper_config_view_loaded _
  | Keeper_items_loaded _
  | Keeper_sandbox_view_loaded _
  | Keeper_sandbox_logs_loaded _)
  | Exact_msg (Exact_activity_read _)
  | Machine_msg (Machine_activity_read _)
  | Runtime_msg (Runtime_config_view_loaded _
  | Runtime_params_loaded _)
  | Prompts_loaded _
  | Keeper_msg (Keeper_board_quarantines_loaded _ | Keeper_efficiency_loaded _)
  | Preset_msg (Presets_listed _
  | Preset_detail_loaded _
  | Preset_contents_shown _)
  | Play_msg (Play_invites_listed _)
  | Librarian_input_loaded _
  | (Resource_msg (Resources_listed _) | Artifact_msg (Artifact_checks_loaded _))
  | Acting_pane_changes_loaded _
  | Resource_msg (Resource_read _ | Resource_share_recovery_loaded _ | Resource_diagram_ready _)
  | Github_msg (Github_identity_view_loaded _)
  | Identity_msg (Identity_providers_loaded _)
  | Observer_msg (Observer_session_ready _ | Observer_opened _
  | Observer_received _
  | Observer_closed _ | Observer_retry_due _ | Observer_recovery_ready _ | Observer_recovery_identity _)
  | Keeper_msg (Keeper_chat_dispatch_started _)
    -> true
  | Voice_msg (Voice_wizard_saved _)
  | Msx_msg (Msx_frame_loaded _
  (* A withdrawn tick attempted no POST and changes no server state; it only
     releases the pending poll token, so it stays an observation, not an
     operation outcome. *)
  | Msx_tick_withdrawn _)
  | Voice_msg (Voice_agent_voice_saved _
  | Voice_calibrated _ | Voice_level _
  | Voice_transcribed _
  | Voice_silent _
  | Voice_discarded _
  | Voice_failed _)
  | Http_msg (Http_keeper_roster_loaded _ | Http_dataset_loaded _) | Http_surface_read_completed _ | Http_msg (Http_initial_identity_read _ | Http_asks_loaded _ | Http_approvals_loaded _) | Ask_msg (Ask_answer_receipt_ready _) | Http_msg (Http_refresh_done _
  | Http_refresh_failed _)
  (* Not a reply: the refresh that recovered the identity tells the loop to
     read the confirm queue again. It belongs to that refresh, which is
     ordered by its own tickets. *)
  | (Approvals_msg Approvals_listing_superseded)
  | (Keeper_msg Keeper_composer_released)
  | Http_msg (Http_scoped_refresh_done _
  | Http_scoped_refresh_failed _)
  | Approvals_msg (Approval_decision_done _)
  | Ask_msg (Ask_answer_done _)
  | Keeper_msg (Keeper_chat_done _
  | Keeper_chat_stream_deltas _
  | Keeper_chat_stream_unavailable _
  | Keeper_run_next_done _
  | Keeper_observed_interrupt_done _
  | Keeper_chat_interrupt_done _)
  | Fusion_msg (Fusion_launched _)
  | Browser_msg (Browser_lane_follow_loaded _)
  | Connectors_msg (Connector_unbind_all_done _) | Tools_msg (Tools_volume_gc_reclaimed _)
  | Runtime_msg (Runtime_lane_slots_written _
  | Runtime_assignment_changed _)
  | Keeper_msg (Keeper_chat_approval_answered _
  | Keeper_chat_control_received _)
  | Gate_msg (Gate_approval_resolved _
  | Gate_auto_judge_retried _
  | Gate_mode_set _)
  | Keeper_msg (Keeper_tool_approval_answered _
  | Keeper_tool_mode_set _
  | Keeper_chat_dispatch_blocked _)
  | Schedule_msg (Schedule_form_authority_refused _)
  | Keeper_msg (Keeper_deletion_retry_done _)
  | Runtime_msg (Runtime_form_save_changed _) | Keeper_msg (Keeper_settings_save_changed _ | Keeper_creation_changed _
  | Keeper_action_done _ | Keeper_memory_catch_up_done _)
  | Board_msg (Board_publication_done _ | Board_comment_done _)
  | (Board_msg (Board_vote_done _) | Artifact_msg (Artifact_check_changed _))
  | Goal_msg (Goal_transition_done _
  | Goal_confirmation_submitted _)
  | Schedule_msg (Schedule_cancel_done _)
  | Verification_msg (Verification_verdict_done _)
  | Harness_msg (Harness_label_done _)
  | Task_msg (Task_cancel_done _)
  | Exact_msg (Exact_activity_saved _)
  | Machine_msg (Machine_activity_saved _)
  | Runtime_msg (Runtime_param_written _)
  | Board_msg (Board_quarantine_requeued _
  | Board_quarantines_bulk_progress _
  | Board_quarantines_bulk_requeued _)
  | Preset_msg (Preset_saved _
  | Preset_restored _
  | Preset_deleted _)
  | Play_msg (Play_invite_issued _
  | Play_invite_revoked _)
  | Identity_msg (Identity_switch_set _
  | Identity_login_started _
  | Identity_refreshed _
  | Identity_app_saved _
  | Identity_disconnected _)
  | Account_msg (Account_login_event _
  | Account_login_removal _)
  | Github_msg (Github_login_lines _
  | Github_login_finished _
  | Github_token_saved _)
  | Task_msg (Task_dispatch_completed _)
  | Image_render_ready _
    -> false


(* Reads that may be withdrawn by pending input, and Board openings that must
   wait for the input to select their still-current owner. *)
let rec message_waits_for_input ~resource_read ~recovery_loaded = function
  | Workspace_scoped (_, _, message) ->
      message_waits_for_input ~resource_read ~recovery_loaded message
  | Workspace_operation message ->
      message_waits_for_input ~resource_read:(fun _ -> false)
        ~recovery_loaded:(fun _ -> false) message
  | Resource_msg (Resource_read (request, _, _)) -> resource_read request
  | Resource_msg (Resource_share_recovery_loaded (request, _)) -> recovery_loaded request
  | Code_msg answer ->
      (match Masc_tui_code_results.answer_kind answer with
       | Masc_tui_code_results.(Read | Save) -> false)
  | Context_msg answer ->
      (match Masc_tui_context_results.answer_kind answer with
       | Masc_tui_context_results.Read -> false)
  | Fleet_msg answer ->
      (match Masc_tui_fleet_results.answer_kind answer with
       | Masc_tui_fleet_results.Read -> false)
  | Original_msg answer ->
      (match Masc_tui_original_results.answer_kind answer with
       | Masc_tui_original_results.Read -> false)
  | Sent_image_ready _ | Image_render_ready _ -> true
  | Board_msg (Board_attachment_saved (_, result)) ->
      (match result with
       | Error _ -> false
       | Ok (Board_image_open_ready _ | Board_image_open_retry _) -> true
       | Ok (Board_image_open_failed _ | Board_image_open_finished _ | Board_saved_original _) -> false)
  | Chat_msg (Chat_search_finished _) | Chat_command_read_completed _
  | Workspace_msg (Workspace_identity_unconfirmed _) | Schedule_msg (Schedule_form_authority_refused _)
  | Lane_msg (Lane_package_catalog_loaded _ | Lane_package_preview_loaded _)
  | Keeper_msg (Keeper_queue_resume_confirmed _ | Keeper_queue_loaded _) | Lane_msg (Lane_addons_loaded _
  | Lane_application_loaded _ | Lane_subscriptions_loaded _ | Lane_declaration_loaded _)
  | Keeper_msg (Keeper_deletions_loaded _) | Msx_msg (Msx_tick_withdrawn _) | Keeper_msg (Keeper_deletion_retry_done _)
  | Msx_msg (Msx_frame_loaded _ | Msx_activity_loaded _ | Msx_live_loaded _) | Dos_live_loaded _
  | Voice_msg (Voice_wizard_saved _ | Voice_agent_voices_loaded _ | Voice_agent_voice_saved _
  | Voice_wizard_probed _ | Voice_wizard_reread _ | Voice_config_loaded _ | Voice_calibrated _
  | Voice_level _ | Voice_transcribed _ | Voice_silent _ | Voice_discarded _ | Voice_failed _)
  | Overview_loaded _ | Http_msg (Http_asks_loaded _ | Http_approvals_loaded _)
  | Ask_msg (Ask_answer_receipt_ready _ | Ask_followup_observed _ | Ask_followup_finished _)
  | Http_msg (Http_keeper_roster_loaded _ | Http_dataset_loaded _) | Http_surface_read_completed _
  | Http_msg (Http_initial_identity_read _ | Http_refresh_done _ | Http_refresh_failed _)
  | Approvals_msg (Approvals_listing_superseded | Approvals_summary_loaded _) | (Keeper_msg Keeper_composer_released)
  | Http_msg (Http_scoped_refresh_done _ | Http_scoped_refresh_failed _) | Board_msg (Board_post_refresh_done _)
  | Approvals_msg (Approval_decision_done _) | Ask_msg (Ask_answer_done _) | Keeper_msg (Keeper_chat_dispatch_started _
  | Keeper_chat_done _ | Keeper_chat_stream_deltas _ | Keeper_chat_stream_unavailable _
  | Keeper_run_next_done _ | Keeper_observed_interrupt_done _ | Keeper_chat_interrupt_done _
  | Keeper_chat_history_loaded _ | Keeper_chat_first_page_loaded _ | Keeper_chat_copy_loaded _
  | Keeper_chat_operation_loaded _ | Keeper_chat_journal_loaded _ | Keeper_native_tasks_loaded _
  | Keeper_preparation_loaded _ | Keeper_child_content_loaded _) | Keeper_msg (Keeper_chat_older_loaded _) | Live_context_loaded _
  | Local_msg (Local_keepers_read _ | Local_workspace_read _) | Keeper_msg (Keeper_composite_loaded _) | Lane_msg (Lane_inventory_loaded _)
  | Clients_loaded _ | Lane_msg (Lane_runs_loaded _ | Lane_run_detail_loaded _)
  | Measurement_artifact_loaded _ | Verification_msg (Verification_loaded _) | Harness_msg (Harness_loaded _)
  | Fusion_msg (Fusion_runs_loaded _ | Fusion_detail_loaded _ | Fusion_historical_detail_loaded _
  | Fusion_launch_options_loaded _ | Fusion_launched _) | Memory_msg (Memory_recall_standing_loaded _)
  | Repository_msg (Repositories_loaded _)
  | Workspace_msg (Workspace_activity_loaded _) | Memory_msg (Memory_loaded _ | Memory_input_loaded _
  | Memory_world_loaded _ | Memory_facts_loaded _) | Repository_msg (Repository_changes_loaded _ | Repository_changes_diff_loaded _)
  | File_changes_loaded _ | Keeper_msg (Keeper_chat_file_changes_loaded _) | Git_diff_loaded _
  | Browser_msg (Browser_history_list_loaded _ | Browser_history_page_loaded _
  | Browser_lane_clients_loaded _ | Browser_lane_loaded _
  | Browser_lane_scene_loaded _ | Browser_lane_follow_loaded _ | Browser_lane_screenshot_ready _)
  | Connectors_msg (Connectors_status_loaded _ | Connectors_loaded _ | Connector_unbind_all_done _) | Tools_msg (Tools_volume_gc_reclaimed _)
  | Runtime_msg (Runtime_surface_loaded _) | Tools_msg (Tools_read_loaded _)
  | Skill_evidence_loaded _ | Tools_msg (Tools_async_observation_loaded _ | Tools_async_detail_loaded _)
  | Task_msg (Task_document_prepared _) | Tools_msg (Tools_async_task_body_loaded _
  | Tools_async_task_history_loaded _ | Tools_volume_gc_reported _) | Runtime_msg (Runtime_lane_slots_written _ | Runtime_catalog_loaded _
  | Runtime_assignment_changed _) | Keeper_msg (Keeper_chat_approval_answered _
  | Keeper_tool_approvals_loaded _) | Ask_msg (Asks_reloaded _) | Keeper_msg (Keeper_roster_reloaded _ | Keeper_row_reloaded _) | Listen_prepared _ | Resource_msg (Resource_diagram_ready _)
  | Keeper_msg (Keeper_turns_loaded _ | Keeper_waiting_loaded _
  | Keeper_chat_control_received _) | Gate_msg (Gate_snapshot_loaded _ | Gate_approval_resolved _
  | Gate_auto_judge_retried _ | Gate_mode_set _) | Keeper_msg (Keeper_tool_approval_answered _
  | Keeper_gate_settings_loaded _ | Keeper_tool_modes_loaded _ | Keeper_tool_mode_set _
  | Keeper_chat_dispatch_blocked _ | Keeper_logs_loaded _ | Keeper_settings_save_changed _)
  | Runtime_msg (Runtime_form_save_changed _) | Keeper_msg (Keeper_creation_changed _ | Keeper_action_done _ | Keeper_memory_catch_up_done _)
  | Board_msg (Board_publication_done _ | Board_comment_done _ | Board_vote_done _) | Goal_msg (Goal_transition_done _
  | Goal_confirmation_submitted _ | Goal_confirmation_loaded _) | Schedule_msg (Schedules_loaded _
  | Schedule_wake_history_loaded _) | Keeper_msg (Keeper_schedules_loaded _ | Keeper_story_turns_loaded _ | Keeper_memory_activity_loaded _) | System_log_streamed _
  | Schedule_msg (Schedule_cancel_done _) | Verification_msg (Verification_verdict_done _) | Harness_msg (Harness_label_done _)
  | Chat_msg (Chat_call_loaded _) | Board_msg (Board_attachment_loaded _ | Board_attachment_prepared _)
  | Keeper_msg (Keeper_calls_loaded _) | Goal_msg (Goal_timeline_loaded _ | Goal_candle_loaded _)
  | Task_msg (Task_history_loaded _ | Task_cancel_done _) | Verification_msg (Verification_evidence_exported _
  | Verification_evidence_loaded _) | Keeper_msg (Keeper_settings_editor_loaded _
  | Keeper_config_view_loaded _ | Keeper_items_loaded _ | Keeper_sandbox_view_loaded _
  | Keeper_sandbox_logs_loaded _) | Exact_msg (Exact_activity_read _ | Exact_activity_saved _)
  | Machine_msg (Machine_activity_read _ | Machine_activity_saved _) | Runtime_msg (Runtime_config_view_loaded _
  | Runtime_params_loaded _ | Runtime_param_written _) | Prompts_loaded _
  | Keeper_msg (Keeper_board_quarantines_loaded _ | Keeper_efficiency_loaded _) | Board_msg (Board_quarantine_requeued _
  | Board_quarantines_bulk_progress _ | Board_quarantines_bulk_requeued _) | Preset_msg (Presets_listed _
  | Preset_detail_loaded _ | Preset_contents_shown _ | Preset_saved _ | Preset_restored _
  | Preset_deleted _) | Play_msg (Play_room_received _ | Play_invites_listed _ | Play_invite_issued _
  | Play_invite_revoked _) | Librarian_input_loaded _ | Artifact_msg (Artifact_checks_loaded _
  | Artifact_check_changed _) | Resource_msg (Resources_listed _)
  | Acting_pane_changes_loaded _ | Resource_msg (Resource_exported _ | Resource_saved _ | Resource_share_changed _)
  | Github_msg (Github_identity_view_loaded _) | Identity_msg (Identity_providers_loaded _ | Identity_switch_set _
  | Identity_login_started _ | Identity_refreshed _ | Identity_app_saved _
  | Identity_disconnected _) | Account_msg (Account_login_event _ | Account_login_json _
  | Account_login_removal _) | Github_msg (Github_login_lines _ | Github_login_finished _
  | Github_token_saved _) | Observer_msg (Observer_session_ready _ | Observer_opened _ | Observer_received _ | Observer_closed _ | Observer_retry_due _ | Observer_recovery_ready _ | Observer_recovery_identity _)
  | Task_msg (Task_dispatch_completed _
  | Task_creation_read_done _) | Keeper_msg (Keeper_queue_action_received _
  | Keeper_execute_streamed _) -> false
let workspace_message_admitted state ~authority ~reading message =
  workspace_reply_admitted state ~authority ~reading
    ~kind:(if workspace_message_is_read message
      then Workspace_observation else Workspace_operation_outcome)

let observer_stream_owned state expected =
  match state.observer_stream_owner with
  | Some current -> current == expected
  | None -> false

let observer_retry_owned state ~authority expected =
  authority = state.workspace_authority
  && match state.observer_retry_owner, state.observer with
     | Some current, (Observer_closed_before_answer _ | Observer_closed_after_live _) ->
         current == expected
     | None, _ | Some _, (Observer_off | Observer_opening | Observer_live _) -> false

let observer_recovery_owned state ~authority expected =
  authority = state.workspace_authority
  && match state.observer_recovery_owner, state.workspace_identity, state.server_identity with
     | Some current, Workspace_identity_match_unconfirmed _, Some _
     | Some current, Workspace_identity_unread, None -> current == expected
     | None, _, _
     | Some _, (Workspace_identity_match | Workspace_identity_mismatch _), _
     | Some _, Workspace_identity_match_unconfirmed _, None
     | Some _, Workspace_identity_unread, Some _ -> false

let observer_recovery_identity_owned state ~authority ~owner ~live ~instance ~origin =
  !live && observer_recovery_owned state ~authority owner
  && match origin, state.workspace_identity, state.server_identity, state.observer_scope_binding with
     | Observer_existing_workspace expected, Workspace_identity_match_unconfirmed _,
       Some current, Observer_scope_bound previous ->
         expected.Masc.Tui_decode.sid_state_ready <> Some false
         && String.equal previous instance
         && server_workspace_matches ~expected:(Some expected) (Ok current)
     | Observer_initial_workspace expected, Workspace_identity_unread, None, Observer_scope_unbound ->
         state.local_workspace_paths = Some expected
         && not (Canonical_path.is_empty expected.lw_base_path)
         && not (Canonical_path.is_empty expected.lw_masc_root)
     | (Observer_existing_workspace _ | Observer_initial_workspace _),
       (Workspace_identity_unread | Workspace_identity_match_unconfirmed _
       | Workspace_identity_match | Workspace_identity_mismatch _), _,
       (Observer_scope_unbound | Observer_scope_bound _ | Observer_scope_retired) -> false

(* Capture the read intent while the exact effect owner is still Loading.
   The UI applies the receipt first, then retains or dispatches this read. *)
let retired_operation_observation state ~authority ~reading message =
  let rec inspect = function
    | Workspace_operation inner -> inspect inner
    | Code_msg answer ->
        (match Masc_tui_code_results.answer_kind answer with
         | Masc_tui_code_results.(Read | Save) -> None)
    | Context_msg answer ->
        (match Masc_tui_context_results.answer_kind answer with
         | Masc_tui_context_results.Read -> None)
    | Fleet_msg answer ->
        (match Masc_tui_fleet_results.answer_kind answer with
         | Masc_tui_fleet_results.Read -> None)
    | Original_msg answer ->
        (match Masc_tui_original_results.answer_kind answer with
         | Masc_tui_original_results.Read -> None)
    | Browser_msg (Browser_lane_scene_loaded (generation, Ok _)) ->
        (match state.browser_lane with
         | Some ({load=Browser_lane_view.Loading (current, operation); _} as view)
           when current = generation && state.browser_lane_generation = generation ->
             Option.map (fun read -> Browser_scene_observation (generation, view, read))
               (Browser_lane_view.observation_after_effect operation)
         | Some { load = (Browser_lane_view.Idle | (Browser_lane_view.No_browser | Browser_lane_view.Failed _));_}
         | None | Some {load=Loading (_, _); _ } -> None)
    | Lane_msg (Lane_subscriptions_loaded (generation, Ok _)) ->
        (match state.lane_addons with
         | Some view when view.generation = generation
             && Option.is_some view.subscription_panel ->
               Some (Lane_subscriptions_observation generation)
         | _ -> None)
    | Chat_msg (Chat_search_finished (_, _, _, _)) | Workspace_scoped (_, _, _)
    | Chat_command_read_completed (_, _) | Workspace_msg (Workspace_identity_unconfirmed _)
    | Schedule_msg (Schedule_form_authority_refused _) | Lane_msg (Lane_package_catalog_loaded (_, _, _)
    | Lane_package_preview_loaded (_, _, _))
    | Keeper_msg (Keeper_queue_resume_confirmed (_, _, _, _) | Keeper_queue_action_received _ | Keeper_queue_loaded (_, _, _, _))
    | Lane_msg (Lane_addons_loaded (_, _, _) | Lane_application_loaded (_, _)
    | Lane_subscriptions_loaded (_, Error _)
    | Lane_declaration_loaded (_, _, _, _, _))
    | Keeper_msg (Keeper_deletions_loaded (_, _)) | Msx_msg (Msx_tick_withdrawn (_, _))
    | Keeper_msg (Keeper_deletion_retry_done (_, _)) | Msx_msg (Msx_frame_loaded (_, _)
    | Msx_activity_loaded (_, _) | Msx_live_loaded (_, _))
    | Dos_live_loaded (_, _) | Voice_msg (Voice_wizard_saved (_, _)
    | Voice_agent_voices_loaded _ | Voice_agent_voice_saved _
    | Voice_wizard_probed (_, _) | Voice_wizard_reread (_, _)
    | Voice_config_loaded (_, _, _) | Voice_calibrated _ | Voice_level _ | Voice_transcribed _
    | Voice_silent _ | Voice_discarded _ | Voice_failed _) | Http_msg (Http_keeper_roster_loaded _ | Http_dataset_loaded _) | Http_surface_read_completed _ | Http_msg (Http_initial_identity_read _ | Http_asks_loaded _ | Http_approvals_loaded _) | Ask_msg (Ask_answer_receipt_ready _ | Ask_followup_observed _ | Ask_followup_finished _) | Http_msg (Http_refresh_done _
    | Http_refresh_failed (_, _, _)) | Approvals_msg (Approvals_listing_superseded
    | Approvals_summary_loaded (_, _, _, _)) | (Keeper_msg Keeper_composer_released)
    | Http_msg (Http_scoped_refresh_done (_, _, _)
    | Http_scoped_refresh_failed (_, _, _, _, _, _))
    | Board_msg (Board_post_refresh_done (_, _)) | Approvals_msg (Approval_decision_done (_, _, _, _, _))
    | Ask_msg (Ask_answer_done (_, _, _)) | Keeper_msg (Keeper_chat_dispatch_started (_, _, _)
    | Keeper_chat_done (_, _, _, _) | Keeper_chat_stream_deltas (_, _)
    | Keeper_chat_stream_unavailable (_, _) | Keeper_run_next_done (_, _)
    | Keeper_observed_interrupt_done (_, _, _, _)
    | Keeper_chat_interrupt_done (_, _, _)
    | Keeper_chat_first_page_loaded (_, _)
    | Keeper_chat_history_loaded (_, _, _)
    | Keeper_chat_copy_loaded (_, _, _) | Keeper_chat_operation_loaded _
    | Keeper_chat_journal_loaded _ | Keeper_native_tasks_loaded (_, _)
    | Keeper_child_content_loaded (_, _) | Keeper_preparation_loaded (_, _))
    | Keeper_msg (Keeper_chat_older_loaded (_, _, _, _)) | Local_msg (Local_workspace_read (_, _) | Local_keepers_read (_, _)) | Live_context_loaded (_, _, _)
    | Keeper_msg (Keeper_composite_loaded (_, _, _)) | Lane_msg (Lane_inventory_loaded (_, _)) | Clients_loaded (_, _)
    | Lane_msg (Lane_runs_loaded (_, _, _, _) | Lane_run_detail_loaded (_, _, _))
    | Measurement_artifact_loaded (_, _, _) | Verification_msg (Verification_loaded _)
    | Harness_msg (Harness_loaded _) | Overview_loaded _ | Fusion_msg (Fusion_runs_loaded (_, _)
    | Fusion_detail_loaded (_, _, _) | Fusion_historical_detail_loaded (_, _, _)
    | Fusion_launch_options_loaded (_, _) | Fusion_launched (_, _))
    | Memory_msg (Memory_recall_standing_loaded (_, _))
    | Repository_msg (Repositories_loaded _) | Workspace_msg (Workspace_activity_loaded (_, _)) | Memory_msg (Memory_loaded _
    | Memory_input_loaded (_, _) | Memory_world_loaded (_, _) | Memory_facts_loaded (_, _))
    | Repository_msg (Repository_changes_loaded (_, _) | Repository_changes_diff_loaded (_, _))
    | File_changes_loaded (_, _) | Keeper_msg (Keeper_chat_file_changes_loaded (_, _, _))
    | Git_diff_loaded (_, _) | Browser_msg (Browser_history_list_loaded (_, _)
    | Browser_history_page_loaded (_, _) | Browser_lane_clients_loaded (_, _)
    | Browser_lane_loaded (_, _)
    | Browser_lane_scene_loaded (_, Error _) | Browser_lane_follow_loaded (_, _)
    | Browser_lane_screenshot_ready _) | Connectors_msg (Connectors_status_loaded (_, _) | Connectors_loaded (_, _)
    | Connector_unbind_all_done _) | Tools_msg (Tools_volume_gc_reclaimed _) | Runtime_msg (Runtime_surface_loaded (_, _))
    | Tools_msg (Tools_read_loaded _)
    | Skill_evidence_loaded (_, _, _) | (Tools_msg (Tools_async_observation_loaded (_, _)) | ((Tools_msg (Tools_async_detail_loaded _) | Task_msg (Task_document_prepared _)) | Tools_msg (Tools_async_task_body_loaded _ | Tools_async_task_history_loaded _ | Tools_volume_gc_reported _)))
    | Runtime_msg (Runtime_lane_slots_written (_, _, _) | Runtime_catalog_loaded (_, _)
    | Runtime_assignment_changed (_, _, _))
    | Keeper_msg (Keeper_chat_approval_answered (_, _, _, _)
    | Keeper_tool_approvals_loaded (_, _, _)) | Ask_msg (Asks_reloaded _) | Keeper_msg (Keeper_roster_reloaded _ | Keeper_row_reloaded _) | Listen_prepared _ | Sent_image_ready _
    | Image_render_ready _ | Keeper_msg (Keeper_turns_loaded _ | Keeper_waiting_loaded _
    | Keeper_chat_control_received (_, _, _)) | Gate_msg (Gate_snapshot_loaded (_, _, _)
    | Gate_approval_resolved (_, _, _, _, _)
    | Gate_auto_judge_retried (_, _, _, _) | Gate_mode_set (_, _, _))
    | Keeper_msg (Keeper_tool_approval_answered (_, _, _, _, _, _)
    | Keeper_gate_settings_loaded _ | Keeper_tool_modes_loaded (_, _)
    | Keeper_tool_mode_set (_, _, _, _) | Keeper_chat_dispatch_blocked (_, _))
    | (Keeper_msg (Keeper_logs_loaded _ | Keeper_execute_streamed _)) | Runtime_msg (Runtime_form_save_changed _) | Keeper_msg (Keeper_settings_save_changed _ | Keeper_creation_changed _ | Keeper_action_done (_, _, _, _) | Keeper_memory_catch_up_done _) | Board_msg (Board_publication_done _ | Board_comment_done _)
    | (Board_msg (Board_vote_done _) | Artifact_msg (Artifact_check_changed _)) | Goal_msg (Goal_transition_done _ | Goal_confirmation_submitted _
    | Goal_confirmation_loaded (_, _)) | Schedule_msg (Schedules_loaded (_, _)
    | Schedule_wake_history_loaded (_, _)) | Keeper_msg (Keeper_schedules_loaded (_, _) | Keeper_story_turns_loaded (_, _) | Keeper_memory_activity_loaded (_, _))
    | System_log_streamed _ | Schedule_msg (Schedule_cancel_done (_, _))
    | Verification_msg (Verification_verdict_done _) | Harness_msg (Harness_label_done _)
    | Board_msg (Board_attachment_loaded _ | Board_attachment_prepared _) | Chat_msg (Chat_call_loaded _) | Task_msg (Task_creation_read_done _) | Keeper_msg (Keeper_calls_loaded (_, _, _)) | Goal_msg (Goal_timeline_loaded (_, _) | Goal_candle_loaded (_, _))
    | Task_msg (Task_history_loaded (_, _) | Task_cancel_done (_, _, _))
    | Verification_msg (Verification_evidence_loaded (_, _) | Verification_evidence_exported _) | Keeper_msg (Keeper_settings_editor_loaded _ | Keeper_config_view_loaded (_, _)
    | Keeper_items_loaded (_, _) | Keeper_sandbox_view_loaded (_, _)
    | Keeper_sandbox_logs_loaded (_, _, _)) | Exact_msg (Exact_activity_read (_, _)
    | Exact_activity_saved (_, _)) | Machine_msg (Machine_activity_read (_, _)
    | Machine_activity_saved (_, _)) | Runtime_msg (Runtime_config_view_loaded (_, _, _, _, _)
    | Runtime_params_loaded _ | Runtime_param_written (_, _))
    | Prompts_loaded (_, _) | Keeper_msg (Keeper_board_quarantines_loaded (_, _) | Keeper_efficiency_loaded (_, _))
    | Board_msg (Board_quarantine_requeued (_, _, _)
    | Board_quarantines_bulk_progress (_, _, _, _, _, _)
    | Board_quarantines_bulk_requeued (_, _)) | Preset_msg (Presets_listed (_, _)
    | Preset_detail_loaded (_, _) | Preset_contents_shown (_, _)
    | Preset_saved (_, _) | Preset_restored (_, _) | Preset_deleted (_, _))
    | Play_msg (Play_room_received (_, _) | Play_invites_listed (_, _)
    | Play_invite_issued (_, _, _) | Play_invite_revoked (_, _, _, _))
    | Librarian_input_loaded (_, _) | (Resource_msg (Resources_listed _) | Artifact_msg (Artifact_checks_loaded _))
    | Board_msg (Board_attachment_saved _) | Acting_pane_changes_loaded (_, _)
    | Resource_msg (Resource_exported _ | Resource_saved _ | Resource_share_changed _ | Resource_share_recovery_loaded _ | Resource_read (_, _, _) | Resource_diagram_ready _)
    | Github_msg (Github_identity_view_loaded (_, _)) | Identity_msg (Identity_providers_loaded (_, _, _)
    | Identity_switch_set (_, _, _, _) | Identity_login_started (_, _)
    | Identity_refreshed (_, _) | Identity_app_saved (_, _, _)
    | Identity_disconnected (_, _, _))
    | Account_msg (Account_login_event (_, _, _) | Account_login_json (_, _, _, _)
    | Account_login_removal (_, _, _, _, _)) | Github_msg (Github_login_lines (_, _)
    | Github_login_finished (_, _) | Github_token_saved (_, _))
    | Observer_msg (Observer_session_ready _ | Observer_opened _ | Observer_received (_, _) | Observer_closed _ | Observer_retry_due _ | Observer_recovery_ready _ | Observer_recovery_identity _)
    | Task_msg (Task_dispatch_completed _) -> None in
  if workspace_reply_admitted state ~authority ~reading ~kind:Workspace_observation
  then None else inspect message

let rec project_workspace_operation_reply state ~authority ~reading message =
  let project receipt observation = workspace_operation_reply state ~authority ~reading
      (receipt, observation) in
  match message with
  | Workspace_operation inner ->
      Workspace_operation (project_workspace_operation_reply state ~authority ~reading inner)
  | Code_msg answer ->
      (match Masc_tui_code_results.answer_kind answer with
       | Masc_tui_code_results.(Read | Save) -> message)
  | Context_msg answer ->
      (match Masc_tui_context_results.answer_kind answer with
       | Masc_tui_context_results.Read -> message)
  | Fleet_msg answer ->
      (match Masc_tui_fleet_results.answer_kind answer with
       | Masc_tui_fleet_results.Read -> message)
  | Original_msg answer ->
      (match Masc_tui_original_results.answer_kind answer with
       | Masc_tui_original_results.Read -> message)
  | Approvals_msg (Approval_decision_done (approval, decision, receipt, generation, observation)) ->
      let receipt, observation = project receipt observation in
      Approvals_msg (Approval_decision_done (approval, decision, receipt, generation, observation))
  | Ask_msg (Ask_answer_done (submission, receipt, observation)) ->
      let receipt, observation = project receipt observation in
      Ask_msg (Ask_answer_done (submission, receipt, observation))
  | Keeper_msg (Keeper_queue_loaded (keeper, control, action, Ok reply)) ->
      Keeper_msg (Keeper_queue_loaded (keeper, control, action,
        Ok (workspace_operation_reply state ~authority ~reading reply)))
  | Lane_msg (Lane_addons_loaded (generation, detail, Ok ({lar_snapshot=Some snapshot; _} as reply))) ->
      let reply, observation = project reply (Ok snapshot) in
      let reply = match observation with
        | Ok snapshot -> {reply with lar_snapshot=Some snapshot}
        | Error reason -> {reply with lar_snapshot=None; lar_inventory_read=`Failed reason} in
      Lane_msg (Lane_addons_loaded (generation, detail, Ok reply))
  | Lane_msg (Lane_subscriptions_loaded (generation, Ok snapshot)) ->
      let snapshot, observation = project snapshot (Ok snapshot.entries) in
      let entries = match observation with
        | Ok entries -> entries
        | Error reason -> List.map (fun (subscription, _) ->
            subscription, Masc_tui_lane_subscriptions.Unavailable reason) snapshot.entries in
      Lane_msg (Lane_subscriptions_loaded (generation, Ok {snapshot with entries}))
  | Browser_msg (Browser_lane_scene_loaded (generation, result)) ->
      let (), result = project () result in
      Browser_msg (Browser_lane_scene_loaded (generation, result))
  | Browser_msg (Browser_lane_follow_loaded (generation, Ok (receipt, result))) ->
      let receipt, result = project receipt result in
      Browser_msg (Browser_lane_follow_loaded (generation, Ok (receipt, result)))
  | Browser_msg (Browser_lane_screenshot_ready reply) ->
      let (), result = project () reply.result in
      Browser_msg (Browser_lane_screenshot_ready {reply with result})
  | Chat_msg (Chat_search_finished (_, _, _, _)) | Workspace_scoped (_, _, _)
  | Chat_command_read_completed (_, _) | Workspace_msg (Workspace_identity_unconfirmed _)
  | Schedule_msg (Schedule_form_authority_refused _) | Lane_msg (Lane_package_catalog_loaded (_, _, _)
  | Lane_package_preview_loaded (_, _, _))
  | Keeper_msg (Keeper_queue_resume_confirmed (_, _, _, _) | Keeper_queue_action_received _
  | Keeper_queue_loaded (_, _, _, Error _))
  | Lane_msg (Lane_addons_loaded (_, _, (Error _ | Ok { lar_snapshot = None; _ }))
  | Lane_application_loaded (_, _)
  | Lane_subscriptions_loaded (_, Error _) | Lane_declaration_loaded (_, _, _, _, _))
  | Keeper_msg (Keeper_deletions_loaded (_, _)) | Msx_msg (Msx_tick_withdrawn (_, _))
  | Keeper_msg (Keeper_deletion_retry_done (_, _)) | Msx_msg (Msx_frame_loaded (_, _)
  | Msx_activity_loaded (_, _) | Msx_live_loaded (_, _)) | Dos_live_loaded (_, _)
  | Voice_msg (Voice_wizard_saved (_, _) | Voice_agent_voices_loaded _
  | Voice_agent_voice_saved _ | Voice_wizard_probed (_, _)
  | Voice_wizard_reread (_, _) | Voice_config_loaded (_, _, _) | Voice_calibrated _ | Voice_level _
  | Voice_transcribed _ | Voice_silent _ | Voice_discarded _ | Voice_failed _)
  | Http_msg (Http_keeper_roster_loaded _ | Http_dataset_loaded _) | Http_surface_read_completed _ | Http_msg (Http_initial_identity_read _ | Http_asks_loaded _ | Http_approvals_loaded _) | Ask_msg (Ask_answer_receipt_ready _ | Ask_followup_observed _ | Ask_followup_finished _) | Http_msg (Http_refresh_done _ | Http_refresh_failed (_, _, _))
  | Approvals_msg (Approvals_listing_superseded | Approvals_summary_loaded (_, _, _, _))
  | (Keeper_msg Keeper_composer_released) | Http_msg (Http_scoped_refresh_done (_, _, _)
  | Http_scoped_refresh_failed (_, _, _, _, _, _)) | Board_msg (Board_post_refresh_done (_, _))
  | Keeper_msg (Keeper_chat_dispatch_started (_, _, _) | Keeper_chat_done (_, _, _, _)
  | Keeper_chat_stream_deltas (_, _) | Keeper_chat_stream_unavailable (_, _)
  | Keeper_run_next_done (_, _) | Keeper_observed_interrupt_done (_, _, _, _)
  | Keeper_chat_interrupt_done (_, _, _)
  | Keeper_chat_first_page_loaded (_, _)
  | Keeper_chat_history_loaded (_, _, _) | Keeper_chat_copy_loaded (_, _, _)
  | Keeper_chat_operation_loaded _ | Keeper_chat_journal_loaded _
  | Keeper_native_tasks_loaded (_, _) | Keeper_child_content_loaded (_, _) | Keeper_preparation_loaded (_, _))
  | Keeper_msg (Keeper_chat_older_loaded (_, _, _, _))
  | Local_msg (Local_workspace_read (_, _) | Local_keepers_read (_, _)) | Live_context_loaded (_, _, _) | Keeper_msg (Keeper_composite_loaded (_, _, _))
  | Lane_msg (Lane_inventory_loaded (_, _)) | Clients_loaded (_, _)
  | Lane_msg (Lane_runs_loaded (_, _, _, _) | Lane_run_detail_loaded (_, _, _))
  | Measurement_artifact_loaded (_, _, _) | Verification_msg (Verification_loaded _)
  | Harness_msg (Harness_loaded _) | Overview_loaded _ | Fusion_msg (Fusion_runs_loaded (_, _)
  | Fusion_detail_loaded (_, _, _) | Fusion_historical_detail_loaded (_, _, _)
  | Fusion_launch_options_loaded (_, _) | Fusion_launched (_, _))
  | Memory_msg (Memory_recall_standing_loaded (_, _))
  | Repository_msg (Repositories_loaded _) | Workspace_msg (Workspace_activity_loaded (_, _)) | Memory_msg (Memory_loaded _
  | Memory_input_loaded (_, _) | Memory_world_loaded (_, _) | Memory_facts_loaded (_, _))
  | Repository_msg (Repository_changes_loaded (_, _) | Repository_changes_diff_loaded (_, _))
  | File_changes_loaded (_, _) | Keeper_msg (Keeper_chat_file_changes_loaded (_, _, _))
  | Git_diff_loaded (_, _) | Browser_msg (Browser_history_list_loaded (_, _)
  | Browser_history_page_loaded (_, _) | Browser_lane_clients_loaded (_, _)
  | Browser_lane_loaded (_, _)
  | Browser_lane_follow_loaded (_, Error _)) | Connectors_msg (Connectors_status_loaded (_, _) | Connectors_loaded (_, _)
  | Connector_unbind_all_done _) | Tools_msg (Tools_volume_gc_reclaimed _) | Runtime_msg (Runtime_surface_loaded (_, _))
  | Tools_msg (Tools_read_loaded _)
  | Skill_evidence_loaded (_, _, _) | (Tools_msg (Tools_async_observation_loaded (_, _)) | ((Tools_msg (Tools_async_detail_loaded _) | Task_msg (Task_document_prepared _)) | Tools_msg (Tools_async_task_body_loaded _ | Tools_async_task_history_loaded _ | Tools_volume_gc_reported _)))
  | Runtime_msg (Runtime_lane_slots_written (_, _, _) | Runtime_catalog_loaded (_, _)
  | Runtime_assignment_changed (_, _, _))
  | Keeper_msg (Keeper_chat_approval_answered (_, _, _, _)
  | Keeper_tool_approvals_loaded (_, _, _)) | Ask_msg (Asks_reloaded _) | Keeper_msg (Keeper_roster_reloaded _ | Keeper_row_reloaded _) | Listen_prepared _ | Sent_image_ready _
  | Image_render_ready _ | Keeper_msg (Keeper_turns_loaded _ | Keeper_waiting_loaded _
  | Keeper_chat_control_received (_, _, _)) | Gate_msg (Gate_snapshot_loaded (_, _, _)
  | Gate_approval_resolved (_, _, _, _, _)
  | Gate_auto_judge_retried (_, _, _, _) | Gate_mode_set (_, _, _))
  | Keeper_msg (Keeper_tool_approval_answered (_, _, _, _, _, _)
  | Keeper_gate_settings_loaded _ | Keeper_tool_modes_loaded (_, _)
  | Keeper_tool_mode_set (_, _, _, _) | Keeper_chat_dispatch_blocked (_, _))
  | (Keeper_msg (Keeper_logs_loaded _ | Keeper_execute_streamed _)) | Runtime_msg (Runtime_form_save_changed _) | Keeper_msg (Keeper_settings_save_changed _ | Keeper_creation_changed _ | Keeper_action_done (_, _, _, _) | Keeper_memory_catch_up_done _) | Board_msg (Board_publication_done _ | Board_comment_done _) | (Board_msg (Board_vote_done _) | Artifact_msg (Artifact_check_changed _))
  | Goal_msg (Goal_transition_done _ | Goal_confirmation_submitted _
  | Goal_confirmation_loaded (_, _)) | Schedule_msg (Schedules_loaded (_, _)
  | Schedule_wake_history_loaded (_, _)) | Keeper_msg (Keeper_schedules_loaded (_, _) | Keeper_story_turns_loaded (_, _) | Keeper_memory_activity_loaded (_, _))
  | System_log_streamed _ | Schedule_msg (Schedule_cancel_done (_, _))
  | Verification_msg (Verification_verdict_done _) | Harness_msg (Harness_label_done _)
  | Board_msg (Board_attachment_loaded _ | Board_attachment_prepared _) | Chat_msg (Chat_call_loaded _) | Task_msg (Task_creation_read_done _) | Keeper_msg (Keeper_calls_loaded (_, _, _)) | Goal_msg (Goal_timeline_loaded (_, _) | Goal_candle_loaded (_, _))
  | Task_msg (Task_history_loaded (_, _) | Task_cancel_done (_, _, _))
  | Verification_msg (Verification_evidence_loaded (_, _) | Verification_evidence_exported _) | Keeper_msg (Keeper_settings_editor_loaded _ | Keeper_config_view_loaded (_, _)
  | Keeper_items_loaded (_, _) | Keeper_sandbox_view_loaded (_, _)
  | Keeper_sandbox_logs_loaded (_, _, _)) | Exact_msg (Exact_activity_read (_, _)
  | Exact_activity_saved (_, _)) | Machine_msg (Machine_activity_read (_, _)
  | Machine_activity_saved (_, _)) | Runtime_msg (Runtime_config_view_loaded (_, _, _, _, _)
  | Runtime_params_loaded _ | Runtime_param_written (_, _))
  | Prompts_loaded (_, _) | Keeper_msg (Keeper_board_quarantines_loaded (_, _) | Keeper_efficiency_loaded (_, _))
  | Board_msg (Board_quarantine_requeued (_, _, _)
  | Board_quarantines_bulk_progress (_, _, _, _, _, _)
  | Board_quarantines_bulk_requeued (_, _)) | Preset_msg (Presets_listed (_, _)
  | Preset_detail_loaded (_, _) | Preset_contents_shown (_, _)
  | Preset_saved (_, _) | Preset_restored (_, _) | Preset_deleted (_, _))
  | Play_msg (Play_room_received (_, _) | Play_invites_listed (_, _)
  | Play_invite_issued (_, _, _) | Play_invite_revoked (_, _, _, _))
  | Librarian_input_loaded (_, _) | (Resource_msg (Resources_listed _) | Artifact_msg (Artifact_checks_loaded _))
  | Board_msg (Board_attachment_saved _) | Acting_pane_changes_loaded (_, _)
  | Resource_msg (Resource_exported _ | Resource_saved _ | Resource_share_changed _ | Resource_share_recovery_loaded _ | Resource_read (_, _, _) | Resource_diagram_ready _)
  | Github_msg (Github_identity_view_loaded (_, _)) | Identity_msg (Identity_providers_loaded (_, _, _)
  | Identity_switch_set (_, _, _, _) | Identity_login_started (_, _)
  | Identity_refreshed (_, _) | Identity_app_saved (_, _, _)
  | Identity_disconnected (_, _, _))
  | Account_msg (Account_login_event (_, _, _) | Account_login_json (_, _, _, _)
  | Account_login_removal (_, _, _, _, _)) | Github_msg (Github_login_lines (_, _)
  | Github_login_finished (_, _) | Github_token_saved (_, _)) | Observer_msg (Observer_session_ready _ | Observer_opened _
  | Observer_received (_, _) | Observer_closed _ | Observer_retry_due _ | Observer_recovery_ready _ | Observer_recovery_identity _)
  | Task_msg (Task_dispatch_completed _) -> message
