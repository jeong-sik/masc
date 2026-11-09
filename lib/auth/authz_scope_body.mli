(* HIGH-RISK-UNREVIEWED: this module writes and reads the scope a scoped PAT
   record holds. A scope read wider than the one written lets the PAT do more
   than its Human allowed. *)

(** The body of an {!Authz_types.Authorization_scope.t}: the runtimes, channels
    and effects a scoped PAT may reach (design 4.4, plan C4-1b).

    {b Body.} An object with the members [runtimes], [channels] and
    [allowed_effects], in this order. Each is ["all"] for [All], or a list of
    strings for the rest: [[]] is [Empty] and a list with members is [Only]
    of them. A runtime is its id, a channel the label of
    {!Authz_types.Channel.to_string}, and an effect the label of
    {!Authz_types.Effect.to_string}. A list holds its labels in strictly
    ascending byte order, the order of the sets, so one scope has one body.

    A body with other members, the same members in another order, a list with
    a repeated label or another order, or a label that names nothing is
    refused. Nothing is widened on reading: a refused body is no scope.

    The PAT record (plan C4-1c) puts this object in one of its members. This
    module does not decide whether a scope may be issued (design 4.4: a
    management effect needs a named channel and named effects). *)

(** The error cannot come from a value of the scope: the labels are ASCII and
    an id is in the alphabet of {!Authz_id}. It is returned because
    {!Authz_body.t} can only be made through functions that check. *)
val to_body : Authz_types.Authorization_scope.t -> (Authz_body.t, Authz_body.error) result

type dimension =
  | Runtimes
  | Channels
  | Allowed_effects

type error =
  | Not_an_object
  | Wrong_members
      (** An object, but not exactly [runtimes], [channels] and
          [allowed_effects] in this order. *)
  | Not_a_scope of dimension  (** Neither ["all"] nor a list of strings. *)
  | Not_ascending of dimension
      (** A list whose labels are not strictly ascending: a repeated label,
          or another order. *)
  | Invalid_runtime_id of Authz_id.error
  | Unknown_channel of string
  | Unknown_effect of string

val error_to_string : error -> string

(** Reads a body. The members are read in order, and in each one the first
    check that fails is the result: its shape, its order, and then each label
    in turn. *)
val of_body : Authz_body.t -> (Authz_types.Authorization_scope.t, error) result

(** {b A set of effects alone.} The list of labels that [allowed_effects]
    holds, in the same strictly ascending order, and never ["all"]: a grant
    names the effects it allows (design 4.3), and a set has no [All]. A Self
    grant in a Runtime record is written this way (plan D2). *)
val effect_set_to_body : Authz_types.Effect.Set.t -> (Authz_body.t, Authz_body.error) result

(** Reads a set of effects. ["all"] and anything but a list of strings is
    [Not_a_scope Allowed_effects]; the order and the labels are checked as in
    {!of_body}. *)
val effect_set_of_body : Authz_body.t -> (Authz_types.Effect.Set.t, error) result
