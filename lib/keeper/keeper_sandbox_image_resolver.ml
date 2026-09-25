module Catalog = Keeper_sandbox_image_catalog

type error =
  | Not_declared
  | Catalog_unreadable of Catalog.load_error
  | Unknown_image of { name : string; known : string list }
  | Not_built_on_host of { name : string; store : Catalog.store }
  | No_image_store of { keeper : string; sandbox_profile : Keeper_types_profile_sandbox.sandbox_profile }

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
  | Unknown_image { name; known } ->
    Printf.sprintf "sandbox_image %S is not in the image catalog (it has: %s)." name
      (match known with [] -> "no names" | names -> String.concat ", " names)
  | Not_built_on_host { name; store = Catalog.Microvm Keeper_microvm_backend.Microsandbox } ->
    Printf.sprintf
      "nothing is promoted for %S in the microsandbox image store. The msb CLI has no image build command, and `masc sandbox-image promote --runtime microsandbox` cannot read an image digest for the catalog. This backend has no supported build-and-promote path yet."
      name
  | Not_built_on_host { name; store = Catalog.Microvm Keeper_microvm_backend.Nerdctl_kata } ->
    Printf.sprintf
      "nothing is promoted for %S in the nerdctl_kata image store. `masc sandbox-image --runtime nerdctl_kata` can build an image, but `masc sandbox-image promote --runtime nerdctl_kata` cannot read its digest for the catalog. This backend has no supported promote path yet."
      name
  | Not_built_on_host { name; store = (Catalog.Docker_daemon | Catalog.Microvm Keeper_microvm_backend.Apple_container) as store } ->
    Printf.sprintf
      "nothing is promoted for %S in the %s image store. Build it with \
       `masc sandbox-image --recipe %s%s%s` and record the tag it prints with \
       `masc sandbox-image promote %s <tag>%s`."
      name (Catalog.store_to_string store) name (source_flag name)
      (runtime_flag store) name (runtime_flag store)
  | No_image_store { keeper; sandbox_profile = Keeper_types_profile_sandbox.Micro_vm } ->
    Printf.sprintf
      "keeper %s declares sandbox_profile=microvm and no microvm_backend, so there \
       is no image store to start it from. Set microvm_backend to one of: %s."
      keeper (String.concat ", " Keeper_microvm_backend.valid_strings)
  | No_image_store { keeper; sandbox_profile = (Keeper_types_profile_sandbox.Docker | Keeper_types_profile_sandbox.Remote_ssh) as profile } ->
    Printf.sprintf "keeper %s runs on sandbox_profile=%s, which starts no container image."
      keeper (Keeper_types_profile_sandbox.sandbox_profile_to_string profile)

let resolve ~config_root ~store declared =
  match declared with
  | None -> Error Not_declared
  | Some name when String.equal (String.trim name) "" -> Error Not_declared
  | Some name ->
    let loaded =
      match Embedded_config.read Catalog.shipped_file_name with
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
       (match Catalog.resolve catalog ~name ~store with
        | Catalog.Resolved pinned -> Ok pinned
        | Catalog.Unknown_image { name; known } -> Error (Unknown_image { name; known })
        | Catalog.Not_built_on_host { name; store } ->
          Error (Not_built_on_host { name; store })))

let store_of_meta (meta : Keeper_meta_contract.keeper_meta) =
  match meta.Keeper_meta_contract.sandbox_profile, meta.Keeper_meta_contract.microvm_backend with
  | Keeper_types_profile_sandbox.Docker, _ -> Some Catalog.Docker_daemon
  | Keeper_types_profile_sandbox.Micro_vm, Some backend -> Some (Catalog.Microvm backend)
  | Keeper_types_profile_sandbox.Micro_vm, None | Keeper_types_profile_sandbox.Remote_ssh, _ -> None

let resolve_in_workspace ~base_path ~store declared =
  let resolution = Config_dir_resolver.resolve_for_base_path ~base_path in
  resolve
    ~config_root:resolution.Config_dir_resolver.config_root.Config_dir_resolver.path
    ~store declared

let for_keeper ~base_path (meta : Keeper_meta_contract.keeper_meta) =
  match store_of_meta meta with
  | None ->
    Error
      (No_image_store
         { keeper = meta.Keeper_meta_contract.name
         ; sandbox_profile = meta.Keeper_meta_contract.sandbox_profile
         })
  | Some store -> resolve_in_workspace ~base_path ~store meta.Keeper_meta_contract.sandbox_image
