(** Identity pane rows from an immutable reading of its UI inputs. *)

type view =
  { keeper_name : string
  ; providers : Masc_tui_identity_model.identity_provider list
  ; filter : string option
  ; cursor : int
  ; login : Masc_tui_identity_model.identity_login_started option
  ; attempt_error : (Masc_tui_identity_model.identity_notice_kind * string) option
  ; app_form : Masc_tui_identity_model.identity_app_form option
  }

(** Preserve provider numbering, notices, filtered-empty readings and login URL
    wrapping. Styling uses the current terminal theme; no UI state is mutated. *)
val lines : cols:int -> view -> string list
