(** Identity data and pure projections, independent of mutable UI state. *)

type identity_provider =
  | Identity_declared of
      { idp_id : string
      ; idp_label : string
      ; idp_tools : string list option
        (** What this service currently offers this Keeper, or [None] when it
            was never attached. An empty list is a third fact -- attached and
            offering nothing -- and reading it as "not attached" would tell an
            operator to consent again for no reason. *)
      ; idp_also_on : string list
        (** Which other Keepers hold this one. A Keeper attaches on its own
            account -- the client is shared, the token is not -- so this is
            the one question a single Keeper's tab cannot answer for itself,
            and answering it by opening each Keeper in turn is how an
            operator loses track of which account went where. *)
      ; idp_enabled : bool option
        (** The on/off switch on an attached row. [None] when the row is not
            attached or the switch store could not be read; the render must
            not show a guess for either. *)
      ; idp_switch_problem : string option
        (** Why the switch state is unknown, when it is. *)
      }
  | Identity_unreadable of
      { idp_id : string
      ; idp_problem : string
      }

type identity_row_state =
  | Identity_not_attached
  | Identity_attached_without_tools
  | Identity_switch_unreadable
  | Identity_switched_off
  | Identity_attached of int (** how many tools it offers *)

type identity_notice_kind =
  | Notice_ok
  | Notice_bad

type identity_app_field =
  | App_client_id
  | App_client_secret
  | App_scopes

type identity_app_form =
  { iaf_provider : string
  ; iaf_label : string
  ; iaf_field : identity_app_field
  ; iaf_client_id : string
  ; iaf_client_secret : string
  ; iaf_scopes : string
  }

type identity_login_started =
  { ils_keeper : string
  ; ils_provider : string
    (** Which service, by id. The label is for a screen; matching on it
          would tie "this login landed" to a display string that a
          declaration is free to change. *)
  ; ils_label : string
  ; ils_url : string
  }

type identity_login_result =
  | Login_started of
      { provider_id : string
      ; label : string
      ; url : string
      }
  | Login_attached of string
  | Login_failed of string

val identity_names : query:string -> string * string -> bool

val identity_connectable
  :  ?query:string
  -> identity_provider list
  -> (string * string) list

val identity_row_state
  :  providers:identity_provider list
  -> id:string
  -> identity_row_state

val identity_summary : providers:identity_provider list -> query:string -> string
val identity_field_paste : string -> string
val identity_notice : cols:int -> (identity_notice_kind * string) option -> string list

val identity_filter_rows
  :  providers:identity_provider list
  -> string option
  -> string list

val identity_preamble : summary:string -> notice:string list -> string list
val identity_provider_line : summary:string -> notice:string list -> index:int -> int

val identity_cursor_clamped
  :  query:string
  -> providers:identity_provider list
  -> int
  -> int

val identity_cursor_provider
  :  query:string
  -> providers:identity_provider list
  -> int
  -> (string * string) option

val identity_app_form_rows : identity_app_form option -> string list

val identity_provider_attached
  : providers:identity_provider list -> provider_id:string -> bool

val identity_login_landed
  :  providers:identity_provider list
  -> login:identity_login_started
  -> bool
