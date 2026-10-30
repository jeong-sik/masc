type t = Progress

let key = "masc.tool_outcome"
let progress_wire = "progress"

let to_metadata = function
  | Progress -> `Assoc [ key, `String progress_wire ]
;;

let of_metadata (metadata : Yojson.Safe.t option) : t option =
  match metadata with
  | Some (`Assoc fields) ->
    (match List.assoc_opt key fields with
     | Some (`String wire) when String.equal wire progress_wire -> Some Progress
     | Some (`String _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _)
     | None -> None)
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) | None -> None
;;
