module Catalog = Keeper_sandbox_image_catalog

type error =
  | Not_declared
  | Catalog_unreadable of Catalog.load_error
  | Unresolved of Catalog.missing

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
  | Catalog_unreadable error -> Catalog.load_error_to_string error
  | Unresolved (Catalog.Unknown_image { name; known }) ->
    Printf.sprintf "sandbox_image %S is not in the image catalog (it has: %s)." name
      (match known with [] -> "no names" | names -> String.concat ", " names)
  (* Promote records a tag the store already has. msb has no build command,
     so its build arrives through [msb load]; every other store is built into
     by [masc sandbox-image]. *)
  | Unresolved (Catalog.Not_built_on_host { name; store = (Catalog.Microvm Keeper_microvm_backend.Microsandbox as store) }) ->
    Printf.sprintf
      "nothing is promoted for %S in the microsandbox image store. The msb CLI \
       has no image build command, so MASC cannot build one: build the image \
       elsewhere, save it as an OCI archive, `msb load` it, and record its tag \
       with `masc sandbox-image promote %s <tag>%s`."
      name name (runtime_flag store)
  | Unresolved (Catalog.Not_built_on_host
      { name
      ; store =
          ( Catalog.Docker_daemon
          | Catalog.Microvm
              (Keeper_microvm_backend.Apple_container | Keeper_microvm_backend.Nerdctl_kata) )
          as store
      }) ->
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
    let loaded =
      match Embedded_config.read Catalog.file_name with
      | None ->
        Error
          (Catalog.Unreadable
             { path = "config/sandbox-images.toml (shipped)"
             ; detail = "embedded image name catalog is unavailable"
             })
      | Some shipped -> Catalog.load ~config_root ~shipped
    in
    (match loaded with
     | Error error -> Error (Catalog_unreadable error)
     | Ok catalog ->
       Catalog.resolve catalog ~name ~store |> Result.map_error (fun missing -> Unresolved missing))
