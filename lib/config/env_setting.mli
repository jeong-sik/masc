(** Env_setting — the declared environment knobs, as closed vocabularies.

    A knob is a constructor whose wire name, default, operator-facing category
    and description come from one exhaustive match. Reading goes through the
    constructor and {!rows_in} reports it, so a knob cannot be readable by the
    process and absent from [masc_config].

    Adding a constructor is a compile error at its [spec], and {!all_rows}
    picks it up from [@@deriving enumerate] without a second list to keep in
    step. *)

type row =
  { env_name : string
  ; default_display : string
  ; category : string
  ; description : string
  }

module Bool_knob : sig
  type t = Oauth_enabled [@@deriving enumerate]

  val env_name : t -> string
  val default : t -> bool
  val get : t -> bool
end

module Int_knob : sig
  type t =
    | Oauth_code_ttl_sec
    | Oauth_access_token_ttl_sec
    | Oauth_refresh_token_ttl_sec
    | Oauth_max_pending_codes
    | Oauth_max_clients
  [@@deriving enumerate]

  val env_name : t -> string
  val default : t -> int
  val get : t -> int
end

val all_rows : row list
(** Every declared knob, bool knobs first. *)

val rows_in : category:string -> row list
(** {!all_rows} restricted to one operator-facing category. *)
