(* The version reported to the outside world, read from the linked
   dune-build-info metadata so it follows `dune-project` without a second
   place to edit.

   This is a leaf so that every layer can reach it. It used to live inside
   `masc_runtime`, which the gate connectors do not depend on, so those two
   spelled their version as a literal — and it said 0.1 while the project said
   0.21.2. *)
let current =
  match Build_info.V1.version () with
  | None -> "dev"
  | Some version -> Build_info.V1.Version.to_string version
;;
