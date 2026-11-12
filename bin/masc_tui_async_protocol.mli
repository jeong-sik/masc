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
(** A provider history answer and the TUI clock when its request started. The
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

(** What a memory health read answered: the fleet, or one Keeper's row
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
      (** The last field identifies only input held when this resume began. *)
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
      (** The whole roster read on its own, after a change or a failure. *)
  | Keeper_row_reloaded of keeper_row_observation
      (** One Keeper's row read on its own, after the server named it. *)
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
      (** A schedule create/modify form refused by the workspace guard: the
          guard's withdrawal, then the refusal kept on the Schedules surface. *)
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
  (** Diagnostic reader status; it grants no data or action authority. *)
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
      (** The original submission owns the published receipt; this message only
          asks the loop to observe it. *)
  | Ask_followup_observed of ask_followup_read * Masc.Tui_decode_asks.ask_followup_event * int64
  | Ask_followup_finished of ask_followup_read * Masc_tui_ask_projection.followup_result
  (** A workspace-bound roster can settle before unrelated readers. *)
  (* The answer that came back, and the list re-read behind it. The store
     settles on first write, so the response says what was actually recorded
     -- which may be someone else's answer. The submission carries the original
     workspace, Keeper, Ask and human label; none is recovered from prose. *)
  | Ask_answer_done of
      ask_submission
      * (Masc.Tui_decode_asks.answer_receipt, string) result
      * (Masc.Tui_decode_asks.asks_snapshot, string) result
  | Asks_reloaded of asks_observation
      (** The questions read again on their own, after a change or a failure. *)

type approvals_msg =
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
  | Board_publication_done of
      Masc_tui_types.workspace_authority Masc_tui_board_publication.outcome
  | Board_comment_done of {
      request_id : board_comment_request_id;
      post_id : string;
      sent_draft : string;
      result : (string, string) result;
    }
  | Board_vote_done of Masc_tui_types.board_vote_target * (string, string) result
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
val message_waits_for_input :
  resource_read:(Masc_tui_resource_catalog.read_request -> bool) ->
  recovery_loaded:(Masc_tui_types.resource_share_recovery_lookup -> bool) ->
  async_msg -> bool
val workspace_message_admitted :
  state -> authority:workspace_authority -> reading:unit ref option -> async_msg -> bool
(** A stale read never re-enters a reconfirmed workspace. Admitted operation
    and chat receipts keep their original workspace authority. *)

val observer_stream_owned : state -> unit ref -> bool
val observer_retry_owned : state -> authority:workspace_authority -> unit ref -> bool
val observer_recovery_owned : state -> authority:workspace_authority -> unit ref -> bool
val observer_recovery_identity_owned :
  state -> authority:workspace_authority -> owner:unit ref -> live:bool ref ->
  instance:string -> origin:observer_recovery_origin -> bool
(** A retry belongs only to the workspace and exact closed stream that scheduled it. *)

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
