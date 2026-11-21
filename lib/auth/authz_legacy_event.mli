(* HIGH-RISK-UNREVIEWED: this module writes and reads the body of the record
   that freezes the legacy inventory at the switchover and attributes each
   legacy keeper to a person. A body read as another keeper's claim would hand
   a keeper's turns to the wrong person. *)

(** The body of the legacy attribution record at the switchover (design 10.3
    and 10.5): the legacy inventory frozen once, the bootstrap candidate the
    admin admission binds, a legacy keeper claimed by that candidate, or one
    retired without a claim.

    {b Where it goes.} The kind that carries this body lands with the reducer
    that reads it, and the two land together: a kind the log admits but no
    reducer reads would make every replay of the log fail, and a kind no author
    writes has no place in the log's vocabulary yet. This module is the codec
    alone, so the bytes are pinned and reviewed before anything writes them.

    {b Body.} An object whose first member is [event], then the members of that
    event in the order written below:

    - [{"event":"inventory_frozen","bootstrap_invite_id":...,"cutover_at_ms":...,
      "legacy_keepers":[...],"legacy_task_ids":[...],"legacy_manifest_sha256":...}]
    - [{"event":"candidate_bound","user_id":...,"invite_id":...}]
    - [{"event":"keeper_claimed","engine_name":...,"claimant":...,"keeper_id":...,
      "runtime_id":...,"policy_id":...,"turn_scope":{...}}]
    - [{"event":"keeper_retired","engine_name":...,"actor":...}]

    [cutover_at_ms] is a number and the ids, the hash and the labels are
    strings. [legacy_keepers] and [legacy_task_ids] are lists of strings in
    strictly ascending byte order, without a repeat: {!to_body} sorts and
    deduplicates what it is given, so the same inventory always writes the same
    bytes and the same hash, and {!of_body} refuses a list that is not already
    in that order. A legacy keeper is named by its
    {!Authz_types.Engine_name}, the installation-wide name, and the claim's
    [keeper_id] is the owner-scoped {!Authz_types.Keeper_id} the claim makes;
    the two are different names and one is never read as the other.
    [legacy_manifest_sha256] is 64 lowercase hex characters. [turn_scope] is
    the body of {!Authz_types.Authorization_scope.t} that
    {!Authz_scope_body} writes.

    A body with other members, the same members in another order, or a member
    of another type is refused. This module does not know who may write the
    record ({!Authz_record.admits} and {!Authz_state} decide that), nor in
    which order the events may come: the inventory is frozen once, and a claim
    names the candidate the admission bound. {!Authz_state} answers both. *)

type t =
  | Inventory_frozen of
      { bootstrap_invite_id : Authz_types.Invite_id.t
      ; cutover_at_ms : int  (** Wall clock in milliseconds. *)
      ; legacy_keepers : Authz_types.Engine_name.t list
            (** The engine names the installation held at the cutover. *)
      ; legacy_task_ids : string list  (** The tasks no keeper claimed. *)
      ; legacy_manifest_sha256 : Authz_record.Hash.t
      }
  | Candidate_bound of
      { user_id : Authz_types.User_id.t
      ; invite_id : Authz_types.Invite_id.t
            (** The bootstrap invitation whose admission bound this candidate. *)
      }
  | Keeper_claimed of
      { engine_name : Authz_types.Engine_name.t
            (** The installation-wide engine name of the legacy keeper. *)
      ; claimant : Authz_types.User_id.t
      ; keeper_id : Authz_types.Keeper_id.t  (** The keeper made by the claim. *)
      ; runtime_id : Authz_types.Runtime_id.t
      ; policy_id : Authz_types.Policy_id.t
      ; turn_scope : Authz_types.Authorization_scope.t
            (** The limits the claim's PAT puts on the keeper's turns. *)
      }
  | Keeper_retired of
      { engine_name : Authz_types.Engine_name.t
      ; actor : Authz_types.User_id.t
      }

(** The event label on disk: [inventory_frozen], [candidate_bound],
    [keeper_claimed], or [keeper_retired]. The labels are on disk and renaming
    one orphans every record written with it. *)
val label : t -> string

val equal : t -> t -> bool

(** The body of the record. The error cannot come from a value of {!t}: the
    labels, the ids, and the hash text are ASCII. It is returned because
    {!Authz_body.t} can only be made through functions that check. *)
val to_body : t -> (Authz_body.t, Authz_body.error) result

(** Why a body is not the body of a legacy attribution record. *)
type error =
  | Not_an_object
  | Unknown_event of string  (** The first member is [event], but not a label of it. *)
  | Wrong_members
      (** An object, but not exactly the members of one event, in their order,
          with their types. *)
  | Not_ascending of string
      (** The list named by the member is not in strictly ascending byte order:
          a repeat, or another order. *)
  | Invalid_invite_id of Authz_id.error
  | Invalid_user_id of Authz_id.error
  | Invalid_engine_name of Authz_id.error
  | Invalid_keeper_id of Authz_id.error
  | Invalid_runtime_id of Authz_id.error
  | Invalid_policy_id of Authz_id.error
  | Invalid_manifest_hash  (** Not 64 lowercase hex characters. *)
  | Invalid_scope of Authz_scope_body.error

val error_to_string : error -> string

(** Reads a body. The first check that fails is the result: it is an object,
    its first member names an event, its members are those of that event, each
    list is in order, and then each id is one. *)
val of_body : Authz_body.t -> (t, error) result
