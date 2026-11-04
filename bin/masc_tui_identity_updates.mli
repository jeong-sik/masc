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

(** Apply catalog and attempt facts under one read admission. Published
    credentials retire only with the paired current successful catalog read;
    immutable failure/expiry facts need no catalog. Present only the selected Keeper.
    A successful read also holds the callback the server named. *)
(** What one reading of a Keeper's providers and attempts tells the read that
    owed it. *)
type reading =
  | Reading_succeeded
  | Reading_failed
      (** The catalog or an attempt's status could not be read, or the server
          says a consent still waits whose deadline [now] has passed. *)
  | Reading_superseded  (** A newer read, or a lost authority, owns the answer. *)

val providers_loaded
  :  Masc_tui_types.state
  -> Masc_tui_types.detail_read_request
  -> now:float
  -> settle:(reading -> unit)
  -> report:(string -> unit)
  -> attempts:(Masc_tui_types.identity_login_expectation * (Masc_tui_identity_model.identity_login_status, string) result) list
  -> ( Masc_tui_identity_model.identity_provider list
       * Masc_tui_identity_model.identity_callback option
     , string )
     result
  -> unit

(** Retire the exact request generation before remembering its login or notice.
    A stale completion leaves the newer attempt intact. *)
val login_started
  :  Masc_tui_types.state
  -> Masc_tui_types.identity_login_request
  -> now:float
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

val disconnected
  :  Masc_tui_types.state
  -> keeper_name:string
  -> provider_id:string
  -> notice:
       (keeper_name:string option
        -> Masc_tui_identity_model.identity_notice_kind * string
        -> unit)
  -> refresh:(string -> unit)
  -> (string, string) result
  -> unit
