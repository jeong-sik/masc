(** Status facts every surface footer ends with.

    A screen supplies only its own key hints. The facts, their order, and the
    separator between them live here, so adding a fact or changing how one
    reads is a single edit instead of one per surface. Before this module the
    21 footers each spelled [Port: %d] themselves and nothing made them agree. *)

type status_item =
  | Refresh_interval of float
  | Port of int

let status_item_text = function
  | Refresh_interval seconds -> Printf.sprintf "Refresh: %.0fs" seconds
  | Port port -> Printf.sprintf "Port: %d" port

(** [line ~dim ~reset ~port ~hints] is one footer line, terminated by a
    newline. [Port] closes every footer and is appended here; [status] carries
    only the extra facts a surface has, in the order they should read. *)
let line ?(status = []) ~dim ~reset ~port ~hints () =
  Printf.sprintf "%s  %s  | %s%s\n" dim hints
    (String.concat " | " (List.map status_item_text (status @ [ Port port ])))
    reset
