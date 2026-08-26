(** See keeper_oauth_declarations.mli. *)

module Provider = Keeper_oauth_provider

type declaration =
  | Declared of Provider.t
  | Unreadable of { id : string; problem : string }

let id_of = function
  | Declared provider -> provider.Provider.id
  | Unreadable { id; _ } -> id
;;

let directory = "identity/"

let of_key key =
  let id = Filename.remove_extension (Filename.basename key) in
  match Embedded_config.read key with
  | None -> Unreadable { id; problem = "the file is not readable" }
  | Some contents ->
    (match Provider.load ~file_name:id ~contents with
     | Ok provider -> Declared provider
     | Error err -> Unreadable { id; problem = Provider.error_to_string err })
;;

let all () =
  Embedded_config.file_list
  |> List.filter (fun key ->
       String.starts_with ~prefix:directory key && Filename.check_suffix key ".toml")
  |> List.map of_key
  |> List.sort (fun left right -> String.compare (id_of left) (id_of right))
;;

let find wanted = List.find_opt (fun row -> String.equal (id_of row) wanted) (all ())
