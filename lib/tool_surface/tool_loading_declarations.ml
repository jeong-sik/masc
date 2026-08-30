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

(* One parse of the embedded tool tree, on first ask. The files are constant
   for the life of the process -- they are crunched into the binary -- so a
   second parse would read the same bytes to the same answer. *)
let table : (string, Tool_definition_toml.loading) Hashtbl.t Lazy.t =
  lazy
    (let table = Hashtbl.create 256 in
     List.iter
       (fun path ->
          match Filename.dirname path, Filename.extension path with
          | "tools", ".toml" ->
            let name = Filename.remove_extension (Filename.basename path) in
            (match Embedded_config.read path with
             | None -> ()
             | Some contents ->
               Hashtbl.replace table name (loading_of_declaration ~path ~name ~contents))
          | _, _ -> ())
       Embedded_config.file_list;
     table)
;;

let loading_of_tool name =
  match Hashtbl.find_opt (Lazy.force table) name with
  | Some loading -> loading
  | None -> Tool_definition_toml.Always_loaded
;;

let deferrable_tool_names () =
  Hashtbl.fold
    (fun name loading acc ->
       match loading with
       | Tool_definition_toml.Deferrable -> name :: acc
       | Tool_definition_toml.Always_loaded -> acc)
    (Lazy.force table)
    []
  |> List.sort String.compare
;;
