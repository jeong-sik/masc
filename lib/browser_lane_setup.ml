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

type extension_route =
  { manifest_dir : string
  ; host_name : Host_name.t
  }

type request =
  { base_path : string
  ; binary : string option
  ; token_file : string option
  ; extension : extension_route option
  }

type extension_installed =
  { native_manifest : string
  ; directory : string
  ; load : string
  }

type installed =
  { host : string
  ; host_source : string
  ; launcher : string
  ; declaration : string
  ; token : string
  ; extension : extension_installed option
  }

type error =
  | Base_path_not_absolute of string
  | Host_binary_not_found
  | Host_binary_not_executable of string
  | Token_file_unusable of { path : string; reason : string }
  | Lane_token_unusable of { path : string; reason : string }
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
  | Token_file_unusable { path; reason } ->
    Printf.sprintf
      "--token-file must name a file that holds a lane token, and %s does not: %s."
      path reason
  | Lane_token_unusable { path; reason } ->
    Printf.sprintf
      "The lane token %s is not usable: %s. Remove it and run this again to create a new \
       one."
      path reason
  | Token_file_differs { given; canonical } ->
    Printf.sprintf
      "--token-file %s does not match this workspace's lane token %s. The two must be \
       one token; this command does not choose which is right."
      given canonical
  | Embedded_extension_invalid reason ->
    Printf.sprintf "The extension embedded in this build cannot be installed: %s." reason
  | Io { step; path; reason } -> Printf.sprintf "Could not %s %s: %s" step path reason

type platform = Macos | Linux

(* The same two probes the rest of the codebase uses to tell a mac from a Linux
   host without starting a process: a command that starts one fails on a PATH
   that has no uname, and the architecture is no part of the answer. *)
let current_platform () =
  match Sys.os_type with
  | "Unix" when Sys.file_exists "/System/Library/CoreServices/SystemVersion.plist" ->
    Some Macos
  | "Unix" when Sys.file_exists "/proc/version" -> Some Linux
  | _ -> None

let default_manifest_directory ~home = function
  | Macos ->
    List.fold_left
      Filename.concat
      home
      [ "Library"; "Application Support"; "Mozilla"; "NativeMessagingHosts" ]
  | Linux -> List.fold_left Filename.concat home [ ".mozilla"; "native-messaging-hosts" ]

open Result.Syntax

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

(* [Out_channel.with_open_bin] closes with [close_out_noerr], so a final flush
   that fails (a full disk, a quota) would be swallowed and the short file
   published. [close_out] flushes and raises. *)
let write_file path contents =
  let channel = open_out_bin path in
  match
    output_string channel contents;
    close_out channel
  with
  | () -> ()
  | exception exn ->
    close_out_noerr channel;
    raise exn

(* A file replaced through a temporary file in its own directory and a rename,
   so a reader never sees half of it. [Filename.temp_file] creates it private;
   the final mode is set before the rename. *)
let write_replacing ~mode path contents =
  let directory = Filename.dirname path in
  io ~step:"write" ~path (fun () ->
    let temporary = Filename.temp_file ~temp_dir:directory ".install-" ".partial" in
    match
      write_file temporary contents;
      Unix.chmod temporary mode;
      Unix.rename temporary path
    with
    | () -> ()
    | exception exn ->
      (try Sys.remove temporary with Sys_error _ -> ());
      raise exn)

(* A directory this install will write into: it exists as a directory and the
   caller may create files in it. Checked before the first file is written, so
   a path that is a file, or a directory that is read-only, stops the install
   with nothing left behind instead of after most of it. *)
let prepare_directory path =
  let* () = io ~step:"create" ~path (fun () -> Fs_compat.mkdir_p path) in
  io ~step:"write into" ~path (fun () ->
    if not (Sys.is_directory path) then raise (Sys_error (path ^ " is not a directory"));
    Unix.access path [ Unix.W_OK; Unix.X_OK ])

let real_path path = try Unix.realpath path with Unix.Unix_error _ -> path
let host_executable_name = "masc-browser-host"

(* The host that belongs to this masc is the one installed beside it: they
   were built and installed together, and the extension this binary embeds is
   written for that host's protocol. Both the directory the executable is
   reached through and the one a link resolves to are looked in, since a link
   to masc leaves the host beside the link. An executable name that is not
   absolute says nothing about where it is, so it is not searched. PATH is
   where a hand-installed host is. *)
let beside_this_executable () =
  let executable = Sys.executable_name in
  if Filename.is_relative executable
  then None
  else
    List.find_map
      (fun path ->
         let candidate = Filename.concat (Filename.dirname path) host_executable_name in
         if Executable_path.regular_file_is_executable candidate then Some candidate else None)
      [ real_path executable; executable ]

let on_path () =
  match Sys.getenv_opt "PATH" with
  | None -> None
  | Some raw ->
    Executable_path.split_search_path raw
    |> List.filter (fun directory -> not (String.equal directory ""))
    |> List.find_map (fun directory ->
      let candidate = Filename.concat directory host_executable_name in
      if Executable_path.regular_file_is_executable candidate then Some candidate else None)

let host_source = function
  | Some path ->
    let resolved = real_path path in
    if Executable_path.regular_file_is_executable resolved
    then Ok resolved
    else Error (Host_binary_not_executable path)
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
    let* files =
      List.fold_right
        (fun name collected ->
           let* collected = collected in
           match Embedded_browser_extension.read name with
           | Some contents -> Ok ((name, contents) :: collected)
           | None ->
             Error
               (Embedded_extension_invalid
                  (Printf.sprintf "it lists %s and carries no bytes for it" name)))
        Embedded_browser_extension.file_list
        (Ok [])
    in
    Ok (id, files)

let token_bytes = 24

let hex bytes =
  String.concat
    ""
    (List.init (String.length bytes) (fun index ->
       Printf.sprintf "%02x" (Char.code bytes.[index])))

(* The lane token of this install, read before anything is written. A token
   the host or the server would refuse is refused here, because the lane would
   otherwise fail closed with no word from the installer. *)
type token_plan =
  { canonical : string
  ; token_file : string  (** The file the launcher names. *)
  ; given : (string * Browser_lane.Lane_token.t) option
  ; existing : Browser_lane.Lane_token.t option
  }

let read_token ~path ~unusable =
  match read_file path with
  | exception Sys_error _ -> Error (unusable "it is missing or cannot be read")
  | text ->
    (match Browser_lane.Lane_token.of_text text with
     | Ok token -> Ok token
     | Error refusal -> Error (unusable (Browser_lane.Lane_token.refusal_message refusal)))

let plan_token ~base_path ~lane ~given =
  let canonical = Filename.concat lane Common.browser_lane_token_name in
  let* given =
    match given with
    | None -> Ok None
    | Some path ->
      let path = if Filename.is_relative path then Filename.concat base_path path else path in
      let* token =
        read_token ~path ~unusable:(fun reason -> Token_file_unusable { path; reason })
      in
      Ok (Some (path, token))
  in
  let* existing =
    if Sys.file_exists canonical
    then
      let* token =
        read_token ~path:canonical ~unusable:(fun reason ->
          Lane_token_unusable { path = canonical; reason })
      in
      Ok (Some token)
    else Ok None
  in
  let* () =
    match given, existing with
    | Some (path, token), Some canonical_token
      when not (Browser_lane.Lane_token.equal token canonical_token) ->
      Error (Token_file_differs { given = path; canonical })
    | Some _, Some _ | Some _, None | None, Some _ | None, None -> Ok ()
  in
  Ok
    { canonical
    ; token_file = Option.fold given ~none:canonical ~some:fst
    ; given
    ; existing
    }

(* The canonical token is published whole: written to a private temporary file
   and linked into place, so no reader and no second install ever sees it
   empty, and two installs racing both end with the one token that won the
   link. It is created once and then only read: a host and a server that
   already agreed on it would stop talking if it changed. *)
let publish_token ~lane ~canonical token =
  io ~step:"create" ~path:canonical (fun () ->
    let temporary = Filename.temp_file ~temp_dir:lane ".token-" ".partial" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove temporary with Sys_error _ -> ())
      (fun () ->
         write_file temporary (Browser_lane.Lane_token.to_string token ^ "\n");
         match Unix.link temporary canonical with
         | () -> ()
         | exception Unix.Unix_error (Unix.EEXIST, _, _) -> ()))

(* A provisioned token file is made private, as the launcher names it and the
   host reads it. It is restricted before the canonical token is created from
   it, so a file this process may not restrict leaves no token behind. *)
let provision_token ~lane plan =
  let* () =
    match plan.given with
    | Some (path, _) -> io ~step:"restrict" ~path (fun () -> Unix.chmod path 0o600)
    | None -> Ok ()
  in
  let* () =
    match plan.existing with
    | Some _ -> Ok ()
    | None ->
      let token =
        match plan.given with
        | Some (_, token) -> Ok token
        | None ->
          (* [of_text] is the only way to a token, so a generated one goes
             through it too. 48 hex digits always pass. *)
          (match Browser_lane.Lane_token.of_text (hex (Crypto_rng.generate token_bytes)) with
           | Ok token -> Ok token
           | Error refusal ->
             Error
               (Io
                  { step = "generate"
                  ; path = plan.canonical
                  ; reason = Browser_lane.Lane_token.refusal_message refusal
                  }))
      in
      let* token = token in
      publish_token ~lane ~canonical:plan.canonical token
  in
  io ~step:"restrict" ~path:plan.canonical (fun () -> Unix.chmod plan.canonical 0o600)

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

let native_manifest_text ~host_name ~launcher ~extension_id =
  Yojson.Safe.pretty_to_string ~std:true
    (`Assoc
       [ "name", `String (Host_name.to_string host_name)
       ; "description", `String "MASC OCaml Firefox browser lane host"
       ; "path", `String launcher
       ; "type", `String "stdio"
       ; "allowed_extensions", `List [ `String extension_id ]
       ])
  ^ "\n"

(* What the extension route adds to the host and the launcher: the files of the
   extension this build carries and the manifest that lets Firefox start the
   host for it. Read and checked before the first write, like the rest. *)
type extension_plan =
  { route : extension_route
  ; id : string
  ; files : (string * string) list
  ; directory : string
  }

let plan_extension ~lane = function
  | None -> Ok None
  | Some route ->
    let* id, files = embedded_extension () in
    Ok (Some { route; id; files; directory = Filename.concat lane "extension" })

let prepare_extension = function
  | None -> Ok ()
  | Some plan ->
    let* () = prepare_directory plan.directory in
    let* () = prepare_directory plan.route.manifest_dir in
    List.fold_left
      (fun previous (name, _) ->
         let* () = previous in
         prepare_directory (Filename.dirname (Filename.concat plan.directory name)))
      (Ok ())
      plan.files

let write_extension ~launcher = function
  | None -> Ok None
  | Some plan ->
    let* () =
      List.fold_left
        (fun previous (name, contents) ->
           let* () = previous in
           write_replacing ~mode:0o644 (Filename.concat plan.directory name) contents)
        (Ok ())
        plan.files
    in
    let native_manifest =
      Filename.concat
        plan.route.manifest_dir
        (Host_name.to_string plan.route.host_name ^ ".json")
    in
    let* () =
      write_replacing
        ~mode:0o644
        native_manifest
        (native_manifest_text ~host_name:plan.route.host_name ~launcher ~extension_id:plan.id)
    in
    Ok
      (Some
         { native_manifest
         ; directory = plan.directory
         ; load = Filename.concat plan.directory extension_manifest_name
         })

let install request =
  let base_path = request.base_path in
  if Filename.is_relative base_path
  then Error (Base_path_not_absolute base_path)
  else
    let lane =
      List.fold_left
        Filename.concat
        base_path
        [ Common.masc_dirname; Common.browser_lane_dirname ]
    in
    let* extension = plan_extension ~lane request.extension in
    let* source = host_source request.binary in
    let* plan = plan_token ~base_path ~lane ~given:request.token_file in
    let host_directory = Browser_lane_launcher.host_directory_path ~base_path in
    let* () = prepare_directory lane in
    let* () = prepare_directory host_directory in
    let* () = prepare_extension extension in
    let* host_bytes = io ~step:"read" ~path:source (fun () -> read_file source) in
    let* () = provision_token ~lane plan in
    let host = Filename.concat host_directory host_executable_name in
    let* () = write_replacing ~mode:0o755 host host_bytes in
    let launcher = Browser_lane_launcher.launcher_path ~base_path in
    let script = launcher_script ~host ~base_path ~token_file:plan.token_file in
    let* () = write_replacing ~mode:0o755 launcher script in
    let* extension = write_extension ~launcher extension in
    (* Last: the declaration is what makes the launcher count as installed. *)
    let declaration = Browser_lane_launcher.declaration_path ~base_path in
    let* () =
      write_replacing
        ~mode:0o644
        declaration
        (Browser_lane_launcher.declaration ~launcher_script:script)
    in
    Ok
      { host
      ; host_source = source
      ; launcher
      ; declaration
      ; token = plan.canonical
      ; extension
      }
