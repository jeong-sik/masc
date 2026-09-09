(** Which directory a keeper can be handed a file in.

    A keeper reads paths relative to its own sandbox root and refuses anything
    outside it: measured on a live workspace, [/tmp] comes back as
    [path_outside_sandbox] and a workspace-relative path is simply not found,
    while a file placed in the root and named bare is read.

    The root is not one place: a Docker keeper's has a [docker] directory in
    the middle of it. Anything writing a file for a keeper to read has to ask
    rather than assume, and this is what it gets back.

    It used to say a local keeper's root is [.masc/playground/<name>/] and
    that a keeper declaring nothing takes it. #32078 removed that arm -- a
    keeper runs under docker, microvm or ssh, or not at all -- so declaring
    "local" now raises and declaring nothing has no root to take. Those two
    cases are gone; the refusal is asserted in their place. *)

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

(* The profile puts a directory in the middle, and that directory is the whole
   difference between a file the keeper reads and one it never sees. *)
let test_the_profile_decides_the_root () =
  with_workspace [ ("boxed", "docker") ] (fun base ->
      check string "a Docker keeper's, one level in"
        (Filename.concat base ".masc/playground/docker/boxed/")
        (root base "boxed"))
;;

(* A keeper that declares no profile has no root. Asserted rather than left
   out, because the thing that used to happen here -- falling through to a
   default -- is what wrote files into a directory nothing reads. *)
let test_no_declaration_has_no_root () =
  with_workspace [] (fun base ->
      match root base "undeclared" with
      | answer ->
        failf "a keeper declaring no profile answered with a root: %S" answer
      | exception Keeper_sandbox_config.Invalid_keeper_sandbox_config _ -> ())
;;

let () =
  run
    "keeper_sandbox_root_by_profile"
    [ ( "root"
      , [ test_case "the profile decides the root" `Quick
            test_the_profile_decides_the_root
        ; test_case "no declaration has no root" `Quick
            test_no_declaration_has_no_root
        ] )
    ]
;;
