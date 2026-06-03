(* Source-layout guard for the PR-R runtime boundary prep slice.

   [Provider_tool_support] is the runtime/OAS capability projection used by
   runtime transport and runtime filtering. It must live under [lib/runtime/],
   not in the mega-lib root, so the eventual [lib/runtime/dune] extraction can
   collect runtime-owned helpers without rediscovering this root leak. *)

let assert_file_exists path =
  if not (Sys.file_exists path)
  then failwith (Printf.sprintf "expected file to exist: %s" path)
;;

let assert_file_absent path =
  if Sys.file_exists path
  then failwith (Printf.sprintf "expected file to be absent: %s" path)
;;

let () =
  assert_file_exists "lib/runtime/provider_tool_support.ml";
  assert_file_exists "lib/runtime/provider_tool_support.mli";
  assert_file_absent "lib/provider_tool_support.ml";
  assert_file_absent "lib/provider_tool_support.mli";
  print_endline "test_runtime_provider_tool_support_boundary: OK"
;;
