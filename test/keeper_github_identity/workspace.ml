type backend_config = { cluster_name : string }

type config =
  { base_path : string
  ; backend_config : backend_config
  }

let default_config base_path =
  { base_path; backend_config = { cluster_name = "default" } }
;;

let sanitize_cluster_name name =
  let sanitized =
    String.map
      (function
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' as c -> c
        | _ -> '-')
      name
    |> String.trim
  in
  if String.equal sanitized "" then "default" else sanitized
;;

let keepers_runtime_dir config =
  match config.backend_config.cluster_name with
  | "" | "default" -> Common.keepers_runtime_dir_of_base ~base_path:config.base_path
  | cluster_name ->
    Filename.concat
      (Filename.concat
         (Filename.concat config.base_path ".masc")
         (Filename.concat "clusters" (sanitize_cluster_name cluster_name)))
      "keepers"
;;

(* The real form reads the cluster from [MASC_CLUSTER_NAME], the same source
   a process's [config] was built from. *)
let keepers_runtime_dir_for_base_path base_path =
  let cluster_name =
    match Sys.getenv_opt "MASC_CLUSTER_NAME" with
    | Some name when not (String.equal (String.trim name) "") -> String.trim name
    | Some _ | None -> "default"
  in
  keepers_runtime_dir { base_path; backend_config = { cluster_name } }
;;
