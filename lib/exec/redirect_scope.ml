type mode = Read | Write | Append

type t =
  | File of { fd : int; target : Path_scope.t; mode : mode }
  | Fd_to_fd of { src : int; dst : int }

let pp fmt = function
  | File { fd; target; mode } ->
      let op = match mode with Read -> "<" | Write -> ">" | Append -> ">>" in
      Format.fprintf fmt "%d%s%a" fd op Path_scope.pp target
  | Fd_to_fd { src; dst } ->
      Format.fprintf fmt "%d>&%d" src dst
