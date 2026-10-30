(* Workspace_holder — see workspace_holder.mli for design. *)

let workspace = Atomic.make Workspace.empty

let get () = Atomic.get workspace

let rec update transition =
  let current = Atomic.get workspace in
  let next, output = transition current in
  if Atomic.compare_and_set workspace current next
  then output
  else update transition
;;

module For_testing = struct
  let replace value = Atomic.set workspace value
  let reset () = replace Workspace.empty
end
