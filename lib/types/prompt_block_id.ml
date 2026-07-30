type t =
  | Persona
  | Dynamic_context
  | Temporal_summary
  | Memory_os_recall

let equal a b =
  match a, b with
  | Persona, Persona
  | Dynamic_context, Dynamic_context
  | Temporal_summary, Temporal_summary
  | Memory_os_recall, Memory_os_recall -> true
  | (Persona | Dynamic_context | Temporal_summary | Memory_os_recall), _ -> false

let to_string = function
  | Persona -> "persona"
  | Dynamic_context -> "dynamic_context"
  | Temporal_summary -> "temporal_summary"
  | Memory_os_recall -> "memory_os_recall"

let of_string = function
  | "persona" -> Ok Persona
  | "dynamic_context" -> Ok Dynamic_context
  | "temporal_summary" -> Ok Temporal_summary
  | "memory_os_recall" -> Ok Memory_os_recall
  | name -> Error (Printf.sprintf "unknown prompt block id %S" name)

let all_known = [ Persona; Dynamic_context; Temporal_summary; Memory_os_recall ]
