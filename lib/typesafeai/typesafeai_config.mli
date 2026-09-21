(** TypeSafe AI configuration and opt-in control.

    The lane's settings are the [\[typesafeai\]] table of runtime.toml
    ({!Runtime_schema.typesafeai}), published on load by {!Runtime.set_loaded}
    into {!Runtime_typesafeai_policy}. Only the keys are read from the
    environment, because they are secrets: each destination names the
    variable holding its own. The lane is off until one of the named
    variables holds a key. *)

type destinations = Typesafeai_client.destination * Typesafeai_client.destination list
(** The armed destinations, in the order the table names them: each carries
    the key its variable held. Never empty. *)

type unavailable_reason =
  | Lane_disabled  (** [\[typesafeai\] enabled = false] *)
  | No_armed_destination
      (** none of the variables the destinations name holds a key *)
  | Absorb_gate_disabled  (** [\[typesafeai\] absorb_gate = false], the default *)
  | Board_attention_disabled  (** [\[typesafeai\] board_attention = false] *)
  | Context_review_disabled
  | Skill_applicability_disabled
  | Keeper_excluded
      (** the keeper is named in [\[typesafeai\] excluded_keepers]: nothing of
          it reaches the vendor, whichever gate asks *)

val unavailable_reason_to_string : unavailable_reason -> string

val configured_destinations :
  unit -> Runtime_schema.typesafeai_destination * Runtime_schema.typesafeai_destination list
(** [\[typesafeai\] destinations] as loaded, credential-free. *)

val lane_destinations : unit -> (destinations, unavailable_reason) result
(** The lane switch, then the armed destinations: [Error Lane_disabled] when
    the table turns the lane off, [Error No_armed_destination] when no named
    variable holds a key. Used by the continuity measurement CLI,
    independently of any gate. *)

val absorb_gate_destinations : keeper_id:string -> (destinations, unavailable_reason) result
(** One snapshot for evaluation or its skip reason, in this precedence: the
    lane switch, the armed destinations, the absorb gate's own switch, then
    the keeper's exclusion. The lane defaults to on when a key is present; the
    absorb gate requires explicit opt-in because it sends the librarian's
    memories to the vendor. *)

val board_attention_destinations : keeper_id:string -> (destinations, unavailable_reason) result
(** The same for the Board attention judgment
    ({!Keeper_board_attention_exact_flow}), whose switch defaults to on. *)

val context_review_destinations : keeper_id:string -> (destinations, unavailable_reason) result
(** Opt-in preservation review of source Context and its proposed summary.
    Disabled by default; lane, keys and keeper exclusions still apply. *)

val skill_applicability_destinations :
  keeper_id:string -> (destinations, unavailable_reason) result
(** Opt-in applicability advice for an already authorized Skill read.
    Disabled by default; advice does not grant execution permission. *)

val is_enabled : unit -> bool
(** Whether [\[typesafeai\].enabled] permits use and a named variable holds a
    key. *)

val is_board_attention_enabled : unit -> bool
(** {!is_enabled} and [\[typesafeai\].board_attention] does not say
    otherwise, before any keeper's exclusion. *)

val is_absorb_gate_enabled : unit -> bool
(** {!is_enabled} and [\[typesafeai\].absorb_gate] says so, before any
    keeper's exclusion. *)

val is_excluded : keeper_id:string -> bool
(** The keeper is named in [\[typesafeai\].excluded_keepers]. *)

val unknown_excluded_keepers : known:string list -> string list
(** The names in [\[typesafeai\].excluded_keepers] that are not in [known],
    the keepers of the base path: each excludes nobody and is reported at
    boot. *)

type readiness =
  | Off
  | Configured of { models : string list }

val readiness : unit -> readiness
(** Credential-free Board attention readiness for operator projections. [Off]
    covers a disabled Board gate or lane and no armed destination;
    [Configured] carries the model ids of the armed destinations in walk
    order, never a key. *)
