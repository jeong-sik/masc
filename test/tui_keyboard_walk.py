from __future__ import annotations

from tui_keyboard_approvals import (
    KEEPER_ASK_ANSWER_PATH,
    VERIFICATION_QUEUE_PATH,
    approval_selection_identity_interaction,
    blocked_gate_detail_http_fixtures,
    blocked_gate_detail_interaction,
    concealed_input_detail_interaction,
    concealed_input_http_fixtures,
    escaped_question_detail_interaction,
    escaped_question_http_fixtures,
    gate_mode_picker_interaction,
    keeper_ask_answer_interaction,
    keeper_asks_response,
    question_reader_interaction,
    reject_editor_script,
    verification_snapshot,
    verification_verdict_fixtures,
    verification_verdict_interaction,
)
from tui_keyboard_board import (
    board_detail_authority_interaction,
    board_detail_isolation_interaction,
    board_paginated_detail_interaction,
    board_reference_http_fixtures,
    board_reference_interaction,
    board_selection_identity_interaction,
    run_board_json_regression,
)
from tui_keyboard_chat import (
    GRAPHICS_SUPPORTED_REPLY,
    AtomicChatFixture,
    bracketed_paste_interaction,
    chat_clarity_http_fixtures,
    chat_pending_stop_leave_interaction,
    chat_queue_interaction,
    chat_reconcile_http_fixtures,
    chat_reconcile_interaction,
    chat_steer_interaction,
    chat_visibility_modes_interaction,
    chat_working_target_interaction,
    clipboard_paste_key_interaction,
    composer_newline_interaction,
    image_view_interaction,
    keeper_calls_fixture,
    keeper_calls_interaction,
    keeper_chat_error_detail_interaction,
    keeper_chat_failed_response,
    keeper_message_missing_target_interaction,
    keeper_message_switch_http_fixtures,
    keeper_message_switch_interaction,
    keeper_message_unreliable_roster_interaction,
    live_markdown_history_fixture,
    live_markdown_interaction,
    message_origin_badge_interaction,
    message_origin_history_fixture,
    paste_into_a_field_interaction,
    paste_spill_interaction,
    paste_to_file_interaction,
    seed_image_workspace,
    seed_playground_workspace,
    task_dispatch_http_fixtures,
    task_dispatch_interaction,
    utf8_message_interaction,
    viewport_gap_history_fixture,
    viewport_gap_history_page_fixture,
    viewport_gap_interaction,
    word_delete_interaction,
)
from tui_keyboard_clients import (
    clients_footer_interaction,
    clients_http_fixtures,
)
from tui_keyboard_context import (
    context_inspector_interaction,
    run_context_inspector_transport_error_regression,
)
from tui_keyboard_dashboard import (
    attention_drawn_once_interaction,
    duplicated_attention_briefing,
    paused_and_stopped_briefing,
    paused_apart_from_stopped_interaction,
    unlisted_keepers_briefing,
    unlisted_keepers_named_interaction,
    unread_keeper_briefing,
    unread_keeper_counted_interaction,
)
from tui_keyboard_fusion import (
    fusion_http_fixtures,
    fusion_list_detail_interaction,
    fusion_live_reload_http_fixtures,
    fusion_live_reload_interaction,
    seed_goal_linked_task,
)
from tui_keyboard_harness import (
    BOARD_ID_DRAWN_COLS,
    KEEPER_ASKS_PATH,
    GatedHttpResponse,
    HttpRequests,
    RequestHttpResponse,
    approval_selection_http_fixtures,
    autonomous_turn_history_fixture,
    board_detail_authority_http_fixtures,
    board_detail_isolation_http_fixtures,
    board_paginated_detail_http_fixtures,
    board_selection_http_fixtures,
    context_inspector_fixtures,
    fleet_safety_fixture,
    keeper_runtime_http_fixtures,
    navigate_with_arrows_and_quit,
    overview_event_briefing,
    overview_event_http_fixtures,
    planning_selection_http_fixtures,
    row_budget_http_fixtures,
    run_terminal_scenario,
    seed_row_budget_workspace,
)
from tui_keyboard_keepers import (
    KEEPER_LANES_PATH,
    LANE_INVENTORY_PATH,
    acting_pane_ctrl_l_cycle_interaction,
    compact_input_gate_http_fixtures,
    hitl_lane_run_detail_response,
    hitl_lane_runs_response,
    keeper_detail_overscroll_interaction,
    keeper_gate_mode_footer_interaction,
    keeper_lane_row,
    keeper_lanes_ia_interaction,
    keeper_lanes_response,
    keeper_long_runtime_identity_interaction,
    keeper_runtime_phase_and_identity_interaction,
    keeper_selection_identity_interaction,
    lane_runs_path,
    pressing_a_row_chooses_then_opens_it,
    pressing_a_row_of_a_scrolled_list_opens_it,
    pressing_a_tab_opens_it,
    run_activity_logs_tab_pane_regression,
    run_keeper_info_requeue_key_regression,
    run_keeper_runtime_picker_filter_regression,
    run_keeper_unbind_all_channels_regression,
    run_pause_offers_channel_unbind_regression,
    run_tab_strip_keeps_current_entry_regression,
    seed_long_roster,
    standalone_lane_runtime_config_response,
    lane_inventory_response,
    verifier_lane_run_detail_response,
    verifier_lane_runs_response,
    wheel_scrolls_and_clicks_do_not,
)
from tui_keyboard_memory import (
    autonomous_turn_history_interaction,
    memory_facts_http_fixtures,
    memory_facts_interaction,
    run_memory_journal_regression,
)
from tui_keyboard_observer import (
    observer_feed_interaction,
    observer_http_fixtures,
)
from tui_keyboard_planning import (
    planning_missing_detail_interaction,
    planning_reorder_identity_interaction,
    planning_resize_budget_interaction,
    verification_unread_interaction,
)
from tui_keyboard_runtime import (
    RUNTIME_CONFIG_RAW_PATH,
    runtime_http_fixtures,
    runtime_surface_interaction,
)
from tui_keyboard_schedule import (
    schedule_detail_http_fixtures,
    schedule_detail_interaction,
)
from tui_keyboard_startup import (
    cli_base_path_overrides_environment_interaction,
)
from tui_keyboard_terminal import (
    assert_row_budgeted_surfaces,
    block_stderr_redirect,
    flow_control_is_off_interaction,
    interrupt_with_ctrl_c,
    quit_from_compact_message,
    repair_after_console_diagnostic,
    terminate_with_sigterm,
)
from tui_keyboard_workspace import (
    FILE_CHANGES_ALPHA_PATH,
    FILE_CHANGES_BETA_PATH,
    changes_keeper_and_arrow_detail_interaction,
    code_lane_fixtures,
    code_lane_interaction,
    enter_outside_changes_interaction,
    file_changes_alpha_response,
    file_changes_beta_response,
    run_code_memo_regression,
)


def run_chat_input_regression(executable: str) -> None:
    utf8_requests: HttpRequests = []
    to_file_requests: HttpRequests = []
    run_terminal_scenario(
        executable,
        description="A spilled paste is written where the keeper reads",
        interact=paste_to_file_interaction(to_file_requests),
        http_fixtures={
            "/api/v1/keepers/chat/stream": (
                503,
                {"error": "stop after the spill-to-file request capture"},
            )
        },
        http_requests=to_file_requests,
        prepare_workspace=seed_playground_workspace,
    )
    spill_requests: HttpRequests = []
    run_terminal_scenario(
        executable,
        description="A big paste is one line in the draft",
        interact=paste_spill_interaction(spill_requests),
        http_fixtures={
            "/api/v1/keepers/chat/stream": (
                503,
                {"error": "stop after the spill request capture"},
            )
        },
        http_requests=spill_requests,
    )
    paste_requests: HttpRequests = []
    run_terminal_scenario(
        executable,
        description="Bracketed paste is one draft",
        interact=bracketed_paste_interaction(paste_requests),
        http_fixtures={
            "/api/v1/keepers/chat/stream": (
                503,
                {"error": "stop after the paste request capture"},
            )
        },
        http_requests=paste_requests,
    )
    run_terminal_scenario(
        executable,
        description="A paste goes into the field taking characters",
        interact=paste_into_a_field_interaction(),
    )
    word_requests: HttpRequests = []
    run_terminal_scenario(
        executable,
        description="Ctrl-W and Alt+Backspace delete a word in the composer",
        interact=word_delete_interaction(word_requests),
        http_fixtures={
            "/api/v1/keepers/chat/stream": (
                503,
                {"error": "stop after the word-delete request capture"},
            )
        },
        http_requests=word_requests,
    )
    chat_queue = AtomicChatFixture()
    run_terminal_scenario(
        executable,
        description="Ordinary Enter reaches the server queue and edits retain identity",
        interact=chat_queue_interaction(chat_queue),
        http_fixtures=chat_queue.fixtures,
        refresh=0.2,
    )
    steer_requests: HttpRequests = []
    steer = AtomicChatFixture()
    run_terminal_scenario(
        executable,
        description="Enter during Esc waits for fresh acknowledgement, not model completion",
        interact=chat_steer_interaction(steer, steer_requests),
        http_fixtures=steer.fixtures,
        refresh=0.2,
        http_requests=steer_requests,
    )
    working = AtomicChatFixture(first_working=True)
    run_terminal_scenario(executable, description="Working direct execution outranks stale autonomous observer",
        interact=chat_working_target_interaction(working), http_fixtures=working.fixtures, refresh=0.2)
    pending = AtomicChatFixture(first_working=True)
    run_terminal_scenario(executable, description="Pending stop leaves chat without another interrupt",
        interact=chat_pending_stop_leave_interaction(pending), http_fixtures=pending.fixtures, refresh=0.2)
    reconcile_requests: HttpRequests = []
    reconcile_fixtures, reconcile_gate = chat_reconcile_http_fixtures()
    run_terminal_scenario(
        executable,
        description="Unknown admission reconnects by identity before later Enter",
        interact=chat_reconcile_interaction(reconcile_gate, reconcile_requests),
        http_fixtures=reconcile_fixtures,
        http_requests=reconcile_requests,
    )
    run_terminal_scenario(
        executable,
        description="UTF-8 message input",
        interact=utf8_message_interaction(utf8_requests),
        http_fixtures={
            "/api/v1/keepers/chat/stream": (
                503,
                {"error": "stop after UTF-8 request capture"},
            )
        },
        http_requests=utf8_requests,
    )


def run_keyboard_regression(executable: str, *, group: int | None = None) -> None:
    missing_target_requests: HttpRequests = []
    unreliable_roster_requests: HttpRequests = []
    keeper_scroll_fixtures = overview_event_http_fixtures()
    # The gate holds a refresh open so the scenario can resize while one is in
    # flight, so it has to sit on a request every refresh makes. The board list
    # is fetched only while the board is on screen, which the scenario is not,
    # so the briefing -- which every surface asks for -- carries the gate.
    keeper_scroll_gate = GatedHttpResponse((200, overview_event_briefing()))
    approval_fixtures, approval_items, approval_new = approval_selection_http_fixtures()
    planning_reorder_fixtures = planning_selection_http_fixtures()
    planning_missing_fixtures = planning_selection_http_fixtures()
    board_selection_fixtures = board_selection_http_fixtures()
    board_authority_fixtures, late_list = board_detail_authority_http_fixtures()
    board_detail_fixtures, b_failure = board_detail_isolation_http_fixtures()
    missing_target_fixtures, late_b = board_paginated_detail_http_fixtures()
    message_switch_fixtures, alpha_history = keeper_message_switch_http_fixtures()
    chat_visibility_fixtures = chat_clarity_http_fixtures()
    lanes_fixtures = keeper_runtime_http_fixtures()
    lanes_gate = GatedHttpResponse(
        keeper_lanes_response(
            [
                keeper_lane_row(
                    "alpha",
                    phase="running",
                    turn_phase="idle",
                    idle_seconds=75,
                    runtime_state="done",
                    selected_model="claude-opus-5",
                ),
                keeper_lane_row(
                    "beta",
                    phase="failing",
                    turn_phase="executing",
                    idle_seconds=3599,
                    runtime_state="done",
                    selected_model=None,
                    turn_healthy=False,
                ),
            ]
        )
    )
    lanes_fixtures[KEEPER_LANES_PATH] = lanes_gate
    lanes_fixtures[LANE_INVENTORY_PATH] = lane_inventory_response()
    lanes_fixtures[RUNTIME_CONFIG_RAW_PATH] = standalone_lane_runtime_config_response()
    lanes_fixtures[lane_runs_path("verifier_exact")] = verifier_lane_runs_response()
    lanes_fixtures[
        "/api/v1/dashboard/exact-lane-runs/vrf-fixture"
    ] = verifier_lane_run_detail_response()
    lanes_fixtures[lane_runs_path("hitl_auto_judge")] = hitl_lane_runs_response()
    lanes_fixtures[
        "/api/v1/dashboard/exact-lane-runs/hitl-fixture"
    ] = hitl_lane_run_detail_response()
    runtime_fixtures, runtime_initial_probe, runtime_force_probe = (
        runtime_http_fixtures()
    )
    schedule_fixtures = schedule_detail_http_fixtures()
    fusion_fixtures, fusion_initial_runs = fusion_http_fixtures()

    def run_general() -> None:
        run_terminal_scenario(
            executable,
            description="flow control leaves Ctrl-S to the key layer",
            interact=flow_control_is_off_interaction(),
        )
        run_terminal_scenario(
            executable,
            description="Image view over the frame",
            interact=image_view_interaction(),
            prepare_workspace=seed_image_workspace,
            preload_input=GRAPHICS_SUPPORTED_REPLY,
        )
        run_terminal_scenario(
            executable,
            description="Memory fact browser lists both stores and filters",
            interact=memory_facts_interaction(),
            http_fixtures=memory_facts_http_fixtures(),
        )
        run_terminal_scenario(
            executable,
            description="Autonomous turn history",
            interact=autonomous_turn_history_interaction(),
            http_fixtures={
                "/api/v1/keepers/alpha/chat/history": autonomous_turn_history_fixture(),
            },
            extra_args=("--reasoning", "full", "--tool-view", "full"),
        )
        run_memory_journal_regression(executable)
        run_terminal_scenario(
            executable,
            description="Keeper provider-input Context Inspector",
            interact=context_inspector_interaction(),
            http_fixtures=context_inspector_fixtures(),
        )
        run_context_inspector_transport_error_regression(executable)
        run_terminal_scenario(
            executable,
            description="Ctrl-V is not swallowed by the terminal",
            interact=clipboard_paste_key_interaction(),
            http_fixtures={
                "/api/v1/keepers/alpha/chat/history": (200, []),
            },
        )
        run_terminal_scenario(
            executable,
            description="Keeper chat visibility modes",
            interact=chat_visibility_modes_interaction(),
            http_fixtures=chat_visibility_fixtures,
        )
        error_detail_fixtures = keeper_runtime_http_fixtures()
        error_detail_fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])
        error_detail_fixtures["/api/v1/keepers/alpha/memory-journal?limit=20"] = (
            200,
            {"keeper": "alpha", "entries": []},
        )
        error_detail_fixtures["/api/v1/keepers/chat/stream"] = RequestHttpResponse(
            keeper_chat_failed_response
        )
        run_terminal_scenario(
            executable,
            description="Keeper chat errors preserve their complete detail",
            interact=keeper_chat_error_detail_interaction(),
            http_fixtures=error_detail_fixtures,
        )
        run_terminal_scenario(
            executable,
            description="Keeper message origin badges",
            interact=message_origin_badge_interaction,
            http_fixtures={
                "/api/v1/keepers/alpha/chat/history": message_origin_history_fixture(),
            },
        )
        run_terminal_scenario(
            executable,
            description="Keeper oversized viewport gap under NO_COLOR",
            interact=viewport_gap_interaction,
            http_fixtures={
                "/api/v1/keepers/alpha/chat/history": viewport_gap_history_fixture(),
                "/api/v1/keepers/alpha/chat/history/page": (
                    viewport_gap_history_page_fixture()
                ),
            },
            extra_env={"NO_COLOR": "1"},
        )
        run_terminal_scenario(
            executable,
            description="Keeper live Markdown code frame",
            interact=live_markdown_interaction,
            http_fixtures={
                "/api/v1/keepers/alpha/chat/history": live_markdown_history_fixture(),
            },
        )
        run_terminal_scenario(
            executable,
            description="Keeper message Ctrl-G switch",
            interact=keeper_message_switch_interaction(alpha_history),
            http_fixtures=message_switch_fixtures,
        )
        run_terminal_scenario(
            executable,
            description="Keepers operations and Standalone-only Lanes",
            interact=keeper_lanes_ia_interaction(lanes_gate, lanes_fixtures),
            http_fixtures=lanes_fixtures,
        )
        run_terminal_scenario(
            executable,
            description="Code lane lists, drills, and lexes",
            interact=code_lane_interaction,
            http_fixtures=code_lane_fixtures(),
        )
        run_code_memo_regression(executable)

    def run_surfaces() -> None:
        enter_split_fixtures = keeper_runtime_http_fixtures()
        enter_split_fixtures[FILE_CHANGES_ALPHA_PATH] = file_changes_alpha_response()
        run_terminal_scenario(
            executable,
            description="Enter off the Changes surface does not arm its diff",
            interact=enter_outside_changes_interaction,
            http_fixtures=enter_split_fixtures,
        )
        run_tab_strip_keeps_current_entry_regression(executable)
        run_keeper_unbind_all_channels_regression(executable)
        run_keeper_info_requeue_key_regression(executable)
        run_pause_offers_channel_unbind_regression(executable)
        run_keeper_runtime_picker_filter_regression(executable)
        run_activity_logs_tab_pane_regression(executable)
        changes_navigation_fixtures = keeper_runtime_http_fixtures()
        changes_navigation_fixtures[FILE_CHANGES_ALPHA_PATH] = file_changes_alpha_response()
        changes_navigation_fixtures[FILE_CHANGES_BETA_PATH] = file_changes_beta_response()
        # The v jump reads the row's file through the keeper axis; both query
        # encodings of the slash are served, as the workspace fixtures do.
        code_children = (
            200,
            [
                {"path": "repos/masc/lib/example.ml", "label": "example.ml",
                 "depth": 0, "parent": "repos/masc/lib", "hasChildren": False,
                 "diff": None, "keeperId": None, "hueIndex": None},
            ],
        )
        code_file = (200, {"ok": True, "content": "let a = 2\n"})
        for children_path in (
            "/api/v1/workspace/children?path=repos/masc/lib&limit=2000&keeper=alpha",
            "/api/v1/workspace/children?path=repos%2Fmasc%2Flib&limit=2000&keeper=alpha",
        ):
            changes_navigation_fixtures[children_path] = code_children
        for file_path in (
            "/api/v1/workspace/file?path=repos/masc/lib/example.ml&keeper=alpha",
            "/api/v1/workspace/file?path=repos%2Fmasc%2Flib%2Fexample.ml&keeper=alpha",
        ):
            changes_navigation_fixtures[file_path] = code_file
        run_terminal_scenario(
            executable,
            description="Changes keeper switch and arrow detail navigation",
            interact=changes_keeper_and_arrow_detail_interaction,
            http_fixtures=changes_navigation_fixtures,
        )
        gate_mode_fixtures = keeper_runtime_http_fixtures()
        gate_mode_gate = GatedHttpResponse(
            (200, {"overrides": [{"keeper": "alpha", "mode": "yolo"}]}),
            subsequent_response=(
                200,
                {"overrides": [{"keeper": "alpha", "mode": "yolo"}]},
            ),
            hold_seconds=15.0,
        )
        gate_mode_fixtures["/api/v1/keepers/tool-approval-mode"] = gate_mode_gate
        run_terminal_scenario(
            executable,
            description="Keeper gate footer offers Auto from YOLO",
            interact=keeper_gate_mode_footer_interaction(gate_mode_gate),
            http_fixtures=gate_mode_fixtures,
        )
        run_terminal_scenario(
            executable,
            description="Runtime lane candidates from joined projections",
            interact=runtime_surface_interaction(
                runtime_fixtures,
                runtime_initial_probe,
                runtime_force_probe,
            ),
            refresh=0.05,
            http_fixtures=runtime_fixtures,
            # The probe's checked-at is drawn in the terminal's zone; UTC keeps the
            # expected "2026-08-24 10:20:00" the same on every machine.
            extra_env={"TZ": "UTC"},
        )
        run_terminal_scenario(
            executable,
            description="Schedule operational detail and page navigation",
            interact=schedule_detail_interaction(),
            http_fixtures=schedule_fixtures,
            # The recorded times are drawn in the terminal's zone; UTC keeps the
            # expected "2026-08-25 09:30:20" the same on every machine.
            extra_env={"TZ": "UTC"},
        )
        run_terminal_scenario(
            executable,
            description="Fusion list identity and panel-to-judge detail",
            interact=fusion_list_detail_interaction(
                fusion_fixtures,
                fusion_initial_runs,
            ),
            refresh=0.05,
            http_fixtures=fusion_fixtures,
            # The harness verdict in these fixtures judges task-linked-501. Seeding
            # that task and the goal it serves is what lets the detail say what the
            # verdict was aiming at, rather than naming a task and stopping.
            prepare_workspace=seed_goal_linked_task,
        )
        fusion_live_fixtures, fusion_mcp_gate, fusion_run_list = fusion_live_reload_http_fixtures()
        run_terminal_scenario(
            executable,
            description="Fusion live reload on an observer status push",
            interact=fusion_live_reload_interaction(fusion_run_list, fusion_mcp_gate),
            http_fixtures=fusion_live_fixtures,
        )
        run_terminal_scenario(
            executable,
            description="Keeper tool-call log",
            interact=keeper_calls_interaction(),
            http_fixtures={
                "/api/v1/keepers/alpha/tool-calls?limit=100": keeper_calls_fixture(),
            },
        )
        verification_gate = GatedHttpResponse((200, verification_snapshot([])))
        run_terminal_scenario(
            executable,
            description="Verification unread before read",
            interact=verification_unread_interaction(verification_gate),
            http_fixtures={
                VERIFICATION_QUEUE_PATH: verification_gate,
            },
        )

    def run_overview() -> None:
        verdict_requests: HttpRequests = []
        with reject_editor_script() as reject_editor:
            run_terminal_scenario(
                executable,
                description="Verification verdict keys",
                interact=verification_verdict_interaction(verdict_requests),
                http_fixtures=verification_verdict_fixtures(),
                http_requests=verdict_requests,
                extra_env={"EDITOR": reject_editor},
            )
        observer_requests: HttpRequests = []
        run_terminal_scenario(
            executable,
            description="Observer feed subscription",
            interact=observer_feed_interaction(observer_requests),
            http_fixtures=observer_http_fixtures(),
            http_requests=observer_requests,
        )
        dispatch_requests: HttpRequests = []
        run_terminal_scenario(
            executable,
            description="Composer task dispatch",
            interact=task_dispatch_interaction(dispatch_requests),
            http_fixtures=task_dispatch_http_fixtures(),
            http_requests=dispatch_requests,
        )
        run_terminal_scenario(
            executable,
            description="Attention drawn once",
            interact=attention_drawn_once_interaction(),
            http_fixtures={
                "/api/v1/dashboard/briefing": duplicated_attention_briefing(),
            },
        )
        run_terminal_scenario(
            executable,
            description="Unread keeper counted",
            interact=unread_keeper_counted_interaction(),
            http_fixtures={
                "/api/v1/dashboard/briefing": unread_keeper_briefing(),
            },
        )
        run_terminal_scenario(
            executable,
            description="Unlisted keepers named",
            interact=unlisted_keepers_named_interaction(),
            http_fixtures={
                "/api/v1/dashboard/briefing": unlisted_keepers_briefing(),
            },
        )
        run_terminal_scenario(
            executable,
            description="Paused apart from stopped",
            interact=paused_apart_from_stopped_interaction(),
            http_fixtures={
                "/api/v1/dashboard/briefing": paused_and_stopped_briefing(),
            },
        )
        composer_requests: HttpRequests = []
        run_terminal_scenario(
            executable,
            description="Composer newline and send",
            interact=composer_newline_interaction(composer_requests),
            http_fixtures={
                "/health?full=1": fleet_safety_fixture(),
                "/api/v1/keepers/chat/stream": (
                    503,
                    {"error": "stop after composer request capture"},
                ),
            },
            http_requests=composer_requests,
        )
        run_terminal_scenario(
            executable,
            description="Keeper detail overscroll normalization",
            interact=keeper_detail_overscroll_interaction(
                keeper_scroll_fixtures,
                keeper_scroll_gate,
            ),
            http_fixtures=keeper_scroll_fixtures,
        )

    def run_rosters() -> None:
        run_terminal_scenario(
            executable,
            description="Keeper selection identity",
            interact=keeper_selection_identity_interaction,
            http_fixtures=overview_event_http_fixtures(),
            prepare_workspace=block_stderr_redirect,
        )
        run_terminal_scenario(
            executable,
            description="CLI base path overrides inherited environment",
            interact=cli_base_path_overrides_environment_interaction,
            http_fixtures=overview_event_http_fixtures(),
            conflicting_env_base_path=True,
        )
        run_terminal_scenario(
            executable,
            description="Keeper message unreliable roster",
            interact=keeper_message_unreliable_roster_interaction(
                unreliable_roster_requests
            ),
            refresh=0.05,
            http_fixtures=overview_event_http_fixtures(),
            http_requests=unreliable_roster_requests,
            prepare_workspace=block_stderr_redirect,
        )
        run_terminal_scenario(
            executable,
            description="Keeper message missing target",
            interact=keeper_message_missing_target_interaction(missing_target_requests),
            refresh=0.05,
            http_fixtures=overview_event_http_fixtures(),
            http_requests=missing_target_requests,
        )
        run_terminal_scenario(
            executable,
            description="approval selection identity",
            interact=approval_selection_identity_interaction(
                approval_fixtures,
                approval_items,
                approval_new,
            ),
            http_fixtures=approval_fixtures,
        )
        run_terminal_scenario(
            executable,
            description="Planning preserves selected goals and footer across resize",
            interact=planning_resize_budget_interaction,
            http_fixtures=planning_selection_http_fixtures(),
        )
        run_terminal_scenario(
            executable,
            description="Planning selection identity",
            interact=planning_reorder_identity_interaction(planning_reorder_fixtures),
            http_fixtures=planning_reorder_fixtures,
        )
        run_terminal_scenario(
            executable,
            description="Planning missing detail recovery",
            interact=planning_missing_detail_interaction(planning_missing_fixtures),
            http_fixtures=planning_missing_fixtures,
        )
        run_terminal_scenario(
            executable,
            description="Clients draws its footer and an armed search",
            interact=clients_footer_interaction,
            http_fixtures=clients_http_fixtures(),
        )
        run_terminal_scenario(
            executable,
            description="Clients keeps its footer while a crowded roster resizes",
            interact=clients_footer_interaction,
            http_fixtures=clients_http_fixtures(extra_clients=40),
        )

    def run_board_terminal() -> None:
        board_reference_fixtures = board_reference_http_fixtures()
        keeper_ask_fixtures, _ask_initial, _ask_new = approval_selection_http_fixtures()
        keeper_ask_fixtures[KEEPER_ASKS_PATH] = keeper_asks_response()
        keeper_ask_fixtures[KEEPER_ASK_ANSWER_PATH] = (200, {"ok": True})
        ask_requests: HttpRequests = []
        run_terminal_scenario(
            executable,
            description="Blocked Gate reason remains whole in approval detail",
            interact=blocked_gate_detail_interaction(),
            http_fixtures=blocked_gate_detail_http_fixtures(),
        )
        run_terminal_scenario(
            executable,
            description="A concealing escape in the input draws as text in approval detail",
            interact=concealed_input_detail_interaction(),
            http_fixtures=concealed_input_http_fixtures(),
        )
        run_terminal_scenario(
            executable,
            description="A cursor escape in a held call's question draws as text in approval detail",
            interact=escaped_question_detail_interaction(),
            http_fixtures=escaped_question_http_fixtures(),
        )
        run_terminal_scenario(
            executable,
            description="Answering a Keeper's question from an approval detail",
            interact=keeper_ask_answer_interaction(keeper_ask_fixtures, ask_requests),
            http_fixtures=keeper_ask_fixtures,
            http_requests=ask_requests,
        )
        reader_fixtures, _, _ = approval_selection_http_fixtures()
        reader_fixtures[KEEPER_ASKS_PATH] = keeper_asks_response(long_question=True)
        reader_fixtures[KEEPER_ASK_ANSWER_PATH] = (200, {"ok": True})
        reader_requests: HttpRequests = []
        run_terminal_scenario(
            executable,
            description="Question arrows, overflow and visible free-text editing",
            interact=question_reader_interaction(reader_requests),
            http_fixtures=reader_fixtures,
            http_requests=reader_requests,
        )
        mode_fixtures = blocked_gate_detail_http_fixtures()
        mode_fixtures["/api/v1/dashboard/gate/mode"] = (200, {"ok": True})
        mode_fixtures["/api/v1/dashboard/gate/external-mode"] = (200, {"ok": True})
        mode_requests: HttpRequests = []
        run_terminal_scenario(
            executable,
            description="Gate mode chooser applies only after Enter",
            interact=gate_mode_picker_interaction(mode_requests),
            http_fixtures=mode_fixtures,
            http_requests=mode_requests,
        )
        run_terminal_scenario(
            executable,
            description="Board references and related posts",
            interact=board_reference_interaction(board_reference_fixtures),
            http_fixtures=board_reference_fixtures,
        )
        run_board_json_regression(executable)
        run_terminal_scenario(
            executable,
            description="Board selection identity",
            interact=board_selection_identity_interaction(board_selection_fixtures),
            http_fixtures=board_selection_fixtures,
        )
        run_terminal_scenario(
            executable,
            description="Board detail post authority",
            interact=board_detail_authority_interaction(
                board_authority_fixtures,
                late_list,
            ),
            http_fixtures=board_authority_fixtures,
            terminal_cols=BOARD_ID_DRAWN_COLS,
        )
        run_terminal_scenario(
            executable,
            description="Board detail isolation",
            interact=board_detail_isolation_interaction(b_failure),
            http_fixtures=board_detail_fixtures,
            terminal_cols=BOARD_ID_DRAWN_COLS,
        )
        run_terminal_scenario(
            executable,
            description="Board exact detail survives page omission",
            interact=board_paginated_detail_interaction(missing_target_fixtures, late_b),
            http_fixtures=missing_target_fixtures,
            terminal_cols=BOARD_ID_DRAWN_COLS,
        )
        run_terminal_scenario(
            executable,
            description="row-budgeted Overview and Board",
            interact=assert_row_budgeted_surfaces,
            http_fixtures=row_budget_http_fixtures(),
            prepare_workspace=seed_row_budget_workspace,
        )
        run_terminal_scenario(
            executable,
            description="console diagnostic repair",
            interact=repair_after_console_diagnostic,
            prepare_workspace=block_stderr_redirect,
            refresh=0.05,
        )
        run_terminal_scenario(
            executable,
            description="Keeper phase and runtime identity",
            interact=keeper_runtime_phase_and_identity_interaction,
            http_fixtures=keeper_runtime_http_fixtures(),
        )
        run_terminal_scenario(
            executable,
            description="Ctrl-L walks the Activity pane narrow, wide, hidden",
            interact=acting_pane_ctrl_l_cycle_interaction,
        )
        run_terminal_scenario(
            executable,
            description="Keeper long runtime identities remain distinguishable",
            interact=keeper_long_runtime_identity_interaction,
            http_fixtures=keeper_runtime_http_fixtures(
                alpha_runtime_id="antigravity_subscription.gemini-3-7-flash-thinking-preview",
                beta_runtime_id="antigravity_subscription.gemini-3-7-flash-thinking-lite",
            ),
        )
        run_terminal_scenario(
            executable,
            description="q",
            interact=navigate_with_arrows_and_quit,
        )
        run_terminal_scenario(
            executable,
            description="wheel scrolls, clicks do not",
            interact=wheel_scrolls_and_clicks_do_not,
            http_fixtures=compact_input_gate_http_fixtures(),
        )
        run_terminal_scenario(
            executable,
            description="pressing a tab opens it",
            interact=pressing_a_tab_opens_it,
        )
        run_terminal_scenario(
            executable,
            description="pressing a row chooses, then opens it",
            interact=pressing_a_row_chooses_then_opens_it,
            # This pointer scenario waits for the error row before measuring
            # click coordinates; the Overview's successful empty roster would
            # remove that row and change the fixture's layout contract.
            http_fixtures={
                **compact_input_gate_http_fixtures(),
                "/api/v1/gate/keepers?detailed=true": (
                    503, {"error": "fixture endpoint unavailable"}
                ),
            },
        )
        run_terminal_scenario(
            executable,
            description="pressing a row of a scrolled list opens it",
            interact=pressing_a_row_of_a_scrolled_list_opens_it,
            # This pointer scenario waits for the error row before measuring
            # click coordinates; the Overview's successful empty roster would
            # remove that row and change the fixture's layout contract.
            http_fixtures={
                **compact_input_gate_http_fixtures(),
                "/api/v1/gate/keepers?detailed=true": (
                    503, {"error": "fixture endpoint unavailable"}
                ),
            },
            prepare_workspace=seed_long_roster,
        )
        run_terminal_scenario(
            executable,
            description="compact q",
            interact=quit_from_compact_message,
        )
        run_terminal_scenario(
            executable,
            description="Ctrl-C",
            interact=interrupt_with_ctrl_c,
            confirm_exit=b"\x03",
        )
        # No confirming key: the signal is the whole exit.
        run_terminal_scenario(
            executable,
            description="SIGTERM",
            interact=terminate_with_sigterm,
            confirm_exit=b"",
        )

    groups = (run_general, run_surfaces, run_overview, run_rosters, run_board_terminal)
    if group is None:
        for run in groups:
            run()
    else:
        groups[group]()
