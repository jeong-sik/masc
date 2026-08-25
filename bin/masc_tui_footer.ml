(** Status facts every surface footer ends with.

    A screen supplies only its own key hints. The facts, their order, and the
    separator between them live here, so adding a fact or changing how one
    reads is a single edit instead of one per surface. Before this module the
    21 footers each spelled [Port: %d] themselves and nothing made them agree. *)

type status_item =
  | Refresh_interval of float
  | Server_build of
      { version : string
      ; commit : string
      }
  | Port of int

(* Enough of the commit to tell two checkouts apart, which is the question
   this answers: [Port: 8935] alone is the same on every build that ever
   served that port. *)
let commit_prefix_length = 7

let short_commit commit =
  if String.length commit <= commit_prefix_length
  then commit
  else String.sub commit 0 commit_prefix_length

let status_item_text = function
  | Refresh_interval seconds -> Printf.sprintf "Refresh: %.0fs" seconds
  | Server_build { version; commit } ->
    (match version, short_commit commit with
     | "", "" -> "build: unread"
     | version, "" -> "v" ^ version
     | "", commit -> commit
     | version, commit -> Printf.sprintf "v%s %s" version commit)
  | Port port -> Printf.sprintf "Port: %d" port

(** [line ~dim ~reset ~port ~hints] is one footer line, terminated by a
    newline. [Port] closes every footer and is appended here; [status] carries
    only the extra facts a surface has, in the order they should read. *)
let line ?(status = []) ~dim ~reset ~port ~hints () =
  Printf.sprintf "%s  %s  | %s%s\n" dim hints
    (String.concat " | " (List.map status_item_text (status @ [ Port port ])))
    reset
