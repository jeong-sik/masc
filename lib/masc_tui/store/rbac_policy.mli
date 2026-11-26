(** Exhaustive TUI RBAC policy mapping every {!Cmd} effect, SSE stream,
    navigation surface, inline modal, and slash command onto {!Rbac.route_access}
    with zero catch-all matches. *)

open Masc_tui_core
open Masc_tui_keymap

val route_access_of_get_request : Cmd.get_request -> Rbac.route_access
val route_access_of_post_request : Cmd.post_request -> Rbac.route_access
val route_access_of_put_request : Cmd.put_request -> Rbac.route_access
val route_access_of_delete_request : Cmd.delete_request -> Rbac.route_access
val route_access_of_stream_post_request : Cmd.stream_post_request -> Rbac.route_access
val route_access_of_editor_target : Cmd.editor_target -> Rbac.route_access
val route_access_of_stream_id : Subscriptions.stream_id -> Rbac.route_access

val route_access_of_workspace : Nav.workspace -> Rbac.route_access
val route_access_of_work_tab : Nav.work_tab -> Rbac.route_access
val route_access_of_knowledge_tab : Nav.knowledge_tab -> Rbac.route_access
val route_access_of_keeper_tab : Nav.keeper_tab -> Rbac.route_access
val route_access_of_runtime_tab : Nav.runtime_tab -> Rbac.route_access
val route_access_of_infra_tab : Nav.infra_tab -> Rbac.route_access
val route_access_of_inspector : Nav.inspector -> Rbac.route_access
val route_access_of_inline_action : Nav.inline_action_kind -> Rbac.route_access
val route_access_of_overlay : Nav.overlay -> Rbac.route_access
val route_access_of_menu_target : Nav.menu_target -> Rbac.route_access

val route_access_of_slash_command_id : Slash.command_id -> Rbac.route_access
val route_access_of_slash_parsed : Slash.parsed -> Rbac.route_access
val route_access_of_keymap_action : Keymap.action -> Rbac.route_access

val decide_keymap_action :
  Rbac.auth_session -> Keymap.action -> Rbac.access_verdict
val can_run_keymap_action : Rbac.auth_session -> Keymap.action -> bool

val decide_get : Rbac.auth_session -> Cmd.get_request -> Rbac.access_verdict
val decide_post : Rbac.auth_session -> Cmd.post_request -> Rbac.access_verdict
val decide_put : Rbac.auth_session -> Cmd.put_request -> Rbac.access_verdict
val decide_delete : Rbac.auth_session -> Cmd.delete_request -> Rbac.access_verdict
val decide_stream_post :
  Rbac.auth_session -> Cmd.stream_post_request -> Rbac.access_verdict
val decide_editor_target :
  Rbac.auth_session -> Cmd.editor_target -> Rbac.access_verdict
val decide_stream :
  Rbac.auth_session -> Subscriptions.stream_id -> Rbac.access_verdict

val decide_workspace : Rbac.auth_session -> Nav.workspace -> Rbac.access_verdict
val decide_work_tab : Rbac.auth_session -> Nav.work_tab -> Rbac.access_verdict
val decide_knowledge_tab :
  Rbac.auth_session -> Nav.knowledge_tab -> Rbac.access_verdict
val decide_keeper_tab :
  Rbac.auth_session -> Nav.keeper_tab -> Rbac.access_verdict
val decide_runtime_tab :
  Rbac.auth_session -> Nav.runtime_tab -> Rbac.access_verdict
val decide_infra_tab : Rbac.auth_session -> Nav.infra_tab -> Rbac.access_verdict
val decide_inspector : Rbac.auth_session -> Nav.inspector -> Rbac.access_verdict
val decide_inline_action :
  Rbac.auth_session -> Nav.inline_action_kind -> Rbac.access_verdict
val decide_overlay : Rbac.auth_session -> Nav.overlay -> Rbac.access_verdict
val decide_menu_target :
  Rbac.auth_session -> Nav.menu_target -> Rbac.access_verdict
val decide_slash_command_id :
  Rbac.auth_session -> Slash.command_id -> Rbac.access_verdict
val decide_slash_parsed :
  Rbac.auth_session -> Slash.parsed -> Rbac.access_verdict

val can_fetch_get : Rbac.auth_session -> Cmd.get_request -> bool
val can_post : Rbac.auth_session -> Cmd.post_request -> bool
val can_put : Rbac.auth_session -> Cmd.put_request -> bool
val can_delete : Rbac.auth_session -> Cmd.delete_request -> bool
val can_stream_post : Rbac.auth_session -> Cmd.stream_post_request -> bool
val can_stream : Rbac.auth_session -> Subscriptions.stream_id -> bool
val can_access_workspace : Rbac.auth_session -> Nav.workspace -> bool
val can_access_overlay : Rbac.auth_session -> Nav.overlay -> bool
val can_access_inline_action : Rbac.auth_session -> Nav.inline_action_kind -> bool
val can_access_menu_target : Rbac.auth_session -> Nav.menu_target -> bool
val can_run_slash_command_id : Rbac.auth_session -> Slash.command_id -> bool

val is_cmd_allowed : Rbac.auth_session -> Cmd.t -> bool
val filter_cmds : Rbac.auth_session -> Cmd.t list -> Cmd.t list
(** Filter out any disallowed network/editor/artifact/voice commands for
    [session], including nested {!Cmd.Batch} trees and {!Cmd.Sync_streams}
    lists, ensuring zero speculative 403/404 requests. *)

val active_view_verdict : Model.t -> Rbac.access_verdict
(** Verdict for the currently focused workspace, sub-tab, or inspector. *)

val can_chat_with_keeper : Rbac.auth_session -> Rbac.access_verdict
(** Verdict for sending a chat/steer/follow-up turn to a keeper. *)
