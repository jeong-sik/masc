(* One parse of the embedded tool tree, on first ask. The files are constant
   for the life of the process -- they are crunched into the binary -- so a
   second parse would read the same bytes to the same answer. Held whole,
   so every per-tool axis a file can declare (loading, repeat) is read from
   the one parse rather than each reader walking the tree again. *)

let declaration_of_file ~path ~name ~contents =
  (* Raise rather than answer "declares nothing". A misplaced key (after a
     [[params]] table, where TOML makes it that table's key) parses as a
     parameter's unknown key, and answering "declares nothing" for it would
     make a declaration nobody honours and nobody reports. *)
  match Tool_definition_toml.load ~name ~contents with
  | Error message -> failwith (Printf.sprintf "tool declarations: %s: %s" path message)
  | Ok loaded -> loaded
;;

let table : (string, Tool_definition_toml.loaded) Hashtbl.t Lazy.t =
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
               Hashtbl.replace table name (declaration_of_file ~path ~name ~contents))
          | _, _ -> ())
       Embedded_config.file_list;
     table)
;;

let find name = Hashtbl.find_opt (Lazy.force table) name
