type builtin =
  | Exact of Standalone_lane.t
  | Browser of Browser_lane.Lane_name.t
  | Machine of Machine_lane.t
[@@deriving enumerate]

type t =
  | Builtin of builtin
  | Package of Declaration_file.t

let equal_builtin (left : builtin) (right : builtin) = left = right

(* The part of a wire id before [separator]. Read back through
   [all_of_family], so each family name is spelled once. *)
type family =
  | Exact_family
  | Browser_family
  | Machine_family
  | Package_family
[@@deriving enumerate]

let family_to_wire = function
  | Exact_family -> "exact"
  | Browser_family -> "browser"
  | Machine_family -> "machine"
  | Package_family -> "package"
;;

let family_of_wire raw =
  List.find_opt (fun family -> String.equal (family_to_wire family) raw) all_of_family
;;

let separator = '/'

let family = function
  | Builtin (Exact _) -> Exact_family
  | Builtin (Browser _) -> Browser_family
  | Builtin (Machine _) -> Machine_family
  | Package _ -> Package_family
;;

let name = function
  | Builtin (Exact lane) -> Standalone_lane.to_id lane
  | Builtin (Browser lane) -> Browser_lane.Lane_name.to_wire lane
  | Builtin (Machine machine) -> Machine_lane.to_wire machine
  | Package file -> Declaration_file.to_string file
;;

let to_wire id = family_to_wire (family id) ^ String.make 1 separator ^ name id

(* A built-in id is read back through [to_wire], so no lane name is spelled a
   second time here. *)
let builtin_of_wire raw =
  List.find_opt (fun builtin -> String.equal (to_wire (Builtin builtin)) raw) all_of_builtin
  |> Option.map (fun builtin -> Builtin builtin)
;;

let of_wire raw =
  match String.index_opt raw separator with
  | None -> None
  | Some at ->
    (match family_of_wire (String.sub raw 0 at) with
     | None -> None
     | Some (Exact_family | Browser_family | Machine_family) -> builtin_of_wire raw
     | Some Package_family ->
       Declaration_file.of_name (String.sub raw (at + 1) (String.length raw - at - 1))
       |> Option.map (fun file -> Package file))
;;
