(** Apply Identity responses on the UI state owner fiber. Reporting and
    provider refresh effects are supplied by the caller. *)

val github_view_loaded :
  Masc_tui_types.state -> Masc_tui_types.detail_read_request ->
  (string list, string) result -> unit
(** Complete the detail read, then apply only for the still-selected Keeper. *)

val switch_set :
  Masc_tui_types.state -> keeper_name:string -> provider_id:string -> enabled:bool ->
  report:(string -> string -> unit) -> refresh:(string -> unit) ->
  (unit, string) result -> unit
(** Success reports before re-reading the provider view. Refusal records its notice. *)

val providers_loaded :
  Masc_tui_types.state -> Masc_tui_types.detail_read_request ->
  (Masc_tui_identity_model.identity_provider list, string) result -> unit
(** Apply only a current selected-Keeper read; clear a tracked login only when
    the refreshed provider inventory proves it landed. *)

val login_started :
  Masc_tui_types.state -> keeper_name:string -> Masc_tui_identity_model.identity_login_result -> unit
(** Keep the Keeper-stamped login or the existing attached/refusal notice. *)

val app_saved :
  Masc_tui_types.state -> provider_id:string -> (int, string) result -> unit
(** Preserve the recorded scope count and the zero-scope inventory notice. *)

val refreshed :
  Masc_tui_types.state -> keeper_name:string -> refresh:(string -> unit) ->
  (unit, string) result -> unit
(** Success clears the old provider view before [refresh]; refusal records its error. *)
