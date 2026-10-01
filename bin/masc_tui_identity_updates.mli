(** Identity response transitions. Notices and reporting remain caller-owned;
    request retirement is independent of the currently selected Keeper. *)

val github_view_loaded
  :  Masc_tui_types.state
  -> Masc_tui_types.detail_read_request
  -> (string list, string) result
  -> unit

val switch_set
  :  Masc_tui_types.state
  -> keeper_name:string
  -> provider_id:string
  -> enabled:bool
  -> report:(string -> string -> unit)
  -> refresh:(string -> unit)
  -> notice:
       (keeper_name:string option
        -> Masc_tui_identity_model.identity_notice_kind * string
        -> unit)
  -> (unit, string) result
  -> unit

(** Retire landed logins for the read's Keeper, even offscreen; present only
    current responses for the selected Keeper. *)
val providers_loaded
  :  Masc_tui_types.state
  -> Masc_tui_types.detail_read_request
  -> (Masc_tui_identity_model.identity_provider list, string) result
  -> unit

(** Retire the exact request generation before remembering its login or notice.
    A stale completion leaves the newer attempt intact. *)
val login_started
  :  Masc_tui_types.state
  -> Masc_tui_types.identity_login_request
  -> report:(string -> string -> unit)
  -> notice:
       (keeper_name:string option
        -> Masc_tui_identity_model.identity_notice_kind * string
        -> unit)
  -> Masc_tui_identity_model.identity_login_result
  -> unit

val app_saved
  :  keeper_name:string option
  -> provider_id:string
  -> notice:
       (keeper_name:string option
        -> Masc_tui_identity_model.identity_notice_kind * string
        -> unit)
  -> (int, string) result
  -> unit

(** Refresh the selected Keeper; report offscreen outcomes without clearing
    another Keeper's view. *)
val refreshed
  :  Masc_tui_types.state
  -> keeper_name:string
  -> refresh:(string -> unit)
  -> report:(string -> string -> unit)
  -> (unit, string) result
  -> unit
