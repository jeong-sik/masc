(** Phase 0 SSOT guard for the keeper OUTPUT directory.

    The runtime-keeper directory resolves through a single constant,
    [Common.keepers_runtime_dirname], shared by the two SSOT functions:
    [Common.keepers_runtime_dir_of_base] (base_path-only / cycle-bound callers)
    and [Workspace.keepers_runtime_dir] (cluster-aware callers). These pin the
    CURRENT pre-relocation path. The input/output relocation flips
    [keepers_runtime_dirname] in ONE place; the expected values here update once,
    mirroring that single-line source change. *)

open Alcotest

(* The single literal behind every keeper OUTPUT path. *)
let test_dirname_constant () =
  check string "keeper OUTPUT dir segment" "keepers"
    Common.keepers_runtime_dirname

(* base_path variant resolves to <base>/.masc/keepers (default cluster). *)
let test_of_base_resolves_under_masc () =
  check string "default-cluster keeper OUTPUT dir" "/tmp/base/.masc/keepers"
    (Common.keepers_runtime_dir_of_base ~base_path:"/tmp/base")

(* The base variant must equal masc_dir + the shared dirname constant — i.e. it
   is built from the SSOT constant, not an inlined literal. *)
let test_of_base_uses_constant () =
  check string "of_base is masc_dir ^ dirname constant"
    (Filename.concat
       (Common.masc_dir_from_base_path ~base_path:"/tmp/base")
       Common.keepers_runtime_dirname)
    (Common.keepers_runtime_dir_of_base ~base_path:"/tmp/base")

let () =
  run "keepers_runtime_dir_ssot"
    [ ( "ssot"
      , [ test_case "dirname constant is the single literal" `Quick
            test_dirname_constant
        ; test_case "of_base resolves under .masc" `Quick
            test_of_base_resolves_under_masc
        ; test_case "of_base built from constant" `Quick
            test_of_base_uses_constant
        ] )
    ]
