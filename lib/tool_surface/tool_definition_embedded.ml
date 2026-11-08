(** See [tool_definition_embedded.mli]. *)

let path name = "tools/" ^ name ^ ".toml"

let find name =
  let rel = path name in
  match Embedded_config.read rel with
  | None -> Error (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents -> Tool_definition_toml.load ~name ~contents
;;

let load name =
  match find name with
  | Ok loaded -> loaded
  | Error message -> failwith message
;;

let schema name = (load name).Tool_definition_toml.schema

(* Read on every logged tool call, so the TOML is decoded once per name. The
   embedded tree is immutable for the life of the process; the table only
   ever gains entries, and two fibers decoding the same name race to insert
   the same value, so the decode runs outside the lock. *)
let path_params_table : (string, string list) Hashtbl.t = Hashtbl.create 64
let path_params_lock = Stdlib.Mutex.create ()

let path_params name =
  match Stdlib.Mutex.protect path_params_lock (fun () -> Hashtbl.find_opt path_params_table name) with
  | Some declared -> declared
  | None ->
    let declared =
      match find name with
      | Ok loaded -> loaded.Tool_definition_toml.path_params
      | Error _ -> []
    in
    Stdlib.Mutex.protect path_params_lock (fun () -> Hashtbl.replace path_params_table name declared);
    declared
;;
