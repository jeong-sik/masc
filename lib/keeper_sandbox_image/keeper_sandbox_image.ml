(* The recipe's one source is sandbox-images/base/Dockerfile. The rule in this
   directory's dune file copies it into [Keeper_sandbox_image_base_recipe] at
   build time, because the thing that needs it is a binary installed somewhere
   else entirely: carrying it is what makes `masc sandbox-image` work on a host
   that never had a checkout. It is also why the recipe carries no COPY:
   `docker build -` reads it on stdin with no context. *)

(* What a Keeper turn needs from any image, read off the argv it is run as
   (keeper_sandbox_docker.ml): `<image> bash -l -s` with the tool script on
   stdin, `--user <host uid>:<gid>`, a read-only rootfs plus one tmpfs, and
   --cap-drop=ALL. So bash has to be here, ripgrep has to be here because Grep
   refuses without it, and git has to be here because a Keeper that cannot read
   history cannot say what changed. Nothing else is assumed: a project's own
   toolchain belongs in that project's image, named per Keeper with
   sandbox_image. *)
let dockerfile = Keeper_sandbox_image_base_recipe.dockerfile

let label_argv labels =
  List.concat_map (fun (key, value) -> [ "--label"; key ^ "=" ^ value ]) labels

let build_argv ?(labels = []) ~tag () =
  [ "build"; "-t"; tag ] @ label_argv labels @ [ "-" ]

let context_directory_build_argv ?(labels = []) ~tag ~dockerfile ~context () =
  [ "build"; "-t"; tag ] @ label_argv labels @ [ "-f"; dockerfile; context ]
