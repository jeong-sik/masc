type t =
  { category : Agent_core.Error.category
  ; message : string
  }

let of_core_error error =
  { category = Agent_core.Error.category error
  ; message = Agent_core.Error.to_string error
  }
;;

(* A leaf message is agent-core's own text and may span lines; the summary is
   one line. *)
let one_line text = String.map (function '\n' | '\r' -> ' ' | c -> c) text

let category_to_string : Agent_core.Error.category -> string = function
  | Agent_core.Error.Api_category -> "api"
  | Agent_core.Error.Provider_category -> "provider"
  | Agent_core.Error.Agent_category -> "agent"
  | Agent_core.Error.Mcp_category -> "mcp"
  | Agent_core.Error.Config_category -> "config"
  | Agent_core.Error.Serialization_category -> "serialization"
  | Agent_core.Error.Io_category -> "io"
  | Agent_core.Error.Orchestration_category -> "orchestration"
  | Agent_core.Error.Internal_category -> "internal"
;;

let category_of_string = function
  | "api" -> Some Agent_core.Error.Api_category
  | "provider" -> Some Agent_core.Error.Provider_category
  | "agent" -> Some Agent_core.Error.Agent_category
  | "mcp" -> Some Agent_core.Error.Mcp_category
  | "config" -> Some Agent_core.Error.Config_category
  | "serialization" -> Some Agent_core.Error.Serialization_category
  | "io" -> Some Agent_core.Error.Io_category
  | "orchestration" -> Some Agent_core.Error.Orchestration_category
  | "internal" -> Some Agent_core.Error.Internal_category
  | _ -> None
;;

let summary { category; message } =
  Printf.sprintf "%s: %s" (category_to_string category) (one_line message)
;;

let to_yojson { category; message } =
  `Assoc
    [ "category", `String (category_to_string category); "message", `String message ]
;;

let of_yojson json =
  match json with
  | `Assoc fields ->
    let actual = List.sort String.compare (List.map fst fields) in
    if not (List.equal String.equal actual [ "category"; "message" ])
    then
      Error
        (Printf.sprintf
           "core failure fields must be exactly [category,message], got [%s]"
           (String.concat "," actual))
    else (
      match List.assoc_opt "category" fields, List.assoc_opt "message" fields with
      | Some (`String category), Some (`String message) ->
        (match category_of_string category with
         | Some category -> Ok { category; message }
         | None ->
           Error
             (Printf.sprintf "core failure has unknown category %S" category))
      | _ -> Error "core failure category and message must both be strings")
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error "core failure is not an object"
;;
