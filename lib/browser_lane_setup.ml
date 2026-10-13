module Host_name = struct
  type t = string

  let default = "masc_browser_host"

  let segment_is_valid segment =
    (not (String.equal segment ""))
    && String.for_all
         (function
           | 'a' .. 'z' | '0' .. '9' | '_' -> true
           | _ -> false)
         segment

  let of_string name =
    if List.for_all segment_is_valid (String.split_on_char '.' name)
    then Ok name
    else
      Error
        "host name must contain nonempty lowercase alphanumeric or underscore segments \
         separated by '.'"

  let to_string name = name
end

type request =
  { base_path : string
  ; binary : string option
  ; token_file : string option
  ; manifest_dir : string
  ; host_name : Host_name.t
  }

type installed =
  { host : string
  ; launcher : string
  ; declaration : string
  ; manifest : string
  ; token : string
  ; extension_directory : string
  ; extension_manifest : string
  }

type error =
  | Base_path_not_absolute of string
  | Host_binary_not_found
  | Host_binary_not_executable of string
  | Token_file_unusable of string
  | Lane_token_unusable of string
  | Token_file_differs of { given : string; canonical : string }
  | Embedded_extension_invalid of string
  | Io of { step : string; path : string; reason : string }

let error_message = function
  | Base_path_not_absolute path ->
    Printf.sprintf "The workspace path %s is not absolute." path
  | Host_binary_not_found ->
    "masc-browser-host was not found beside this masc or on PATH. Install it, or name the \
     built executable with --binary."
  | Host_binary_not_executable path ->
    Printf.sprintf "--binary must be an executable file, and %s is not one." path
  | Token_file_unusable path ->
    Printf.sprintf
      "--token-file must name an existing provisioned lane token, and %s is missing or \
       empty."
      path
  | Lane_token_unusable path ->
    Printf.sprintf
      "The lane token %s is empty or not a regular file. Remove it and run this again to \
       create a new one."
      path
  | Token_file_differs { given; canonical } ->
    Printf.sprintf
      "--token-file %s does not match this workspace's lane token %s. The two must be \
       one token; this command does not choose which is right."
      given canonical
  | Embedded_extension_invalid reason ->
    Printf.sprintf "The extension embedded in this build cannot be installed: %s." reason
  | Io { step; path; reason } -> Printf.sprintf "Could not %s %s: %s" step path reason

let default_manifest_directory ~home = function
  | Sandbox_readiness.Macos _ ->
    Some
      (List.fold_left
         Filename.concat
         home
         [ "Library"; "Application Support"; "Mozilla"; "NativeMessagingHosts" ])
  | Sandbox_readiness.Linux _ ->
    Some (List.fold_left Filename.concat home [ ".mozilla"; "native-messaging-hosts" ])
  | Sandbox_readiness.Unsupported -> None

let ( let* ) = Result.bind

(* One place that turns the exceptions of a filesystem step into the step's
   own words, so the sentence the operator reads names what was being done and
   to which path. *)
let io ~step ~path action =
  match action () with
  | value -> Ok value
  | exception Unix.Unix_error (code, _, _) ->
    Error (Io { step; path; reason = Unix.error_message code })
  | exception Sys_error reason -> Error (Io { step; path; reason })
  | exception (Eio.Io _ as exn) -> Error (Io { step; path; reason = Printexc.to_string exn })

let read_file path = In_channel.with_open_bin path In_channel.input_all

(* A file replaced through a temporary file in its own directory and a rename,
   created with its final mode, so a reader never sees half of it and a token
   is never briefly world-readable. *)
let write_replacing ~mode path contents =
  let directory = Filename.dirname path in
  io ~step:"write" ~path (fun () ->
    let temporary = Filename.temp_file ~temp_dir:directory ".install-" ".partial" in
    match
      Out_channel.with_open_bin temporary (fun out -> output_string out contents);
      Unix.chmod temporary mode;
      Unix.rename temporary path
    with
    | () -> ()
    | exception exn ->
      (try Sys.remove temporary with Sys_error _ -> ());
      raise exn)

let make_directory path = io ~step:"create" ~path (fun () -> Fs_compat.mkdir_p path)

let is_executable_file path =
  match Unix.stat path with
  | { Unix.st_kind = Unix.S_REG; _ } ->
    (match Unix.access path [ Unix.X_OK ] with
     | () -> true
     | exception Unix.Unix_error _ -> false)
  | _ -> false
  | exception Unix.Unix_error _ -> false

let real_path path = try Unix.realpath path with Unix.Unix_error _ -> path
let host_executable_name = "masc-browser-host"

(* The host that belongs to this masc is the one installed beside it: they
   were built and installed together, and the extension this binary embeds is
   written for that host's protocol. PATH is where a hand-installed one is. *)
let beside_this_executable () =
  let beside =
    Filename.concat (Filename.dirname (real_path Sys.executable_name)) host_executable_name
  in
  if is_executable_file beside then Some beside else None

let on_path () =
  match Sys.getenv_opt "PATH" with
  | None -> None
  | Some raw ->
    Executable_path.split_search_path raw
    |> List.filter (fun directory -> not (String.equal directory ""))
    |> List.find_map (fun directory ->
      let candidate = Filename.concat directory host_executable_name in
      if is_executable_file candidate then Some candidate else None)

let host_source = function
  | Some path ->
    let resolved = real_path path in
    if is_executable_file resolved then Ok resolved else Error (Host_binary_not_executable path)
  | None ->
    (match beside_this_executable () with
     | Some path -> Ok (real_path path)
     | None ->
       (match on_path () with
        | Some path -> Ok (real_path path)
        | None -> Error Host_binary_not_found))

(* The id Firefox grants the host to, read from the extension that is being
   written rather than repeated: the manifest and the extension cannot name
   different ids. *)
let extension_id ~manifest_text =
  let invalid reason = Error (Embedded_extension_invalid reason) in
  match Yojson.Safe.from_string manifest_text with
  | exception Yojson.Json_error reason -> invalid ("manifest.json: " ^ reason)
  | json ->
    let open Yojson.Safe.Util in
    (match
       json |> member "browser_specific_settings" |> member "gecko" |> member "id"
     with
     | `String id when not (String.equal id "") -> Ok id
     | _ -> invalid "manifest.json names no browser_specific_settings.gecko.id"
     | exception Type_error (reason, _) -> invalid ("manifest.json: " ^ reason))

let extension_manifest_name = "manifest.json"

let embedded_extension () =
  match Embedded_browser_extension.read extension_manifest_name with
  | None -> Error (Embedded_extension_invalid "it carries no manifest.json")
  | Some manifest_text ->
    let* id = extension_id ~manifest_text in
    let files =
      List.filter_map
        (fun name ->
           Option.map (fun contents -> name, contents) (Embedded_browser_extension.read name))
        Embedded_browser_extension.file_list
    in
    Ok (id, files)

let token_bytes = 24

let hex bytes =
  String.concat
    ""
    (List.init (String.length bytes) (fun index ->
       Printf.sprintf "%02x" (Char.code bytes.[index])))

let nonempty_regular_file path =
  match Unix.stat path with
  | { Unix.st_kind = Unix.S_REG; st_size; _ } -> st_size > 0
  | _ -> false
  | exception Unix.Unix_error _ -> false

(* The canonical token is created once and then only read: a host and a server
   that already agreed on it would stop talking if it changed. Creation is
   exclusive, so two installs racing end with one token and both succeed. *)
let create_token_if_absent ~canonical ~value =
  io ~step:"create" ~path:canonical (fun () ->
    match Unix.openfile canonical [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600 with
    | exception Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    | descriptor ->
      let channel = Unix.out_channel_of_descr descriptor in
      Fun.protect
        ~finally:(fun () -> close_out_noerr channel)
        (fun () ->
           output_string channel (value ^ "\n");
           flush channel))

(* The token the host reads: the workspace's own, or a provisioned file that
   must be that same token. Returns the path the launcher names. *)
let provision_token ~base_path ~lane ~given =
  let canonical = Filename.concat lane Common.browser_lane_token_name in
  let provided =
    Option.map
      (fun path -> if Filename.is_relative path then Filename.concat base_path path else path)
      given
  in
  let* () =
    match provided with
    | Some path when not (nonempty_regular_file path) -> Error (Token_file_unusable path)
    | Some path when Sys.file_exists canonical ->
      let* given_text = io ~step:"read" ~path (fun () -> read_file path) in
      let* canonical_text = io ~step:"read" ~path:canonical (fun () -> read_file canonical) in
      if String.equal (String.trim given_text) (String.trim canonical_text)
      then Ok ()
      else Error (Token_file_differs { given = path; canonical })
    | Some _ | None -> Ok ()
  in
  let* () = make_directory lane in
  let* () =
    if Sys.file_exists canonical
    then Ok ()
    else
      let* fresh =
        match provided with
        | Some path ->
          let* text = io ~step:"read" ~path (fun () -> read_file path) in
          Ok (String.trim text)
        | None -> Ok (hex (Crypto_rng.generate token_bytes))
      in
      create_token_if_absent ~canonical ~value:fresh
  in
  let token_file = Option.value provided ~default:canonical in
  if not (nonempty_regular_file canonical)
  then Error (Lane_token_unusable canonical)
  else
    let* () = io ~step:"restrict" ~path:token_file (fun () -> Unix.chmod token_file 0o600) in
    let* () = io ~step:"restrict" ~path:canonical (fun () -> Unix.chmod canonical 0o600) in
    Ok (canonical, token_file)

let launcher_script ~host ~base_path ~token_file =
  (* The launcher names no server. The host reads the port from the workspace
     connection.toml and, after a failed request, moves only to an address that
     answers the lane; a port written here would outlive a restart. No token
     value is written here either: only the file that holds it. Firefox
     supplies the manifest path and the extension id, which "$@" forwards. *)
  Printf.sprintf
    "#!/bin/sh\nexec %s --base-path %s --token-file %s \"$@\"\n"
    (Filename.quote host)
    (Filename.quote base_path)
    (Filename.quote token_file)

let native_manifest ~host_name ~launcher ~extension_id =
  Yojson.Safe.pretty_to_string ~std:true
    (`Assoc
       [ "name", `String (Host_name.to_string host_name)
       ; "description", `String "MASC OCaml Firefox browser lane host"
       ; "path", `String launcher
       ; "type", `String "stdio"
       ; "allowed_extensions", `List [ `String extension_id ]
       ])
  ^ "\n"

let install request =
  let base_path = request.base_path in
  if Filename.is_relative base_path
  then Error (Base_path_not_absolute base_path)
  else
    let* extension_id, extension_files = embedded_extension () in
    let* source = host_source request.binary in
    let lane =
      List.fold_left
        Filename.concat
        base_path
        [ Common.masc_dirname; Common.browser_lane_dirname ]
    in
    let* canonical_token, token_file =
      provision_token ~base_path ~lane ~given:request.token_file
    in
    let host_directory = Browser_lane_launcher.host_directory_path ~base_path in
    let* () = make_directory host_directory in
    let* () = make_directory request.manifest_dir in
    let host = Filename.concat host_directory host_executable_name in
    let* host_bytes = io ~step:"read" ~path:source (fun () -> read_file source) in
    let* () = write_replacing ~mode:0o755 host host_bytes in
    let launcher = Browser_lane_launcher.launcher_path ~base_path in
    let script = launcher_script ~host ~base_path ~token_file in
    let* () = write_replacing ~mode:0o755 launcher script in
    let declaration = Browser_lane_launcher.declaration_path ~base_path in
    let* () =
      write_replacing
        ~mode:0o644
        declaration
        (Browser_lane_launcher.declaration ~launcher_script:script)
    in
    let extension_directory = Filename.concat lane "extension" in
    let* () = make_directory extension_directory in
    let* () =
      List.fold_left
        (fun previous (name, contents) ->
           let* () = previous in
           let path = Filename.concat extension_directory name in
           let* () = make_directory (Filename.dirname path) in
           write_replacing ~mode:0o644 path contents)
        (Ok ())
        extension_files
    in
    let manifest =
      Filename.concat
        request.manifest_dir
        (Host_name.to_string request.host_name ^ ".json")
    in
    let* () =
      write_replacing
        ~mode:0o644
        manifest
        (native_manifest ~host_name:request.host_name ~launcher ~extension_id)
    in
    Ok
      { host
      ; launcher
      ; declaration
      ; manifest
      ; token = canonical_token
      ; extension_directory
      ; extension_manifest = Filename.concat extension_directory extension_manifest_name
      }
