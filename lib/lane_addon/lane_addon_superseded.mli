(** Which retained Lane instances a newer binding of the same owner supersedes
    (RFC-0497 section 4.1). The caller reads the bindings and says which
    instances this process holds; this module only decides.

    Layer one counts the decision. Nothing reads it to delete. *)

type owner = { id : string; source_path : string; revision : string }

(** Whether a binding's lifecycle returned its resources. *)
type release =
  | Released  (** [Detached (Never_created | Released | Native_released)]. *)
  | Not_released
      (** Every other lifecycle, [Native_retained] included, and a lifecycle
          that cannot be read. *)

type 'runtime persistence =
  | Ephemeral
  | Persistent of { package_id : string; runtime : 'runtime }
  | Package_unreadable

(** A binding's instance id and its UUIDv7 time. *)
type identity =
  | Minted of { instance_id : string; minted_ms : int64 }
  | Unminted  (** No instance id, or one whose UUIDv7 time cannot be read. *)

type ('visibility, 'runtime) binding = {
  identity : identity;
  release : release;
  owner : owner option;
  visibility : 'visibility;
  persistence : 'runtime persistence;
}

type count = {
  eligible : string list;  (** Instance ids section 4.1 would delete. *)
  protected : int;  (** Bindings kept, diverging ones included. *)
  diverging_bindings : int;
      (** Released, superseded bindings kept because their visibility or
          runtime differs from their group's representative. *)
  diverging_groups : int;  (** Groups that hold a diverging binding. *)
}

val plan :
  now_ms:int64 ->
  live:(string -> bool) ->
  owner_faulted:(owner -> bool) ->
  ('visibility, 'runtime) binding list ->
  count
(** [live] names the instances this process holds or cleans up.
    [owner_faulted] says whether the reading holds an unreadable record that
    may be this owner's newest. A group's representative is the [Minted]
    binding with the greatest instance id whose time is not after [now_ms]; any
    other binding is never a representative and never eligible. Visibility and
    runtime are compared structurally. *)
