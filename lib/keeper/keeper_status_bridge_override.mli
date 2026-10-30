(** A Keeper field whose live value differs from its declared default. The
    status surfaces list these as [override_fields] and
    [override_field_sources]. *)

type t =
  | Instructions of { default : string; live : string }
  | Mention_targets of { default : string list; live : string list }
  | Board_interests of { default : string list; live : string list }
  | Runtime_id of { default : string; live : string }
  | Activation_mode of
      { default : Keeper_activation_mode.t
      ; live : Keeper_activation_mode.t
      }

val field_name : t -> string
(** The dotted name the status JSON carries, such as ["model.runtime_id"]. *)

val default_value_json : t -> Yojson.Safe.t
val live_value_json : t -> Yojson.Safe.t

type runtime_drift = { default : string; live : string }

val runtime_drift : t list -> runtime_drift option
(** The declared and live runtime ids when the runtime is overridden. *)
