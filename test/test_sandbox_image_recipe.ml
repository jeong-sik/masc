(* The general sandbox recipe against the argv a Keeper turn is actually run
   as. These are not style checks: each one names something the turn does, so a
   package dropped from the recipe fails here rather than at a Keeper's first
   tool call inside a container nobody can install into. *)

open Alcotest

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec scan i =
    if i + nl > hl then false
    else if String.equal (String.sub haystack i nl) needle then true
    else scan (i + 1)
  in
  nl = 0 || scan 0

let assert_present label needle =
  check bool label true (contains Keeper_sandbox_image.dockerfile needle)

(* keeper_sandbox_docker.ml runs the turn as [<image> bash -l -s]. *)
let test_recipe_installs_bash () = assert_present "bash" "bash"

(* keeper_workspace_read_ops.ml: "rg executable not found; Grep requires rg". *)
let test_recipe_installs_ripgrep () = assert_present "ripgrep" "ripgrep"

(* A Keeper reports what it changed out of history and diffs. *)
let test_recipe_installs_git () = assert_present "git" "git"

(* The container runs as the host operator's uid, which the image has no entry
   for. Without a writable HOME a login shell and git both land nowhere. *)
let test_recipe_gives_an_arbitrary_uid_a_home () =
  assert_present "home dir created" "/home/keeper";
  assert_present "home is world-writable" "chmod 0777";
  assert_present "HOME points at it" "ENV HOME="

(* The recipe is fed to [docker build -] on stdin. A COPY would need a context
   that an installed binary does not have, which is the whole reason MASC's own
   development image cannot be built away from a checkout. *)
let test_recipe_needs_no_build_context () =
  check bool "no COPY" false (contains Keeper_sandbox_image.dockerfile "\nCOPY ");
  check bool "no ADD" false (contains Keeper_sandbox_image.dockerfile "\nADD ")

let test_build_argv_reads_the_recipe_from_stdin () =
  check
    (list string)
    "docker build -t <tag> -"
    [ "build"; "-t"; "masc-sandbox:general"; "-" ]
    (Keeper_sandbox_image.build_argv ~tag:Keeper_sandbox_image.default_tag)

(* A Keeper that names no image gets the general one, under Docker and under
   microVM alike -- both guest paths read this same default
   (keeper_sandbox_factory.resolve_guest). The Keepers that want MASC's own
   development image name it; this is what the rest get. *)
let test_runtime_default_is_the_general_image () =
  (* Read the env the same way the resolver does rather than assume it is
     unset: a host with an override is a correct configuration, not a failing
     test, and the override winning is the other half of the contract. *)
  match Sys.getenv_opt "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" with
  | Some override when String.trim override <> "" ->
    check string "an override wins over the default" override
      (Env_config_sandbox.Runtime.docker_image ())
  | _ ->
    check string "unset env resolves to the general tag"
      Keeper_sandbox_image.default_tag
      (Env_config_sandbox.Runtime.docker_image ())

let () =
  run "Sandbox image recipe"
    [ ( "dockerfile"
      , [ test_case "installs bash" `Quick test_recipe_installs_bash
        ; test_case "installs ripgrep" `Quick test_recipe_installs_ripgrep
        ; test_case "installs git" `Quick test_recipe_installs_git
        ; test_case "gives an arbitrary uid a home" `Quick
            test_recipe_gives_an_arbitrary_uid_a_home
        ; test_case "needs no build context" `Quick test_recipe_needs_no_build_context
        ] )
    ; ( "build_argv"
      , [ test_case "reads the recipe from stdin" `Quick
            test_build_argv_reads_the_recipe_from_stdin
        ] )
    ; ( "runtime default"
      , [ test_case "is the general image" `Quick
            test_runtime_default_is_the_general_image
        ] )
    ]
