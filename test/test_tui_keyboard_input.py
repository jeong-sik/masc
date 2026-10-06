from __future__ import annotations

import sys
from functools import partial

# Explicit compatibility exports required by tracked standalone PTY/capture consumers.
from tui_keyboard_chat import (
    AtomicChatFixture as AtomicChatFixture,
    IMAGE_NAME as IMAGE_NAME,
    keeper_chat_succeeded_response as keeper_chat_succeeded_response,
    open_atomic_chat as open_atomic_chat,
    seed_image_workspace as seed_image_workspace,
    unwrapped as unwrapped,
)
from tui_keyboard_harness import (
    DASHBOARD_GOALS_PATH as DASHBOARD_GOALS_PATH,
    PLANNING_PATH as PLANNING_PATH,
    RUNTIME_RESOLVED_PATH as RUNTIME_RESOLVED_PATH,
    board_detail_comment as board_detail_comment,
    board_selection_post as board_selection_post,
    composer_showing as composer_showing,
    copy_reference as copy_reference,
    empty_runtime_resolved_fixture as empty_runtime_resolved_fixture,
    escape_to_keeper_detail as escape_to_keeper_detail,
    fixture_cell_width as fixture_cell_width,
    path_without_masc as path_without_masc,
    planning_goal as planning_goal,
    planning_snapshot as planning_snapshot,
    press_and_settle as press_and_settle,
    row_budget_http_fixtures as row_budget_http_fixtures,
    screen_row_of as screen_row_of,
    seed_row_budget_workspace as seed_row_budget_workspace,
    seed_workspace as seed_workspace,
    test_http_endpoint as test_http_endpoint,
    tab_until as tab_until,
    wait_for_http_request as wait_for_http_request,
    with_workspace_identity as with_workspace_identity,
)
from tui_keyboard_repositories import (
    REPOSITORIES_PATH as REPOSITORIES_PATH,
    repositories_fixture as repositories_fixture,
)
from tui_keyboard_runtime import (
    runtime_resolved_response as runtime_resolved_response,
    runtime_resolved_runtime as runtime_resolved_runtime,
)
from tui_keyboard_schedule import (
    SCHEDULES_PATH as SCHEDULES_PATH,
    schedule_detail_http_fixtures as schedule_detail_http_fixtures,
)
from tui_keyboard_workspace import (
    FILE_CHANGES_ALPHA_PATH as FILE_CHANGES_ALPHA_PATH,
    code_lane_fixtures as code_lane_fixtures,
    file_changes_alpha_response as file_changes_alpha_response,
    open_changes as open_changes,
)

from tui_keyboard_board import (
    run_board_compose_footer_regression,
    run_board_json_regression,
    run_board_list_footer_regression,
)
from tui_keyboard_browser import (
    run_browser_client_picker_regression,
    run_browser_scene_regression,
    run_browser_screenshot_regression,
)
from tui_keyboard_chat import (
    GRAPHICS_SUPPORTED_REPLY as GRAPHICS_SUPPORTED_REPLY,
    run_chat_clarity_regression,
    run_chat_retained_stop_regression,
    run_mermaid_chat_regression,
    run_quit_waiting_regression,
)
from tui_keyboard_dashboard import (
    run_dashboard_usage_regression,
)
from tui_keyboard_fusion import (
    run_fusion_history_regression,
)

# Tracked capture/profile scripts use this public helper surface. Keep
# explicit exports while the family registry delegates implementation to owners.
from tui_keyboard_harness import (
    COMPOSER_FOCUSED as COMPOSER_FOCUSED,
    CSI_RE as CSI_RE,
    FRAME_END as FRAME_END,
    FULL_REDRAW as FULL_REDRAW,
    HttpRequests as HttpRequests,
    PathHttpResponse as PathHttpResponse,
    RequestHttpResponse as RequestHttpResponse,
    WINDOW_TEXT_RE as WINDOW_TEXT_RE,
    configure_child_terminal as configure_child_terminal,
    drain_until_quiet as drain_until_quiet,
    end_of_needle as end_of_needle,
    find_needle as find_needle,
    keeper_metadata as keeper_metadata,
    keeper_row_selected as keeper_row_selected,
    keeper_runtime_http_fixtures as keeper_runtime_http_fixtures,
    overview_event_http_fixtures as overview_event_http_fixtures,
    palette_go as palette_go,
    read_available as read_available,
    resize_and_wait as resize_and_wait,
    run_terminal_scenario as run_terminal_scenario,
    screen_rows as screen_rows,
    screen_text as screen_text,
    select_keeper_row as select_keeper_row,
    send_and_wait as send_and_wait,
    wait_for_fixture_event as wait_for_fixture_event,
    wait_for_fixture_state as wait_for_fixture_state,
    wait_for_output as wait_for_output,
    write_all as write_all,
    ScenarioFamily,
    main,
)
from tui_keyboard_keepers import (
    CONNECTORS_PATH as CONNECTORS_PATH,
    CONNECTOR_NAMES_PATH as CONNECTOR_NAMES_PATH,
    run_keeper_lanes_regression,
    run_keeper_settings_activation_regression,
)
from tui_keyboard_machines import (
    run_dos_live_regression,
    run_msx_background_poll_regression,
    run_msx_palette_regression,
    run_msx_retained_regression,
    run_msx_size_regression,
    run_msx_spectator_regression,
)
from tui_keyboard_memory import (
    run_memory_journal_regression,
)
from tui_keyboard_observer import (
    run_acting_call_evidence_regression,
    run_http_badge_refresh_regression,
    run_http_conditional_read_regression,
    run_observer_reconnect_regression,
)
from tui_keyboard_planning import (
    run_planning_review_regression,
)
from tui_keyboard_repositories import (
    run_project_changes_regression,
    run_repositories_regression,
)
from tui_keyboard_resources import run_resources_regression
from tui_keyboard_runtime import (
    run_config_regression,
    run_held_back_override_regression,
    run_prompts_refresh_failure_keeps_catalog_regression,
    run_runtime_regression,
)
from tui_keyboard_schedule import (
    run_schedule_delivery_regression,
    run_schedule_source_status_regression,
)
from tui_keyboard_startup import (
    run_cli_base_path_regression,
    run_ctrl_y_regression,
    run_exit_reason_regression,
    run_first_install_credential_regression,
)
from tui_keyboard_terminal import (
    run_theme_scheme_regression,
)
from tui_keyboard_tools import (
    run_skill_catalog_error_regression,
    run_skill_usage_coverage_regression,
    run_tools_purpose_regression,
    run_tools_request_identity_regression,
)
from tui_keyboard_voice import (
    run_send_on_stop_regression,
    run_voice_scroll_regression,
    run_voice_wizard_regression,
)
from tui_keyboard_walk import run_keyboard_regression
from tui_keyboard_workspace import (
    run_changes_newline_regression,
    run_code_memo_regression,
)

KEYBOARD_FAMILY = ScenarioFamily(
    "keyboard", "keyboard PTY regression", (run_keyboard_regression,)
)

# Named families and keyboard scenario shards have their own Dune rules.
SCENARIO_FAMILIES: tuple[ScenarioFamily, ...] = (
    KEYBOARD_FAMILY,
    ScenarioFamily(
        "dashboard-usage",
        "Dashboard and Usage regression",
        (run_dashboard_usage_regression,),
    ),
    ScenarioFamily(
        "fusion-history",
        "historical Fusion inspection",
        (run_fusion_history_regression,),
    ),
    ScenarioFamily(
        "cli-base-path", "CLI base-path regression", (run_cli_base_path_regression,)
    ),
    ScenarioFamily(
        "send-on-stop", "send_on_stop regression", (run_send_on_stop_regression,)
    ),
    ScenarioFamily(
        "chat-retained-stop",
        "stopped chat input retained regression",
        (run_chat_retained_stop_regression,),
    ),
    ScenarioFamily(
        "quit-waiting",
        "quit with waiting messages regression",
        (run_quit_waiting_regression,),
    ),
    ScenarioFamily("ctrl-y", "Ctrl-Y regression", (run_ctrl_y_regression,)),
    ScenarioFamily(
        "first-install-credential",
        "first install credential regression",
        (run_first_install_credential_regression,),
    ),
    ScenarioFamily(
        "exit-reason",
        "exit reason regression",
        (run_exit_reason_regression,),
    ),
    ScenarioFamily(
        "planning-review",
        "Planning Task Review regression",
        (run_planning_review_regression,),
    ),
    ScenarioFamily(
        "repositories", "Repositories regression", (run_repositories_regression,)
    ),
    ScenarioFamily(
        "project-changes",
        "project Git changes regression",
        (run_project_changes_regression,),
    ),
    ScenarioFamily(
        "browser-screenshot",
        "Browser screenshot regression",
        (
            run_browser_screenshot_regression,
            run_browser_client_picker_regression,
            run_browser_scene_regression,
        ),
    ),
    ScenarioFamily("config", "Config regression", (run_config_regression,)),
    ScenarioFamily(
        "voice-wizard",
        "Voice wizard regression",
        (run_voice_wizard_regression, run_voice_scroll_regression),
    ),
    ScenarioFamily(
        "held-back-override",
        "held-back override regression",
        (
            run_held_back_override_regression,
            run_prompts_refresh_failure_keeps_catalog_regression,
        ),
    ),
    ScenarioFamily(
        "theme-scheme", "theme scheme regression", (run_theme_scheme_regression,)
    ),
    ScenarioFamily(
        "msx-palette", "MSX palette regression", (run_msx_palette_regression,)
    ),
    ScenarioFamily(
        "msx-spectator", "MSX spectator regression", (run_msx_spectator_regression,)
    ),
    ScenarioFamily(
        "msx-retained", "MSX retained pixels regression", (run_msx_retained_regression,)
    ),
    ScenarioFamily(
        "msx-retained-tick",
        "MSX retained pixels over tick regression",
        (partial(run_msx_retained_regression, retained_tick=True),),
    ),
    ScenarioFamily(
        "msx-background-poll",
        "MSX background poll regression",
        (run_msx_background_poll_regression,),
    ),
    ScenarioFamily("msx-size", "MSX size regression", (run_msx_size_regression,)),
    ScenarioFamily(
        "dos-live", "DOS live spectator regression", (run_dos_live_regression,)
    ),
    ScenarioFamily(
        "board-compose-footer",
        "board compose footer regression",
        (run_board_list_footer_regression, run_board_compose_footer_regression),
    ),
    ScenarioFamily(
        "schedule-delivery",
        "schedule delivery regression",
        (run_schedule_delivery_regression,),
    ),
    ScenarioFamily(
        "schedule-source-status",
        "schedule source status regression",
        (run_schedule_source_status_regression,),
    ),
    ScenarioFamily(
        "changes-newline",
        "Changes newline projection regression",
        (run_changes_newline_regression,),
    ),
    ScenarioFamily(
        "mermaid-chat", "mermaid chat regression", (run_mermaid_chat_regression,)
    ),
    ScenarioFamily(
        "chat-clarity", "chat clarity regression", (run_chat_clarity_regression,)
    ),
    ScenarioFamily("runtime", "Runtime regression", (run_runtime_regression,)),
    ScenarioFamily("resources", "Resources regression", (run_resources_regression,)),
    ScenarioFamily(
        "keepers-lanes", "Keepers/Lanes regression", (run_keeper_lanes_regression,)
    ),
    ScenarioFamily(
        "keeper-settings-activation",
        "Keeper settings activation regression",
        (run_keeper_settings_activation_regression,),
    ),
    ScenarioFamily("board-json", "Board JSON regression", (run_board_json_regression,)),
    ScenarioFamily("code-memo", "Code memo regression", (run_code_memo_regression,)),
    ScenarioFamily(
        "memory-journal", "Memory journal regression", (run_memory_journal_regression,)
    ),
    ScenarioFamily(
        "skill-usage-coverage",
        "Skill usage coverage regression",
        (run_skill_usage_coverage_regression, run_skill_catalog_error_regression),
    ),
    ScenarioFamily(
        "tools-request-identity",
        "Tools request identity regression",
        (run_tools_request_identity_regression,),
    ),
    ScenarioFamily(
        "tools-purpose", "Tools purpose regression", (run_tools_purpose_regression,)
    ),
    ScenarioFamily(
        "http-badge-refresh",
        "HTTP badge refresh timing regression",
        (run_http_badge_refresh_regression,),
    ),
    ScenarioFamily(
        "http-conditional-read",
        "HTTP conditional read regression",
        (run_http_conditional_read_regression,),
    ),
    ScenarioFamily(
        "observer-reconnect",
        "observer reconnect regression",
        (run_observer_reconnect_regression,),
    ),
    ScenarioFamily(
        "acting-call-evidence",
        "Acting call evidence regression",
        (run_acting_call_evidence_regression,),
    ),
)


if __name__ == "__main__":
    main(sys.argv[1:], SCENARIO_FAMILIES, KEYBOARD_FAMILY)
