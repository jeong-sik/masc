module String_map = Map.Make (String)

(* Parsed eagerly at module init from the constant crunched embedded tree so
   concurrent OCaml 5 domains never race [Stdlib.Lazy.force]. *)
let table : Tool_definition_toml.same_turn_result String_map.t =
  List.fold_left
    (fun table path ->
       match Filename.dirname path, Filename.extension path with
       | "tools", ".toml" ->
         let name = Filename.remove_extension (Filename.basename path) in
         (match Embedded_config.read path with
          | None -> table
          | Some contents ->
            (match Tool_definition_toml.load ~name ~contents with
             | Error message ->
               failwith
                 (Printf.sprintf
                    "tool same-turn result declarations: %s: %s"
                    path
                    message)
             | Ok loaded ->
               String_map.add name loaded.Tool_definition_toml.same_turn_result table))
       | _, _ -> table)
    String_map.empty
    Embedded_config.file_list
;;

let declared name = String_map.find_opt name table

let sent_as_pointer () =
  String_map.fold
    (fun name declared names ->
       match declared with
       | Tool_definition_toml.Repeat_sent_as_pointer -> name :: names
       | Tool_definition_toml.Repeat_sent_whole -> names)
    table
    []
  |> List.rev
;;
