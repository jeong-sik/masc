(** The machines a workspace shares, one instance each, each in its own
    attached add-on worker: MSX (RFC-0439) and DOS ([Dos_lane]). A new machine
    is a constructor here, and every exhaustive match over this type then says
    what it means. *)

(** [all] (derived) lists every machine once, in constructor order. *)
type t =
  | Msx
  | Dos
[@@deriving enumerate]

val to_wire : t -> string
(** The machine's name in a Lane id, after [machine/]. The play room, the
    machine spectator and the workspace dataset events carry the same name in
    their [machine] fields. *)

val of_wire : string -> t option
(** Inverse of {!to_wire}, derived from it over [all]: [None] for a name no
    machine has. A new constructor needs no second spelling here. *)
