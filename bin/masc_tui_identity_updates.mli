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
  -> (unit, Masc_tui_types.request_failure) result
  -> unit

(** What one reading of a Keeper's providers and attempts tells the read that
    owed it. *)
type reading =
  | Reading_succeeded
  | Reading_failed
      (** The catalog, or the status of an attempt still waited on, could not be
          read, or the server says such a consent still waits although its
          deadline [wall_now] has passed. *)
  | Reading_superseded  (** A newer read, or a lost authority, owns the answer. *)

(** Apply catalog and attempt facts under one read admission. Published
    credentials retire only with the paired current successful catalog read;
    immutable failure/expiry facts need no catalog. Present only the selected Keeper.
    A successful read also holds the callback the server named. [settle] gets
    the reading's outcome. [wall_now] is the wall clock it judges consent
    deadlines by; [now] is the same moment on the main loop's clock, where a
    failed reading schedules its retry (#53581). *)
val providers_loaded
  :  Masc_tui_types.state
  -> Masc_tui_types.detail_read_request
  -> ?settle:(reading -> unit)
  -> report:(string -> unit)
  -> now:Masc_tui_wake.Mono.t
  -> wall_now:float
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
  -> (Masc_tui_identity_model.identity_login_result, Masc_tui_types.workspace_refusal) result
  -> unit

val app_saved
  :  ko:bool
  -> keeper_name:string option
  -> provider_id:string
  -> notice:
       (keeper_name:string option
        -> Masc_tui_identity_model.identity_notice_kind * string
        -> unit)
  -> (int, Masc_tui_types.request_failure) result
  -> unit

(** Refresh the selected Keeper; report offscreen outcomes without clearing
    another Keeper's view. *)
val refreshed
  :  Masc_tui_types.state
  -> keeper_name:string
  -> refresh:(string -> unit)
  -> report:(string -> string -> unit)
  -> (unit, Masc_tui_types.request_failure) result
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
  -> (string, Masc_tui_types.request_failure) result
  -> unit
