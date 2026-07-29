type t =
  | Facts_and_episodes
  | Facts_only

let to_string = function
  | Facts_and_episodes -> "facts_and_episodes"
  | Facts_only -> "facts_only"
;;

let of_string = function
  | "facts_and_episodes" -> Some Facts_and_episodes
  | "facts_only" -> Some Facts_only
  | _ -> None
;;

let all = [ Facts_and_episodes; Facts_only ]
let valid_strings = List.map to_string all

let () =
  List.iter
    (fun projection -> assert (of_string (to_string projection) = Some projection))
    all
;;
