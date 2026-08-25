(** The [keeper.tools] group vocabulary (RFC-0389).

    A leaf on purpose: the TOML parser needs it to reject an unknown group
    at load time, and the descriptor needs it to resolve a declared surface.
    Living below both is what breaks the cycle that used to push the check
    to the consumer as a stringly fail-open. *)

type t =
  | Execute_group
  | Search_files_group
  | Filesystem_group
  | Board_group
  | Voice_group
  | Workspace_group
  | Surface_group
  | Memory_group
  | Meta_group
  | Core_group

let to_string = function
  | Execute_group -> "execute"
  | Search_files_group -> "search_files"
  | Filesystem_group -> "fs"
  | Board_group -> "board"
  | Voice_group -> "voice"
  | Workspace_group -> "workspace"
  | Surface_group -> "surface"
  | Memory_group -> "memory"
  | Meta_group -> "meta"
  | Core_group -> "core"
;;

(* Strict inverse of [to_string]. Unknown strings are [None] so the load
   time check can reject them — a typo in [keeper.tools] must fail the TOML
   load, not quietly keep the full surface. *)
let of_string = function
  | "execute" -> Some Execute_group
  | "search_files" -> Some Search_files_group
  | "fs" -> Some Filesystem_group
  | "board" -> Some Board_group
  | "voice" -> Some Voice_group
  | "workspace" -> Some Workspace_group
  | "surface" -> Some Surface_group
  | "memory" -> Some Memory_group
  | "meta" -> Some Meta_group
  | "core" -> Some Core_group
  | _ -> None
;;

let name = to_string
;;
