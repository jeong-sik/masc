type mode = Read | Write | Append

type target =
  | In_command_namespace of Path_scope.t
  | On_this_host of {
      path : string;
      as_written : Path_scope.t;
    }

type t =
  | File of { fd : int; target : target; mode : mode }
  | Fd_to_fd of { src : int; dst : int }

let on_this_host as_written path = On_this_host { path; as_written }

let target_as_written = function
  | In_command_namespace scope -> scope
  | On_this_host { as_written; _ } -> as_written

let pp fmt = function
  | File { fd; target; mode } ->
      let op = match mode with Read -> "<" | Write -> ">" | Append -> ">>" in
      Format.fprintf fmt "%d%s%a" fd op Path_scope.pp (target_as_written target)
  | Fd_to_fd { src; dst } ->
      Format.fprintf fmt "%d>&%d" src dst
