type mode = Extension

let refuse message =
  prerr_endline message;
  1

let observation ~base_path =
  Masc.Browser_lane_launcher.observe
    ~base_path
    ~server:Masc.Browser_lane_launcher.Not_serving

(* The sentence {!Masc.Browser_lane_launcher.message} says what is left to do,
   and it names this command whenever the lane is not installed. *)
let show ~base_path =
  Printf.printf "Browser lane for %s\n" base_path;
  print_endline (Masc.Browser_lane_launcher.message (observation ~base_path));
  0

let manifest_directory ~manifest_dir =
  match manifest_dir with
  | Some directory -> Ok directory
  | None ->
    (match Sys.getenv_opt "HOME", Masc.Browser_lane_setup.current_platform () with
     | (None | Some ""), _ ->
       Error "HOME is not set, so Firefox's manifest directory is unknown. Name it with --manifest-dir."
     | Some _, None ->
       Error
         "This installer supports macOS and Linux. Name Firefox's native messaging \
          directory with --manifest-dir."
     | Some home, Some platform ->
       Ok (Masc.Browser_lane_setup.default_manifest_directory ~home platform))

let host_name = function
  | None -> Ok Masc.Browser_lane_setup.Host_name.default
  | Some name ->
    Masc.Browser_lane_setup.Host_name.of_string name
    |> Result.map_error (fun message -> "--host-name: " ^ message)

let after_install ~base_path (installed : Masc.Browser_lane_setup.installed) =
  Printf.printf "Installed the browser lane host for %s\n" base_path;
  Printf.printf "  host        %s (copied from %s)\n" installed.host installed.host_source;
  Printf.printf "  launcher    %s\n" installed.launcher;
  Printf.printf "  manifest    %s\n" installed.manifest;
  Printf.printf "  extension   %s\n" installed.extension_directory;
  Printf.printf "  lane token  %s\n" installed.token;
  print_endline "";
  print_endline "Next, in Firefox:";
  print_endline "  1. Open about:debugging#/runtime/this-firefox";
  print_endline "  2. Choose \"Load Temporary Add-on...\"";
  Printf.printf "  3. Select %s\n" installed.extension_manifest;
  print_endline
    "Firefox forgets a temporary add-on when it quits, so load it again after you restart \
     Firefox.";
  print_endline "";
  print_endline (Masc.Browser_lane_launcher.message (observation ~base_path));
  0

let install ~base_path ~binary ~token_file ~manifest_dir ~host_name:requested =
  match host_name requested, manifest_directory ~manifest_dir with
  | Error message, _ | _, Error message -> refuse message
  | Ok host_name, Ok manifest_dir ->
    (match
       Masc.Browser_lane_setup.install
         { Masc.Browser_lane_setup.base_path; binary; token_file; manifest_dir; host_name }
     with
     | Ok installed -> after_install ~base_path installed
     | Error error -> refuse (Masc.Browser_lane_setup.error_message error))

let run ~base_path ~mode ~binary ~token_file ~manifest_dir ~host_name =
  match mode with
  | None -> show ~base_path
  | Some Extension -> install ~base_path ~binary ~token_file ~manifest_dir ~host_name
