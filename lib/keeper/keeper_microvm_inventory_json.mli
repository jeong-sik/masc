(** Pure strict decoder shared by full guest inventory and exact helper absence
    observation. Callers must separately establish successful complete CLI
    output; this module performs no process, filesystem or lifecycle effects. *)

type presence = Present | Absent

type invalid_inventory =
  | Invalid_json
  | Expected_array
  | Expected_row_object
  | Duplicate_row_key
  | Invalid_configuration
  | Duplicate_configuration_key
  | Missing_identity
  | Invalid_identity
  | Conflicting_identity
  | Duplicate_guest_name

type presence_error = Invalid_guest_name

type scoping_labels =
  { component : string
  ; base_path_hash : string
  ; kind : string
  ; keeper : string
  }

type row = { name : string; scoping_labels : scoping_labels option }
(** Malformed, duplicate, incomplete or conflicting labels project to [None],
    while every validated guest identity remains present in the inventory. *)

type t
(** Complete unfiltered decoded inventory. This value is an observation, not
    mutation authority or evidence that a process completed successfully. *)

val of_apple_json : string -> (t, invalid_inventory) result
(** Validate every row identity, including duplicate keys, conflicting identities
    and duplicate guest names, before returning any absence observation. *)

val rows : t -> row list
val presence : guest_name:string -> t -> (presence, presence_error) result
(** Exact name comparison over all identities. A blank requested name is an
    error; foreign or malformed scoping labels never filter an existing guest. *)

val invalid_inventory_message : invalid_inventory -> string
(** Bounded diagnostic with no inventory content. *)
