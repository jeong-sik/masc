(** Identity pane rows from an immutable reading of its UI inputs. *)

type view =
  { keeper_name : string
  ; providers : Masc_tui_identity_model.identity_provider list
  ; filter : string option
  ; cursor : int
  ; logins : Masc_tui_identity_model.identity_login_started list
  ; attempt_error : (Masc_tui_identity_model.identity_notice_kind * string) option
  ; app_form : Masc_tui_identity_model.identity_app_form option
  ; callback : Masc_tui_identity_model.identity_callback option
  ; order : Masc_tui_identity_model.identity_order
  ; show : Masc_tui_identity_model.identity_show
  }

type drawn =
  { rows : string list
  ; cursor_row : int option
      (** The index in [rows] of the provider the cursor is on, for the pane
          that scrolls these rows to keep it in view; [None] when no provider
          row is drawn. *)
  }

(** Preserve provider numbering, notices, filtered-empty readings and login URL
    wrapping. Styling uses the current terminal theme; no UI state is mutated. *)
val draw : cols:int -> view -> drawn
