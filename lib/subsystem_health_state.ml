module By_name = Map.Make (String)

type health =
  | Alive
  | Dead of { crashed_at : float }

type event =
  | Registered of { name : string }
  | Crashed of
      { name : string
      ; crashed_at : float
      }

type t = health By_name.t

let empty = By_name.empty

let apply state = function
  | Registered { name } -> By_name.add name Alive state
  | Crashed { name; crashed_at } -> By_name.add name (Dead { crashed_at }) state
;;

let entries state = By_name.bindings state
