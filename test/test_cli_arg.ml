(** Tests for Cli_arg — positional and flag argument parser. *)

let () =
  let open Cli_arg in
  let test_empty_argv () =
    let specs = [Flag "verbose"] in
    match parse specs [|"prog"|] with
    | Ok result ->
        Alcotest.(check int) "empty positional zero" 0 (List.length result.positional);
        Alcotest.(check string) "flag defaults false" "" (Hashtbl.find result.named "verbose")
    | Error e -> Alcotest.fail (pp_error e)
  in

  let test_boolean_flag () =
    let specs = [Flag "verbose"] in
    match parse specs [|"prog"; "--verbose"|] with
    | Ok result ->
        Alcotest.(check string) "flag true" "true" (Hashtbl.find result.named "verbose")
    | Error e -> Alcotest.fail (pp_error e)
  in

  let test_positional_single () =
    let specs = [Positional "name"] in
    match parse specs [|"prog"; "alice"|] with
    | Ok result ->
        Alcotest.(check string) "positional value" "alice" (Hashtbl.find result.named "name")
    | Error e -> Alcotest.fail (pp_error e)
  in

  let test_positional_missing () =
    let specs = [Positional "name"] in
    match parse specs [|"prog"|] with
    | Error (Missing_positional "name") -> ()
    | Ok _ -> Alcotest.fail "expected Missing_positional error"
    | Error e -> Alcotest.fail (Printf.sprintf "unexpected error: %s" (pp_error e))
  in

  let test_positional_opt_default () =
    let specs = [Positional_opt ("name", "default_name")] in
    match parse specs [|"prog"|] with
    | Ok result ->
        Alcotest.(check string) "positional_opt default" "default_name" (Hashtbl.find result.named "name")
    | Error e -> Alcotest.fail (pp_error e)
  in

  let test_positional_opt_override () =
    let specs = [Positional_opt ("name", "default_name")] in
    match parse specs [|"prog"; "alice"|] with
    | Ok result ->
        Alcotest.(check string) "positional_opt override" "alice" (Hashtbl.find result.named "name")
    | Error e -> Alcotest.fail (pp_error e)
  in

  let test_option_with_value () =
    let specs = [Option "output"] in
    match parse specs [|"prog"; "--output", "out.txt"|] with
    | Ok result ->
        Alcotest.(check string) "option value" "out.txt" (Hashtbl.find result.named "output")
    | Error e -> Alcotest.fail (pp_error e)
  in

  let test_option_missing_value () =
    let specs = [Option "output"] in
    match parse specs [|"prog"; "--output"|] with
    | Error (Missing_value "output") -> ()
    | Ok _ -> Alcotest.fail "expected Missing_value error"
    | Error e -> Alcotest.fail (Printf.sprintf "unexpected error: %s" (pp_error e))
  in

  let test_unknown_flag () =
    let specs = [Flag "verbose"] in
    match parse specs [|"prog"; "--unknown"|] with
    | Error (Unknown_flag "unknown") -> ()
    | Ok _ -> Alcotest.fail "expected Unknown_flag error"
    | Error e -> Alcotest.fail (Printf.sprintf "unexpected error: %s" (pp_error e))
  in

  let test_double_dash_ends_flags () =
    let specs = [Flag "verbose"; Positional "file"] in
    match parse specs [|"prog"; "--"; "--verbose"; "file.txt"|] with
    | Ok result ->
        Alcotest.(check string) "flag after -- is positional" ""
          (try Hashtbl.find result.named "verbose" with Not_found -> "");
        (* After --, "--verbose" becomes a positional arg *)
        Alcotest.(check int) "one extra positional" 1 (List.length result.positional);
        Alcotest.(check string) "first extra is --verbose" "--verbose" (List.hd result.positional);
        (* The positional spec "file" should also get a value from "file.txt" *)
        Alcotest.(check string) "positional file value" "file.txt" (Hashtbl.find result.named "file")
    | Error e -> Alcotest.fail (pp_error e)
  in

  let test_multiple_positionals_and_flags () =
    let specs = [Flag "verbose"; Flag "quiet"; Positional "input"; Positional "output"] in
    match parse specs [|"prog"; "--verbose"; "in.txt"; "--quiet"; "out.txt"|] with
    | Ok result ->
        Alcotest.(check string) "verbose flag" "true" (Hashtbl.find result.named "verbose");
        Alcotest.(check string) "quiet flag" "true" (Hashtbl.find result.named "quiet");
        Alcotest.(check string) "input positional" "in.txt" (Hashtbl.find result.named "input");
        Alcotest.(check string) "output positional" "out.txt" (Hashtbl.find result.named "output")
    | Error e -> Alcotest.fail (pp_error e)
  in

  let test_extra_positionals_saved_in_list () =
    let specs = [Positional "first"] in
    match parse specs [|"prog"; "a"; "b"; "c"|] with
    | Ok result ->
        Alcotest.(check string) "first positional" "a" (Hashtbl.find result.named "first");
        Alcotest.(check int) "extra count" 2 (List.length result.positional);
        Alcotest.(check string) "first extra" "b" (List.nth result.positional 0);
        Alcotest.(check string) "second extra" "c" (List.nth result.positional 1)
    | Error e -> Alcotest.fail (pp_error e)
  in

  let test_option_eq_style () =
    let specs = [Option "output"; Option "name"] in
    match parse specs [|"prog"; "--output=out.txt"; "--name=alice"|] with
    | Ok result ->
        Alcotest.(check string) "option = style output" "out.txt" (Hashtbl.find result.named "output");
        Alcotest.(check string) "option = style name" "alice" (Hashtbl.find result.named "name")
    | Error e -> Alcotest.fail (pp_error e)
  in

  let test_empty_flag_spec_defaults () =
    let specs = [Flag "debug"; Flag "trace"] in
    match parse specs [|"prog"|] with
    | Ok result ->
        Alcotest.(check string) "debug default" "" (Hashtbl.find result.named "debug");
        Alcotest.(check string) "trace default" "" (Hashtbl.find result.named "trace")
    | Error e -> Alcotest.fail (pp_error e)
  in

  let test_mixed_complex () =
    let specs = [
      Flag "verbose";
      Option "output";
      Positional "source";
      Positional_opt ("dest", "./default_dest");
    ] in
    match parse specs [|"prog"; "--verbose"; "--output", "/tmp/out"; "src.txt"|] with
    | Ok result ->
        Alcotest.(check string) "verbose" "true" (Hashtbl.find result.named "verbose");
        Alcotest.(check string) "output" "/tmp/out" (Hashtbl.find result.named "output");
        Alcotest.(check string) "source" "src.txt" (Hashtbl.find result.named "source");
        Alcotest.(check string) "dest default" "./default_dest" (Hashtbl.find result.named "dest")
    | Error e -> Alcotest.fail (pp_error e)
  in

  Alcotest.run "cli_arg" [
    "parse", [
      Alcotest.test_case "empty argv with flag spec" `Quick test_empty_argv;
      Alcotest.test_case "boolean flag" `Quick test_boolean_flag;
      Alcotest.test_case "single positional" `Quick test_positional_single;
      Alcotest.test_case "missing positional error" `Quick test_positional_missing;
      Alcotest.test_case "positional_opt default" `Quick test_positional_opt_default;
      Alcotest.test_case "positional_opt override" `Quick test_positional_opt_override;
      Alcotest.test_case "option with value" `Quick test_option_with_value;
      Alcotest.test_case "option missing value error" `Quick test_option_missing_value;
      Alcotest.test_case "unknown flag error" `Quick test_unknown_flag;
      Alcotest.test_case "double-dash ends flags" `Quick test_double_dash_ends_flags;
      Alcotest.test_case "multiple positionals and flags" `Quick test_multiple_positionals_and_flags;
      Alcotest.test_case "extra positionals saved" `Quick test_extra_positionals_saved_in_list;
      Alcotest.test_case "option=value style" `Quick test_option_eq_style;
      Alcotest.test_case "flag defaults to empty" `Quick test_empty_flag_spec_defaults;
      Alcotest.test_case "mixed complex parse" `Quick test_mixed_complex;
    ];
  ]