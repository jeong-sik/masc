(** Why a Keeper turn could not resolve its Task Skill pins.

    This module holds only the error and its Agent Core carrier, so the turn
    terminal classifier ({!Keeper_agent_error}) can read the typed reason
    without depending on the whole Task Skill selection module (#31131). *)

type t =
  | Skill_config_rejected of { diagnostics : Skill_source_config.diagnostic list }
  | Skill_config_unreadable of { detail : string }
      (** The snapshot's Skill configuration was rejected or could not be
          read, so it holds no entries and no pin can be told apart from a
          deleted Skill. Resolution fails when any Task pins a Skill; a stale
          pin against a configured snapshot is an unprojectable row. *)
  | Skill_source_unreadable of
      { source_id : string
      ; observation : Skill_catalog_snapshot.source_observation
      }
      (** The scan of the pinned Skill's source did not read successfully, so
          the Skill may still exist there. Resolution fails rather than
          listing the pin as deleted. *)
  | Skill_entry_unreadable of
      { reference : Skill_reference.t
      ; path : string
      ; detail : string
      }
      (** The pinned package's document could not be read, so the Skill may
          still exist. Resolution fails rather than listing the pin as
          deleted. *)

type kind =
  | Config_rejected
  | Config_unreadable
  | Source_unreadable
  | Entry_unreadable

val kind : t -> kind

val kind_to_code : kind -> string
(** The turn terminal reason code. *)

val code : t -> string
(** [kind_to_code (kind error)]. *)

val to_string : t -> string

val core_error : t -> Agent_core.Error.t
(** [Internal_carried] whose carrier holds this value. *)

val of_core_error : Agent_core.Error.t -> t option
(** [Some] only for an error built by {!core_error}. *)
