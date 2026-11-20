(** Lane add-ons, package installer, declaration/subscription forms, browser
    history, and browser lane interaction launchers. *)

val map_lane_addons
  :  Masc_tui_types.state
  -> (Masc_tui_lane_addons.t -> Masc_tui_lane_addons.t)
  -> unit

val lane_addons_input_failure : string -> Masc_tui_lane_addons.diagnostic option

val lane_addons_detail_failure
  :  string
  -> Masc_tui_lane_addons.diagnostic option

val lane_addons_kept_back
  :  Masc_tui_types.state
  -> request:Masc_tui_words.Kept_request.t
  -> Masc_tui_types.workspace_refusal
  -> Masc_tui_lane_addons.diagnostic option

val lane_installer_kept_back
  :  Masc_tui_types.state
  -> Masc_tui_lane_addons.t
  -> Masc_tui_lane_installer.read
  -> Masc_tui_types.workspace_refusal
  -> Masc_tui_lane_addons.t

val launch_lane_application
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val lane_addons_request_failure
  :  string
  -> Masc_tui_lane_addons.diagnostic option

val launch_lane_package_catalog
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string option
  -> unit

val launch_lane_package_preview
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> unit

val launch_lane_declaration
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> edit:bool
  -> Masc_tui_lane_declaration.request
  -> unit

val launch_lane_subscriptions
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_lane_subscriptions.request
  -> unit

val launch_lane_addons
  :  ?target:Masc_tui_lane_addons.read_target
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_lane_addons.request
  -> unit

val launch_browser_history
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> reload:bool
  -> unit

val launch_browser_lane
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_types.Browser_lane_view.operation
  -> unit

val refresh_browser_lane
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val open_browser_lane
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit
