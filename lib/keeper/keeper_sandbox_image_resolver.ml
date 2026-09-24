module Catalog = Keeper_sandbox_image_catalog

type error =
  | Not_declared
  | Catalog_unreadable of Catalog.load_error
  | Unknown_image of { name : string; known : string list }
  | Not_built_on_host of { name : string; store : Catalog.store }

(* A microVM runtime's store is chosen on the command line; Docker's is the
   default and takes no flag. *)
let runtime_flag = function
  | Catalog.Docker_daemon -> ""
  | Catalog.Microvm backend -> " --runtime " ^ Keeper_microvm_backend.to_string backend

(* Only the embedded recipe builds without a checkout. *)
let source_flag name =
  if String.equal name Keeper_sandbox_image_version.(base_embedded.name) then ""
  else " --source <checkout>"

let error_to_string = function
  | Not_declared ->
    "sandbox_image is not set. A Keeper whose sandbox_profile starts a container \
     names an image from the host's image catalog (sandbox-images.toml)."
  | Catalog_unreadable (Catalog.Missing { path }) ->
    Printf.sprintf
      "no image catalog at %s. Build an image with `masc sandbox-image`, then \
       `masc sandbox-image promote <name> <tag>` writes the catalog."
      path
  | Catalog_unreadable error -> Catalog.load_error_to_string error
  | Unknown_image { name; known } ->
    Printf.sprintf "sandbox_image %S is not in the image catalog (it has: %s)." name
      (match known with [] -> "no names" | names -> String.concat ", " names)
  | Not_built_on_host { name; store } ->
    Printf.sprintf
      "nothing is promoted for %S in the %s image store. Build it with \
       `masc sandbox-image --recipe %s%s%s` and record the tag it prints with \
       `masc sandbox-image promote %s <tag>%s`."
      name (Catalog.store_to_string store) name (source_flag name)
      (runtime_flag store) name (runtime_flag store)

let resolve ~config_root ~store declared =
  match declared with
  | None -> Error Not_declared
  | Some name when String.equal (String.trim name) "" -> Error Not_declared
  | Some name ->
    (match Catalog.load ~config_root with
     | Error error -> Error (Catalog_unreadable error)
     | Ok catalog ->
       (match Catalog.resolve catalog ~name ~store with
        | Catalog.Resolved pinned -> Ok pinned
        | Catalog.Unknown_image { name; known } -> Error (Unknown_image { name; known })
        | Catalog.Not_built_on_host { name; store } ->
          Error (Not_built_on_host { name; store })))
