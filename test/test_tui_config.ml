(* The TUI reads its own keys out of the [tui] table of runtime.toml. The file
   read and path resolution are the server's shared machinery; what is worth
   pinning is that a [tui].theme is picked up and that every absence -- no
   table, no key, empty file -- reads as "no stored choice" so the caller falls
   back to following the terminal. *)

module Config = Masc_tui_config
module Toml = Keeper_toml_loader

let doc_of s =
  match Toml.parse_toml s with
  | Ok d -> d
  | Error e -> Alcotest.failf "runtime.toml fixture did not parse: %s" e

let theme_of s = Config.theme_of_doc (doc_of s)
let check_opt = Alcotest.(check (option string))

let cases =
  [ Alcotest.test_case "reads [tui] theme" `Quick (fun () ->
        check_opt "monokai" (Some "monokai")
          (theme_of "[tui]\ntheme = \"monokai\"\n"))
  ; Alcotest.test_case "a different theme name reads through" `Quick (fun () ->
        check_opt "solarized" (Some "solarized-dark")
          (theme_of "[tui]\ntheme = \"solarized-dark\"\n"))
  ; Alcotest.test_case "no [tui] table -> None" `Quick (fun () ->
        check_opt "none" None
          (theme_of "[turn]\nstream_idle_timeout_sec = 120\n"))
  ; Alcotest.test_case "[tui] present but no theme -> None" `Quick (fun () ->
        check_opt "none" None (theme_of "[tui]\nsomething_else = 1\n"))
  ; Alcotest.test_case "empty file -> None" `Quick (fun () ->
        check_opt "none" None (theme_of ""))
  ]

(* The IO path: a runtime.toml under [base]/.masc/config is the same file the
   server reads, so [theme ~base_path] must resolve to it. A missing file reads
   as no choice, not a crash. *)
let with_temp_base f =
  let base = Filename.temp_file "masc_tui_config_base" "" in
  Sys.remove base;
  Unix.mkdir base 0o755;
  let masc = Filename.concat base ".masc" in
  let config = Filename.concat masc "config" in
  Unix.mkdir masc 0o755;
  Unix.mkdir config 0o755;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove (Filename.concat config "runtime.toml") with _ -> ());
      (try Unix.rmdir config with _ -> ());
      (try Unix.rmdir masc with _ -> ());
      try Unix.rmdir base with _ -> ())
    (fun () -> f ~base ~config)

let write path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let io_cases =
  [ Alcotest.test_case "reads theme from the base's runtime.toml" `Quick
      (fun () ->
        with_temp_base (fun ~base ~config ->
            write (Filename.concat config "runtime.toml")
              "[tui]\ntheme = \"monokai\"\n";
            check_opt "monokai" (Some "monokai") (Config.theme ~base_path:base)))
  ; Alcotest.test_case "a base with no runtime.toml reads as no choice" `Quick
      (fun () ->
        with_temp_base (fun ~base ~config:_ ->
            check_opt "none" None (Config.theme ~base_path:base)))
  ]

let () =
  Alcotest.run "tui_config"
    [ ("theme_of_doc", cases); ("theme_io", io_cases) ]
