let () =
  let open Alcotest in
  let module S = Coord_utils_backend_setup in
  let tc =
    test_case "cache_resolved_base_path short-circuits resolve" `Quick
      (fun () ->
        let cached_path = "/tmp/masc-test-cache-path" in
        S.cache_resolved_base_path cached_path;
        let result = S.resolve_masc_base_path "/some/other/path" in
        check string "returns cached value" cached_path result)
  in
  run __FILE__ [ "coord base path cache", [ tc ] ]
