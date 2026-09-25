type store =
  | Docker_daemon
  | Microvm of Keeper_microvm_backend.t

(* Docker's store is where a [sandbox_profile = "docker"] Keeper runs, and
   the catalog spells it the way the profile is spelt. *)
let docker_store_name = Keeper_sandbox_config.sandbox_profile_to_string Keeper_sandbox_config.Docker

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

type t =
  { active : entry list
  ; orphaned_builds : entry list
  }

let entries t = t.active
let orphaned_builds t = t.orphaned_builds

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
  | Shipped_build of { name : string }
  | Host_name_without_build of { name : string }

let dotted = function [] -> "the catalog" | path -> String.concat "." path

let parse_error_to_string = function
  | Toml_syntax detail -> "not TOML: " ^ detail
  | Expected_table { path } -> Printf.sprintf "%s is not a table" (dotted path)
  | Unknown_key { path; key } ->
    Printf.sprintf "%s has a key this catalog does not use: %s" (dotted path) key
  | Invalid_name name ->
    Printf.sprintf
      "%S is not an image name: lowercase letters and digits, in words joined \
       by single '-'"
      name
  | Unknown_store { image; store } ->
    Printf.sprintf
      "images.%s.%s is not an image store MASC runs (known: %s); a build goes \
       under [images.%s.<store>]"
      image store
      (String.concat ", " (docker_store_name :: Keeper_microvm_backend.valid_strings))
      image
  | Missing_field { path; field } -> Printf.sprintf "%s has no %s" (dotted path) field
  | Expected_string { path; field } ->
    Printf.sprintf "%s.%s is not a string" (dotted path) field
  | Invalid_digest { path; value } ->
    Printf.sprintf "%s.digest %S is not sha256:<64 lowercase hex>" (dotted path) value
  | Invalid_reference { path; value } ->
    Printf.sprintf
      "%s.reference %S is not repository:tag (a tag after the last ':', \
       letters, digits, '.', '_', '-', '/', ':' only, not starting with '-')"
      (dotted path) value
  | Shipped_build { name } ->
    Printf.sprintf "shipped image %S contains a host build" name
  | Host_name_without_build { name } ->
    Printf.sprintf "host image %S has no build; names belong in the shipped catalog" name

let ( let* ) = Result.bind

(* Words of lowercase letters and digits joined by single '-': the directory
   names under sandbox-images/. *)
let valid_name name =
  let word w = String.length w > 0 && String.for_all (function 'a' .. 'z' | '0' .. '9' -> true | _ -> false) w in
  List.for_all word (String.split_on_char '-' name)

let digest_prefix = "sha256:"
let sha256_hex_length = 64

let valid_digest value =
  let hex = function '0' .. '9' | 'a' .. 'f' -> true | _ -> false in
  let prefix_length = String.length digest_prefix in
  String.length value = prefix_length + sha256_hex_length
  && String.equal (String.sub value 0 prefix_length) digest_prefix
  && String.for_all hex (String.sub value prefix_length sha256_hex_length)

(* [repository:tag], checked only as far as the value's two uses need: it is
   written between TOML quotes and passed as one argv word to an image
   store's CLI. So: no leading '-' (it would read as a flag), only characters
   that need no quoting, and a nonempty tag after the last ':' that holds no
   '/' (so a registry port is not taken for a tag). '@' is not allowed, which
   refuses a digest reference. Whether the image exists is the store's answer
   at promote, not this parser's. *)
let valid_reference value =
  let safe = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' | '/' | ':' -> true
    | _ -> false
  in
  match String.rindex_opt value ':' with
  | None -> false
  | Some colon ->
    let tag = String.sub value (colon + 1) (String.length value - colon - 1) in
    colon > 0
    && value.[0] <> '-'
    && String.length tag > 0
    && (not (String.contains tag '/'))
    && String.for_all safe value

let is_reference = valid_reference

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

let parse_entries text =
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

let parse text =
  Result.map (fun active -> { active; orphaned_builds = [] }) (parse_entries text)

type resolution =
  | Resolved of pinned
  | Unknown_image of { name : string; known : string list }
  | Not_built_on_host of { name : string; store : store }

let resolve t ~name ~store =
  match List.find_opt (fun entry -> String.equal entry.name name) t.active with
  | None -> Unknown_image { name; known = List.map (fun entry -> entry.name) t.active }
  | Some entry ->
    (match List.assoc_opt store entry.promoted with
     | Some promotion -> Resolved promotion.current
     | None -> Not_built_on_host { name; store })

let file_name = "sandbox-images.toml"

type load_error =
  | Unreadable of { path : string; detail : string }
  | Invalid of { path : string; error : parse_error }

let load_error_to_string = function
  | Unreadable { path; detail } -> Printf.sprintf "cannot read %s: %s" path detail
  | Invalid { path; error } -> Printf.sprintf "%s: %s" path (parse_error_to_string error)

type snapshot =
  | Absent
  | Read of string

(* Opening is the existence check, so a file removed between a check and the
   open cannot read as unreadable. *)
let read_snapshot path =
  match Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Absent
  | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
  | fd ->
    let ic = Unix.in_channel_of_descr fd in
    (match In_channel.input_all ic with
     | text ->
       close_in_noerr ic;
       Ok (Read text)
     | exception Sys_error detail ->
       close_in_noerr ic;
       Error detail)

let read_snapshot_for_load path =
  Result.map_error (fun detail -> Unreadable { path; detail }) (read_snapshot path)

let catalog_path ~config_root = Filename.concat config_root file_name

let parse_at ~path text = Result.map_error (fun error -> Invalid { path; error }) (parse text)

let from_shipped_and_snapshot ~path ~shipped snapshot =
  let shipped_path = "config/sandbox-images.toml (shipped)" in
  let* names = Result.map entries (parse_at ~path:shipped_path shipped) in
  let* () =
    match List.find_opt (fun entry -> entry.promoted <> []) names with
    | None -> Ok ()
    | Some entry -> Error (Invalid { path = shipped_path; error = Shipped_build { name = entry.name } })
  in
  let* host =
    match snapshot with
    | Absent -> Ok []
    | Read text -> Result.map entries (parse_at ~path text)
  in
  let* () =
    List.fold_left
      (fun checked entry ->
         let* () = checked in
         if entry.promoted = []
         then Error (Invalid { path; error = Host_name_without_build { name = entry.name } })
         else Ok ())
      (Ok ()) host
  in
  let active, orphaned_builds =
    List.partition
      (fun entry -> List.exists (fun named -> String.equal named.name entry.name) names)
      host
  in
  Ok
    { active =
        List.map
          (fun named ->
             match List.find_opt (fun entry -> String.equal entry.name named.name) active with
             | None -> named
             | Some entry -> { named with promoted = entry.promoted })
          names
    ; orphaned_builds
    }

let load ~config_root ~shipped =
  let path = catalog_path ~config_root in
  let* snapshot = read_snapshot_for_load path in
  from_shipped_and_snapshot ~path ~shipped snapshot

let load_for_change ~config_root ~shipped =
  let path = catalog_path ~config_root in
  let* snapshot = read_snapshot_for_load path in
  let* catalog = from_shipped_and_snapshot ~path ~shipped snapshot in
  Ok (catalog, snapshot)

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

let known_names t = List.map (fun entry -> entry.name) t.active

let change_entry t ~name f =
  match List.find_opt (fun entry -> String.equal entry.name name) t.active with
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
    Result.map (fun active -> { t with active }) (replace t.active)

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
  "# Builds this host promoted for each image store. The binary's shipped\n\
   # sandbox-images.toml supplies the image names. `masc sandbox-image promote` and\n\
   # `rollback` rewrite this file. RFC keeper-sandbox-images-have-versions.\n"

let to_toml t =
  let buf = Buffer.create 512 in
  Buffer.add_string buf header;
  List.iter
    (fun entry ->
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
    (t.active @ t.orphaned_builds);
  Buffer.contents buf

type save_error =
  | Changed_since_read of { path : string }
  | Unwritable of { path : string; detail : string }
  | Written_but_durability_unconfirmed of { path : string; detail : string }
  | Saved_but_unlock_failed of { path : string; detail : string }

let save_error_to_string = function
  | Changed_since_read { path } ->
    Printf.sprintf
      "%s changed after it was read; nothing was written, run the command again"
      path
  | Unwritable { path; detail } -> Printf.sprintf "cannot write %s: %s" path detail
  | Written_but_durability_unconfirmed { path; detail } ->
    Printf.sprintf
      "%s was renamed, but directory sync failed: %s; inspect the catalog before retrying"
      path detail
  | Saved_but_unlock_failed { path; detail } ->
    Printf.sprintf
      "%s was written, but its transaction lock could not be released: %s; inspect the catalog before retrying"
      path detail

(* The lock serializes the compare and atomic replacement across processes.
   A writer may calculate a change from an older snapshot outside the lock;
   once it acquires the lock, the byte comparison rejects that stale change. *)
let save_with ~write ~config_root ~expected t =
  let path = catalog_path ~config_root in
  let lock_path = path ^ ".lock" in
  let save_under_lock () =
    match read_snapshot path with
    | Error detail -> Error (Unwritable { path; detail })
    | Ok current when current <> expected -> Error (Changed_since_read { path })
    | Ok _ ->
      (match write path (to_toml t) with
       | Ok () -> Ok ()
       | Error failure ->
         let detail = Fs_compat.atomic_replace_failure_to_string failure in
         (match failure.stage with
          | Fs_compat.Before_rename -> Error (Unwritable { path; detail })
          | Fs_compat.After_rename ->
            Error (Written_but_durability_unconfirmed { path; detail })))
  in
  match File_lock_eio.with_durable_lock_observed ~lock_path save_under_lock with
  | File_lock_eio.Lock_not_acquired error ->
    Error (Unwritable { path; detail = File_lock_eio.durable_lock_error_to_string error })
  | File_lock_eio.Body_completed { value; release_error = None } -> value
  | File_lock_eio.Body_completed { value = Ok (); release_error = Some error } ->
    Error (Saved_but_unlock_failed
             { path; detail = File_lock_eio.durable_lock_error_to_string error })
  | File_lock_eio.Body_completed { value = Error primary; release_error = Some error } ->
    Log.Misc.error
      "sandbox image catalog lock release failed after catalog operation: %s"
      (File_lock_eio.durable_lock_error_to_string error);
    Error primary

let save = save_with ~write:Fs_compat.save_file_atomic_strict_staged

module For_testing = struct
  let save_with = save_with
end
