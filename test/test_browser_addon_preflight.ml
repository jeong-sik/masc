open Alcotest
module P = Masc.Browser_addon_preflight

(* An owned browser source two enabled declarations serve is used by
   neither, so the deployment refuses it before anything is stopped; the
   declarations stay the operator's to change. *)

let write path text =
  let rec make directory =
    if not (Sys.file_exists directory) then (
      make (Filename.dirname directory);
      Unix.mkdir directory 0o700)
  in
  make (Filename.dirname path);
  Out_channel.with_open_bin path (fun out -> output_string out text)

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Sys.remove path

(* The config root comes from this workspace only. *)
let with_workspace f =
  let base = Filename.temp_dir "browser-addon-preflight-" "" in
  let previous = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Unix.putenv "MASC_CONFIG_DIR" "";
  Config_dir_resolver.reset ();
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "MASC_CONFIG_DIR" (Option.value previous ~default:"");
      Config_dir_resolver.reset ();
      remove base)
    (fun () -> f base)

let declaration_directory base =
  List.fold_left Filename.concat base [ ".masc"; "config"; "lane-addons" ]

(* An enabled declaration [id] of a package that serves only [source]. *)
let declare_one_source base id source =
  let package = List.fold_left Filename.concat base [ "packages"; id; "lane.toml" ] in
  write package
    (Printf.sprintf
       "id = %S\nrevision = \"1\"\ntitle = \"Browser\"\nruntime = \"host_process\"\nservice = \"browser\"\nbrowser_backend = %S\ncommand = [\"masc-browser-addon-worker\"]\ncontributions = [\"observe\"]\n[resources]\nmax_reply_bytes = 4096\n"
       id source);
  write
    (Filename.concat (declaration_directory base) (id ^ ".toml"))
    (Printf.sprintf "id = %S\nrun_id = %S\nmanifest_path = %S\n[binding]\nsources = []\n" id (id ^ "-work") package)

(* One declaration per source passes; a second one of the owned source is
   named with the first and refused. *)
let test_a_source_two_declarations_serve_is_refused () =
  with_workspace @@ fun base ->
  declare_one_source base "browser-firefox" "owned_firefox";
  declare_one_source base "browser-ego" "ego";
  check bool "one declaration per source passes" true
    (P.doubled_sources ~base_path:base = [] && P.report_doubled [] = Ok ());
  declare_one_source base "browser-firefox-second" "owned_firefox";
  check bool "the doubled source is named with its declarations" true
    (match P.doubled_sources ~base_path:base with
     | [ { P.source = Browser_lane.Backend.Owned_firefox; ids } ] ->
       List.sort String.compare ids = [ "browser-firefox"; "browser-firefox-second" ]
     | _ :: _ | [] -> false);
  check bool "and the deployment is refused" true
    (Result.is_error (P.report_doubled (P.doubled_sources ~base_path:base)))

let () =
  run "browser addon preflight"
    [ ( "doubled sources"
      , [ test_case "a source two declarations serve is refused" `Quick
            test_a_source_two_declarations_serve_is_refused
        ] )
    ]
