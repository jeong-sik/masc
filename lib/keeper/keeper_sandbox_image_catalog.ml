type store =
  | Docker_daemon
  | Microvm of Keeper_microvm_backend.t

let docker_store_name = "docker"

let store_to_string = function
  | Docker_daemon -> docker_store_name
  | Microvm backend -> Keeper_microvm_backend.to_string backend

let store_of_string raw =
  if String.equal raw docker_store_name then Some Docker_daemon
  else Option.map (fun backend -> Microvm backend) (Keeper_microvm_backend.of_string raw)

type pinned =
  { reference : string
  ; digest : string
  }

type promotion =
  { current : pinned
  ; previous : pinned option
  }

type entry =
  { name : string
  ; promoted : (store * promotion) list
  }

type t = entry list

let entries t = t

type parse_error =
  | Toml_syntax of string
  | Expected_table of { path : string list }
  | Unknown_key of { path : string list; key : string }
  | Invalid_name of string
  | Unknown_store of { image : string; store : string }
  | Missing_field of { path : string list; field : string }
  | Expected_string of { path : string list; field : string }
  | Invalid_digest of { path : string list; value : string }
  | Invalid_reference of { path : string list; value : string }

let dotted path = String.concat "." path

let parse_error_to_string = function
  | Toml_syntax detail -> "not TOML: " ^ detail
  | Expected_table { path } -> Printf.sprintf "%s is not a table" (dotted path)
  | Unknown_key { path; key } ->
    Printf.sprintf "%s has a key this catalog does not use: %s" (dotted path) key
  | Invalid_name name ->
    Printf.sprintf
      "%S is not an image name: use lowercase letters, digits and '-', not \
       starting with '-'"
      name
  | Unknown_store { image; store } ->
    Printf.sprintf "images.%s names an image store MASC does not run: %s (known: %s)"
      image store
      (String.concat ", "
         (docker_store_name :: Keeper_microvm_backend.valid_strings))
  | Missing_field { path; field } -> Printf.sprintf "%s has no %s" (dotted path) field
  | Expected_string { path; field } ->
    Printf.sprintf "%s.%s is not a string" (dotted path) field
  | Invalid_digest { path; value } ->
    Printf.sprintf "%s.digest %S is not sha256:<64 lowercase hex>" (dotted path) value
  | Invalid_reference { path; value } ->
    Printf.sprintf
      "%s.reference %S is empty or has a character outside A-Z a-z 0-9 . _ / : @ -"
      (dotted path) value

let ( let* ) = Result.bind

let valid_name name =
  let allowed = function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false in
  String.length name > 0
  && (not (Char.equal name.[0] '-'))
  && String.for_all allowed name

let digest_prefix = "sha256:"
let sha256_hex_length = 64

let valid_digest value =
  let hex = function '0' .. '9' | 'a' .. 'f' -> true | _ -> false in
  let prefix_length = String.length digest_prefix in
  String.length value = prefix_length + sha256_hex_length
  && String.equal (String.sub value 0 prefix_length) digest_prefix
  && String.for_all hex (String.sub value prefix_length sha256_hex_length)

(* The characters an OCI image reference is spelt with. Holding references to
   them is also what lets {!to_toml} write one between quotes as it is. *)
let valid_reference value =
  let allowed = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '/' | ':' | '@' | '-' -> true
    | _ -> false
  in
  String.length value > 0 && String.for_all allowed value

let table ~path = function
  | Otoml.TomlTable fields | Otoml.TomlInlineTable fields -> Ok fields
  | _ -> Error (Expected_table { path })

(* Every key a table may carry is named by its reader; anything else is an
   error rather than ignored, so a misspelt field cannot read as absent. *)
let only_keys ~path ~allowed fields =
  match List.find_opt (fun (key, _) -> not (List.mem key allowed)) fields with
  | Some (key, _) -> Error (Unknown_key { path; key })
  | None -> Ok ()

let string_field ~path ~field fields =
  match List.assoc_opt field fields with
  | None -> Error (Missing_field { path; field })
  | Some (Otoml.TomlString value) -> Ok value
  | Some _ -> Error (Expected_string { path; field })

let reference_key = "reference"
let digest_key = "digest"
let previous_key = "previous"

let checked_pin ~path ~reference ~digest =
  if not (valid_reference reference) then Error (Invalid_reference { path; value = reference })
  else if not (valid_digest digest) then Error (Invalid_digest { path; value = digest })
  else Ok { reference; digest }

let pinned ~path fields =
  let* () = only_keys ~path ~allowed:[ reference_key; digest_key ] fields in
  let* reference = string_field ~path ~field:reference_key fields in
  let* digest = string_field ~path ~field:digest_key fields in
  checked_pin ~path ~reference ~digest

let promotion ~path fields =
  let* () = only_keys ~path ~allowed:[ reference_key; digest_key; previous_key ] fields in
  let current_fields = List.filter (fun (key, _) -> not (String.equal key previous_key)) fields in
  let* current = pinned ~path current_fields in
  let* previous =
    match List.assoc_opt previous_key fields with
    | None -> Ok None
    | Some value ->
      let path = path @ [ previous_key ] in
      let* previous_fields = table ~path value in
      Result.map Option.some (pinned ~path previous_fields)
  in
  Ok { current; previous }

let images_key = "images"

let entry (name, value) =
  let path = [ images_key; name ] in
  let* () = if valid_name name then Ok () else Error (Invalid_name name) in
  let* stores = table ~path value in
  let* promoted =
    List.fold_left
      (fun acc (store_name, store_value) ->
         let* read = acc in
         match store_of_string store_name with
         | None -> Error (Unknown_store { image = name; store = store_name })
         | Some store ->
           let path = path @ [ store_name ] in
           let* fields = table ~path store_value in
           let* promotion = promotion ~path fields in
           Ok ((store, promotion) :: read))
      (Ok []) stores
  in
  Ok { name; promoted = List.rev promoted }

let parse text =
  let* toml = Result.map_error (fun detail -> Toml_syntax detail) (Otoml.Parser.from_string_result text) in
  let* top = table ~path:[] toml in
  let* () = only_keys ~path:[] ~allowed:[ images_key ] top in
  match List.assoc_opt images_key top with
  | None -> Ok []
  | Some images ->
    let* named = table ~path:[ images_key ] images in
    let* entries =
      List.fold_left
        (fun acc field ->
           let* read = acc in
           let* entry = entry field in
           Ok (entry :: read))
        (Ok []) named
    in
    Ok (List.rev entries)

type resolution =
  | Resolved of pinned
  | Unknown_image of { name : string; known : string list }
  | Not_built_on_host of { name : string; store : store }

let resolve t ~name ~store =
  match List.find_opt (fun entry -> String.equal entry.name name) t with
  | None -> Unknown_image { name; known = List.map (fun entry -> entry.name) t }
  | Some entry ->
    (match List.assoc_opt store entry.promoted with
     | Some promotion -> Resolved promotion.current
     | None -> Not_built_on_host { name; store })

let file_name = "sandbox-images.toml"

type load_error =
  | Missing of { path : string }
  | Unreadable of { path : string; detail : string }
  | Invalid of { path : string; error : parse_error }

let load_error_to_string = function
  | Missing { path } -> Printf.sprintf "no image catalog at %s" path
  | Unreadable { path; detail } -> Printf.sprintf "cannot read %s: %s" path detail
  | Invalid { path; error } -> Printf.sprintf "%s: %s" path (parse_error_to_string error)

let load ~config_root =
  let path = Filename.concat config_root file_name in
  if not (Sys.file_exists path) then Error (Missing { path })
  else
    match In_channel.with_open_bin path In_channel.input_all with
    | exception Sys_error detail -> Error (Unreadable { path; detail })
    | text -> Result.map_error (fun error -> Invalid { path; error }) (parse text)

type change_error =
  | No_such_image of { name : string; known : string list }
  | Invalid_pin of parse_error
  | Nothing_to_roll_back of { name : string; store : store }

let change_error_to_string = function
  | No_such_image { name; known } ->
    Printf.sprintf "the catalog has no image %S (it has: %s)" name
      (match known with [] -> "none" | names -> String.concat ", " names)
  | Invalid_pin error -> parse_error_to_string error
  | Nothing_to_roll_back { name; store } ->
    Printf.sprintf "%s on %s has no previous build to roll back to" name
      (store_to_string store)

let known_names t = List.map (fun entry -> entry.name) t

let change_entry t ~name f =
  match List.find_opt (fun entry -> String.equal entry.name name) t with
  | None -> Error (No_such_image { name; known = known_names t })
  | Some _ ->
    let rec replace = function
      | [] -> Ok []
      | entry :: rest when String.equal entry.name name ->
        let* promoted = f entry.promoted in
        Ok ({ entry with promoted } :: rest)
      | entry :: rest ->
        let* rest = replace rest in
        Ok (entry :: rest)
    in
    replace t

let set_store store promotion promoted =
  if List.mem_assoc store promoted
  then List.map (fun (s, p) -> if s = store then (s, promotion) else (s, p)) promoted
  else promoted @ [ store, promotion ]

let promote t ~name ~store ~reference ~digest =
  let path = [ images_key; name; store_to_string store ] in
  match checked_pin ~path ~reference ~digest with
  | Error error -> Error (Invalid_pin error)
  | Ok pin ->
    change_entry t ~name (fun promoted ->
      match List.assoc_opt store promoted with
      | Some { current; _ } when current = pin -> Ok promoted
      | Some { current; _ } ->
        Ok (set_store store { current = pin; previous = Some current } promoted)
      | None -> Ok (set_store store { current = pin; previous = None } promoted))

let rollback t ~name ~store =
  change_entry t ~name (fun promoted ->
    match List.assoc_opt store promoted with
    | Some { current; previous = Some previous } ->
      Ok (set_store store { current = previous; previous = Some current } promoted)
    | Some { previous = None; _ } | None -> Error (Nothing_to_roll_back { name; store }))

let header =
  "# Sandbox images a Keeper can name in `sandbox_image`, and the build this\n\
   # host promoted for each image store. `masc sandbox-image promote` and\n\
   # `rollback` rewrite this file. RFC keeper-sandbox-images-have-versions.\n"

let to_toml t =
  let buf = Buffer.create 512 in
  Buffer.add_string buf header;
  List.iter
    (fun entry ->
       Printf.bprintf buf "\n[%s.%s]\n" images_key entry.name;
       List.iter
         (fun (store, promotion) ->
            Printf.bprintf buf "\n[%s.%s.%s]\n%s = \"%s\"\n%s = \"%s\"\n" images_key
              entry.name (store_to_string store) reference_key
              promotion.current.reference digest_key promotion.current.digest;
            Option.iter
              (fun previous ->
                 Printf.bprintf buf "%s = { %s = \"%s\", %s = \"%s\" }\n" previous_key
                   reference_key previous.reference digest_key previous.digest)
              promotion.previous)
         entry.promoted)
    t;
  Buffer.contents buf

type save_error = Unwritable of { path : string; detail : string }

let save_error_to_string (Unwritable { path; detail }) =
  Printf.sprintf "cannot write %s: %s" path detail

let save ~config_root t =
  let path = Filename.concat config_root file_name in
  let staging = path ^ ".tmp" in
  match
    Out_channel.with_open_bin staging (fun oc -> Out_channel.output_string oc (to_toml t));
    Sys.rename staging path
  with
  | () -> Ok ()
  | exception Sys_error detail -> Error (Unwritable { path; detail })
