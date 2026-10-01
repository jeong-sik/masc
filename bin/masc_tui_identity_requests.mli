(** Identity request execution. The caller owns mailbox delivery; domain
    result application belongs to {!Masc_tui_identity_updates}. *)

val launch_github_view :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) -> string -> unit
(** Stamp the selected Keeper's GitHub detail request before launching its read. *)

val launch_view :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) -> string -> unit
(** Stamp the provider-detail request before reading the Keeper's inventory. *)

val launch_switch :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) ->
  keeper_name:string -> provider_id:string -> enabled:bool -> unit
(** Deliver the provider-switch result; cancellation propagates. *)

val launch_app_save :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) ->
  form:Masc_tui_identity_model.identity_app_form -> unit
(** Capture all form fields before the daemon begins, then preserve the
    typed scope-count decode and the existing unreadable-reply error. *)

val launch_login :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) ->
  keeper_name:string -> provider_id:string -> label:string -> unit
(** Preserve attached-credential refresh before login completion and the
    browser handoff before an authorization URL outcome is delivered. *)

val launch_refresh :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) ->
  keeper_name:string -> provider_ids:string list -> unit
(** Refresh providers in order, stopping at the first refusal. Missing switches
    deliver the existing error response rather than running a synchronous write. *)
