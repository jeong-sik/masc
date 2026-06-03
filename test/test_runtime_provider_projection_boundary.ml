open Alcotest

let source_path rel =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  Filename.concat source_root rel
;;

let test_provider_runtime_projection_lives_under_runtime () =
  check
    bool
    "root provider_runtime_projection must stay deleted"
    false
    (Sys.file_exists (source_path "lib/provider_runtime_projection.ml"));
  check
    bool
    "runtime provider_runtime_projection source exists"
    true
    (Sys.file_exists (source_path "lib/runtime/provider_runtime_projection.ml"))
;;

let () =
  run
    "runtime_provider_projection_boundary"
    [ ( "source layout"
      , [ test_case
            "provider runtime projection lives under runtime"
            `Quick
            test_provider_runtime_projection_lives_under_runtime
        ] )
    ]
;;
