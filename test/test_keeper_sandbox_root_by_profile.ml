(** Which directory a keeper can be handed a file in.

    A keeper reads paths relative to its own sandbox root and refuses anything
    outside it: measured on a live workspace, [/tmp] comes back as
    [path_outside_sandbox] and a workspace-relative path is simply not found,
    while a file placed in the root and named bare is read.

    The root is not one place. A local keeper's is
    [.masc/playground/<name>/]; a Docker keeper's has a [docker] directory in
    the middle. Anything writing a file for a keeper to read has to ask rather
    than assume, and this is what it gets back. *)

open Alcotest

let with_workspace declare f =
  let base = Filename.temp_file "masc-sandbox-root" "" in
  Sys.remove base;
  let keepers = Filename.concat (Filename.concat (Filename.concat base ".masc") "config") "keepers" in
  let rec mkdir_p path =
    if not (Sys.file_exists path) then begin
      mkdir_p (Filename.dirname path);
      Sys.mkdir path 0o755
    end
  in
  mkdir_p keepers;
  List.iter
    (fun (name, profile) ->
      let channel = open_out (Filename.concat keepers (name ^ ".toml")) in
      Fun.protect
        ~finally:(fun () -> close_out_noerr channel)
        (fun () ->
          Printf.fprintf channel "[keeper]\nsandbox_profile = %S\n" profile))
    declare;
  Fun.protect ~finally:(fun () -> ()) (fun () -> f base)
;;

let root base name =
  Keeper_sandbox_config.host_root_abs_of_agent ~base_path:base ~agent_name:name
;;

(* The two profiles differ by a directory, and that directory is the whole
   difference between a file the keeper reads and one it never sees. *)
let test_the_profile_decides_the_root () =
  with_workspace [ ("plain", "local"); ("boxed", "docker") ] (fun base ->
      check string "a local keeper's own directory"
        (Filename.concat base ".masc/playground/plain/")
        (root base "plain");
      check string "a Docker keeper's, one level in"
        (Filename.concat base ".masc/playground/docker/boxed/")
        (root base "boxed"))
;;

(* A keeper with no TOML is local, because that is what the resolver defaults
   to -- asserted rather than assumed, since a wrong default writes files into
   a directory nothing reads. *)
let test_no_declaration_is_local () =
  with_workspace [] (fun base ->
      check string "the default root"
        (Filename.concat base ".masc/playground/undeclared/")
        (root base "undeclared"))
;;

(* Tool callers name keepers canonically. Both spellings have to land in one
   directory or a file written under one name is invisible under the other. *)
let test_the_canonical_agent_name_resolves_the_same () =
  with_workspace [ ("boxed", "docker") ] (fun base ->
      check string "wrapper stripped" (root base "boxed")
        (root base "keeper-boxed-agent"))
;;

let () =
  run
    "keeper_sandbox_root_by_profile"
    [ ( "root"
      , [ test_case "the profile decides the root" `Quick
            test_the_profile_decides_the_root
        ; test_case "no declaration is local" `Quick test_no_declaration_is_local
        ; test_case "the canonical agent name resolves the same" `Quick
            test_the_canonical_agent_name_resolves_the_same
        ] )
    ]
;;
