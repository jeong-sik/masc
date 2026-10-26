(** Public browser-tool reachability for one concrete browser adapter.
    This catalog performs no discovery, grants no admission and never switches
    browsers. Available means implemented, not that a session/page is ready or
    that an application accepted an effect. *)
type backend = Connected of Browser_lane.live_transport | Owned_gecko
  | Owned_chromium | Safari_unavailable
type operation =
  | List_tabs | Open_tab | Close_tab | Activate_tab | List_windows | Create_window | Close_window
  | Navigate | Follow_link | Back | Forward | Reload | Session_lifecycle
  | Read_text | Read_html | Read_elements | Read_scene | Read_regions | Read_snapshot | Screenshot
  | Native_workflow
  | Click_snapshot_target | Fill_snapshot_target | Hover_snapshot_target | Double_click_snapshot_target
  | Click | Double_click | Right_click | Middle_click | Pointer_down | Pointer_up | Hover | Pointer_drag | Html5_drop
  | Scroll_page | Scroll_at | Fill | Type_text | Press_key | Key_chord | Select_option
  | Read_frames | Frame_interaction | Read_dialog | Accept_dialog | Dismiss_dialog
  | Hand_off | Take_over | Space_status | Finish_space | Wait_for_control | Adopt_tab | Release_tab
  | Upload_file | List_downloads | Page_zoom | Resize_viewport | Touch
  | Read_clipboard | Write_clipboard | Read_network | Intercept_network
  | Read_console | Read_storage | Write_storage | Emulate_environment | Sentence_action
type tool = Tabs | Read | Interact | Act | Session | Goto | Instruct
type invocation = { tool : tool; action : string option; mode : string option }
type support = Available of invocation
  | Conditional of { invocation : invocation; constraints : string list }
  | Unsupported of string
type entry = { operation : operation; support : support }
val operations : operation list
val operation_name : operation -> string
val operation_of_wire : string -> operation option
val parse_required_actions : Yojson.Safe.t -> (operation list, string) result
(** An explicit array of distinct public operation names, parsed once before
    discovery or session dispatch. Unknown operations are never defaulted. *)
val support : backend -> operation -> support
val missing_operations : backend -> operation list -> operation list
(** Conditional operations are implemented with the catalog's listed
    constraints. This does not establish session readiness or effect success. *)
val catalog : backend -> entry list
val to_json : backend -> Yojson.Safe.t
(** Includes unavailable families rather than advertising blanket browser
    automation. No arbitrary JavaScript/debug-protocol escape hatch is exposed. *)
