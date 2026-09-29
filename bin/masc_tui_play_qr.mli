type error =
  | Too_large
  | Pane_too_narrow of { required_cells : int; available_cells : int }

val render : available_cells:int -> string -> (string, error) result
(** Encode a play link locally as a terminal QR with a four-module quiet zone.
    The result contains printable UTF-8 block characters and line breaks only.
    Refuse a pane that would truncate or wrap a QR row. *)
