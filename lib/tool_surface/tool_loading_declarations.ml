let loading_of_declaration ~path ~name ~contents =
  (* Raise rather than answer Always_loaded. A misplaced [defer_loading]
     (after a [[params]] table, where TOML makes it that table's key) parses
     as a parameter's unknown key, and answering "declares nothing" for it
     would make a declaration nobody honours and nobody reports. *)
  match Tool_definition_toml.load ~name ~contents with
  | Error message ->
    failwith (Printf.sprintf "tool loading declarations: %s: %s" path message)
  | Ok loaded -> loaded.Tool_definition_toml.loading
;;

module String_map = Map.Make (String)

(* Parsed eagerly at module init from the constant crunched embedded tree so
   concurrent OCaml 5 domains never race [Stdlib.Lazy.force]. *)
let table : Tool_definition_toml.loading String_map.t =
  List.fold_left
    (fun table path ->
       match Filename.dirname path, Filename.extension path with
       | "tools", ".toml" ->
         let name = Filename.remove_extension (Filename.basename path) in
         (match Embedded_config.read path with
          | None -> table
          | Some contents ->
            String_map.add name (loading_of_declaration ~path ~name ~contents) table)
       | _, _ -> table)
    String_map.empty
    Embedded_config.file_list
;;

let declared name = String_map.find_opt name table

let required name =
  match declared name with
  | Some loading -> loading
  | None ->
    failwith
      (Printf.sprintf
         "tool loading declarations: %s is missing"
         (Tool_definition_embedded.path name))
;;
