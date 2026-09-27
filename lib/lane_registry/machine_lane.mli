(** The machines that live in the server process, one shared instance each:
    MSX (RFC-0439) and DOS ([Dos_lane]). A new machine is a constructor here,
    and every exhaustive match over this type then says what it means. *)

(** [all] (derived) lists every machine once, in constructor order. *)
type t =
  | Msx
  | Dos
[@@deriving enumerate]

val to_wire : t -> string
(** The machine's name in a Lane id, after [machine/]. *)
