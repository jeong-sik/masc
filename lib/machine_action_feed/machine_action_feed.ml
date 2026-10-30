type entry = {
  at : float;
  who : string;
  action : string;
}

(* Twenty rows fills more than the spectator column has room for at any
   terminal height this renders in, and a lane call is frequent enough
   (hotseat presses, a step every few seconds) that more would only ever
   scroll off before anyone reads it. *)
let cap = 20

(* [existing] is already at most [cap] long (every entry passed through here),
   so only the new head can push it over: drop the oldest one entry at a
   time rather than re-measuring the whole list on every push. *)
let rec take n = function
  | [] -> []
  | _ when n <= 0 -> []
  | x :: rest -> x :: take (n - 1) rest
;;

let push e existing = e :: take (cap - 1) existing

let to_json e : Yojson.Safe.t =
  `Assoc [ ("at", `Float e.at); ("who", `String e.who); ("action", `String e.action) ]
;;

let to_json_list entries : Yojson.Safe.t = `List (List.map to_json entries)
