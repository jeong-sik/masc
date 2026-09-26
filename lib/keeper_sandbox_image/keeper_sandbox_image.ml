(* The recipe's one source is sandbox-images/base/Dockerfile. The rule in this
   directory's dune file copies it into [Keeper_sandbox_image_base_recipe] at
   build time, because the thing that needs it is a binary installed somewhere
   else entirely: carrying it is what makes `masc sandbox-image` work on a host
   that never had a checkout. It is also why the recipe carries no COPY:
   `docker build -` reads it on stdin with no context. *)

let default_tag = "masc-sandbox:general"

(* What a Keeper turn needs from any image, read off the argv it is run as
   (keeper_sandbox_docker.ml): `<image> bash -l -s` with the tool script on
   stdin, `--user <host uid>:<gid>`, a read-only rootfs plus one tmpfs, and
   --cap-drop=ALL. So bash has to be here, ripgrep has to be here because Grep
   refuses without it, and git has to be here because a Keeper that cannot read
   history cannot say what changed. Nothing else is assumed: a project's own
   toolchain belongs in that project's image, named per Keeper with
   sandbox_image. *)
let dockerfile = Keeper_sandbox_image_base_recipe.dockerfile

let build_argv ~tag = [ "build"; "-t"; tag; "-" ]

let write_recipe_into ~dir =
  let path = Filename.concat dir "Dockerfile" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc dockerfile);
  path

let context_directory_build_argv ~tag ~dockerfile ~context =
  [ "build"; "-t"; tag; "-f"; dockerfile; context ]
