(* ATD names are snake_case (run_started, Run_started). Swift and Kotlin
   take camelCase: RunStarted for types, runStarted for cases and fields. *)

let words name = List.filter (fun word -> word <> "") (String.split_on_char '_' name)
let upper_camel name = String.concat "" (List.map String.capitalize_ascii (words name))

let lower_camel name =
  match words name with
  | [] -> name
  | first :: rest ->
    String.concat ""
      (String.uncapitalize_ascii first :: List.map String.capitalize_ascii rest)

(* Native_ir admits only wire names of ASCII letters, digits and _, so the
   name needs no escape in Swift or Kotlin. *)
let quoted name = "\"" ^ name ^ "\""
