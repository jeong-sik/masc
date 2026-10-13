module Launcher = Masc.Browser_lane_launcher
module Setup = Masc.Browser_lane_setup
module Bidi_setup = Masc.Browser_lane_bidi_setup

type mode = Launcher.route

let refuse message =
  prerr_endline message;
  1

let ( let* ) = Result.bind

let observation ~base_path = Launcher.observe ~base_path ~server:Launcher.Not_serving

(* What the lane says is left to do. It names this command whenever the lane is
   not installed. *)
let print_lane_state ~base_path = print_endline (Launcher.message (observation ~base_path))

let show ~base_path =
  Printf.printf "Browser lane for %s\n" base_path;
  print_lane_state ~base_path;
  0

let manifest_directory ~manifest_dir =
  match manifest_dir with
  | Some directory -> Ok directory
  | None ->
    (match Sys.getenv_opt "HOME", Setup.current_platform () with
     | (None | Some ""), _ ->
       Error "HOME is not set, so Firefox's manifest directory is unknown. Name it with --manifest-dir."
     | Some _, None ->
       Error
         "This installer supports macOS and Linux. Name Firefox's native messaging \
          directory with --manifest-dir."
     | Some home, Some platform -> Ok (Setup.default_manifest_directory ~home platform))

let host_name = function
  | None -> Ok Setup.Host_name.default
  | Some name ->
    Setup.Host_name.of_string name |> Result.map_error (fun message -> "--host-name: " ^ message)

(* An option only some routes use. Naming one where no chosen route uses it is
   refused: it would otherwise be accepted and do nothing. *)
let misplaced ~modes options =
  List.find_map
    (fun (flag, given, routes) ->
       if given && not (List.exists (fun route -> List.mem route modes) routes)
       then
         Some
           (Printf.sprintf "%s only applies with %s." flag
              (String.concat " or "
                 (List.map (fun route -> "--mode " ^ Launcher.route_name route) routes)))
       else None)
    options

let extension_route ~modes ~manifest_dir ~host_name:requested =
  if not (List.mem Launcher.Extension modes)
  then Ok None
  else
    let* host_name = host_name requested in
    let* manifest_dir = manifest_directory ~manifest_dir in
    Ok (Some { Setup.manifest_dir; host_name })

let bidi_plan ~modes ~runtime_config_path ~firefox ~profile ~port =
  if not (List.mem Launcher.Bidi modes)
  then Ok None
  else
    Bidi_setup.plan
      ~find_firefox:Bidi_setup.installed_firefox
      { Bidi_setup.runtime_config_path
      ; home = Sys.getenv_opt "HOME"
      ; firefox
      ; profile
      ; port
      }
    |> Result.map Option.some
    |> Result.map_error Bidi_setup.error_message

let print_installed ~base_path (installed : Setup.installed) =
  Printf.printf "Installed the browser lane host for %s\n" base_path;
  Printf.printf "  host        %s (copied from %s)\n" installed.host installed.host_source;
  Printf.printf "  launcher    %s\n" installed.launcher;
  Option.iter
    (fun (extension : Setup.extension_installed) ->
       Printf.printf "  manifest    %s\n" extension.native_manifest;
       Printf.printf "  extension   %s\n" extension.directory)
    installed.extension;
  Printf.printf "  lane token  %s\n" installed.token

let print_extension_steps (extension : Setup.extension_installed) =
  print_endline "";
  print_endline "Next, in Firefox:";
  print_endline "  1. Open about:debugging#/runtime/this-firefox";
  print_endline "  2. Choose \"Load Temporary Add-on...\"";
  Printf.printf "  3. Select %s\n" extension.load;
  print_endline
    "Firefox forgets a temporary add-on when it quits, so load it again after you restart \
     Firefox."

let key_names keys = String.concat ", " (List.map Bidi_setup.key_name keys)

let print_table ~runtime_config_path plan (applied : Bidi_setup.applied) =
  let { Browser_configuration.firefox; profile; port } = Bidi_setup.table plan in
  print_endline "";
  (match Bidi_setup.change plan with
   | Bidi_setup.Created ->
     Printf.printf "Wrote [browser.live.bidi] to %s:\n" runtime_config_path
   | Bidi_setup.Updated keys ->
     Printf.printf "Changed %s in [browser.live.bidi] of %s:\n" (key_names keys)
       runtime_config_path
   | Bidi_setup.Unchanged ->
     Printf.printf
       "[browser.live.bidi] in %s was already there and is left as it is. To change a value, \
        name it with --firefox, --profile or --port:\n"
       runtime_config_path);
  Printf.printf "  firefox  %s\n" firefox;
  Printf.printf "  profile  %s%s\n" profile (if applied.profile_created then " (created)" else "");
  Printf.printf "  port     %d\n" port

let print_bidi_steps plan =
  let { Browser_configuration.port; _ } = Bidi_setup.table plan in
  print_endline "";
  print_endline "Next, for the Firefox MASC starts:";
  print_endline
    "  1. Restart the MASC server. It reads runtime.toml when it starts, then opens this \
     Firefox on the profile above and attaches its host. The server must be this build or \
     newer: an older one does not know the table.";
  print_endline
    "  2. In that Firefox, log in once to the sites the Keepers work on. The profile keeps \
     the logins.";
  if Bidi_setup.port_answers plan
  then
    Printf.printf
      "Something already answers on 127.0.0.1:%d. If that is a Firefox MASC did not start, \
       quit it before restarting the server: one Firefox holds the port, and the host \
       refuses a Firefox that runs another profile.\n"
      port;
  print_endline
    "Firefox's remote debugging port has no authentication: any program on this computer \
     can drive that browser and read its cookies. Keep this profile to the logins the \
     Keepers need."

let print_bidi_state ~base_path ~runtime_config_path =
  let configuration = Result.to_option (Browser_configuration.of_file runtime_config_path) in
  print_endline
    (Masc.Browser_bidi_host_status.message
       (Masc.Browser_bidi_host_status.observe ~base_path ~configuration))

let print_both_routes =
  "With both routes connected the live lane has two browsers, and a request that names no \
   connection is refused as ambiguous_browser_clients."

let install
      ~base_path
      ~runtime_config_path
      ~modes
      ~binary
      ~token_file
      ~manifest_dir
      ~host_name
      ~firefox
      ~profile
      ~port
  =
  let planned =
    let* extension = extension_route ~modes ~manifest_dir ~host_name in
    let* bidi = bidi_plan ~modes ~runtime_config_path ~firefox ~profile ~port in
    Ok (extension, bidi)
  in
  match planned with
  | Error message -> refuse message
  | Ok (extension, bidi) ->
    (match Setup.install { Setup.base_path; binary; token_file; extension } with
     | Error error -> refuse (Setup.error_message error)
     | Ok installed ->
       print_installed ~base_path installed;
       (* The table is written after the lane: the server starts nothing for a
          lane that is not installed, and a table whose host is installed is
          the order a failure leaves harmless. *)
       let tabled =
         match bidi with
         | None -> Ok None
         | Some plan ->
           Bidi_setup.apply plan
           |> Result.map (fun applied -> Some (plan, applied))
           |> Result.map_error Bidi_setup.error_message
       in
       (match tabled with
        | Error message -> refuse message
        | Ok tabled ->
          Option.iter print_extension_steps installed.extension;
          Option.iter
            (fun (plan, applied) ->
               print_table ~runtime_config_path plan applied;
               print_bidi_steps plan)
            tabled;
          if List.length modes > 1 then (print_endline ""; print_endline print_both_routes);
          print_endline "";
          if Option.is_some installed.extension then print_lane_state ~base_path;
          if Option.is_some tabled then print_bidi_state ~base_path ~runtime_config_path;
          0))

let run
      ~base_path
      ~runtime_config_path
      ~modes
      ~binary
      ~token_file
      ~manifest_dir
      ~host_name
      ~firefox
      ~profile
      ~port
  =
  let modes = List.filter (fun route -> List.mem route modes) Launcher.routes in
  let both = Launcher.routes in
  match
    misplaced
      ~modes
      [ "--binary", Option.is_some binary, both
      ; "--token-file", Option.is_some token_file, both
      ; "--manifest-dir", Option.is_some manifest_dir, [ Launcher.Extension ]
      ; "--host-name", Option.is_some host_name, [ Launcher.Extension ]
      ; "--firefox", Option.is_some firefox, [ Launcher.Bidi ]
      ; "--profile", Option.is_some profile, [ Launcher.Bidi ]
      ; "--port", Option.is_some port, [ Launcher.Bidi ]
      ]
  with
  | Some message -> refuse message
  | None ->
    (match modes with
     | [] -> show ~base_path
     | _ :: _ ->
       install
         ~base_path
         ~runtime_config_path
         ~modes
         ~binary
         ~token_file
         ~manifest_dir
         ~host_name
         ~firefox
         ~profile
         ~port)
