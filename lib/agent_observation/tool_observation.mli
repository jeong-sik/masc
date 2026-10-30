(** Immutable attribution captured before the canonical tool-result row commits.
    This value has no persistence or UI effects. *)
type declared_progress = Progress | No_progress | Failed
type t =
  { attribution : Agent_observation.attribution
  ; turn_ref : Ids.Turn_ref.t
  ; declared_progress : declared_progress option
        (** [None] means the tool declared no progress classification. *)
  }
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
(** Closed codec: malformed, missing, duplicate and unknown fields are errors.
    Readers never reconstruct attribution from mutable checkout state. *)
val addressed : t -> Agent_observation.addressed option
(** [None] means a pathless or explicitly unaddressed fact. *)
val declared_progress_word : declared_progress -> string
val of_row : Yojson.Safe.t -> (t option, string) result
(** [Ok None] means the row supplied no observation. Malformed or duplicate
    observation metadata is [Error], never an absent observation. *)
