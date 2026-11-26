open Masc_tui_core
open Masc_tui_app

let empty_env _ = None

let test_rgb_of_hex () =
  Alcotest.(check (result int string)) "with hash" (Ok 0x0B0E14)
    (Theme.rgb_of_hex "#0B0E14");
  Alcotest.(check (result int string)) "without hash" (Ok 0x0B0E14)
    (Theme.rgb_of_hex "0B0E14");
  Alcotest.(check (result int string)) "lowercase" (Ok 0x0B0E14)
    (Theme.rgb_of_hex "#0b0e14");
  Alcotest.(check (result int string)) "blanks" (Ok 0x0B0E14)
    (Theme.rgb_of_hex "  #0B0E14  ");
  Alcotest.(check (result int string)) "white" (Ok 0xFFFFFF)
    (Theme.rgb_of_hex "#FFFFFF");
  (match Theme.rgb_of_hex "#12345" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "short hex must fail");
  (match Theme.rgb_of_hex "#1234567" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "long hex must fail");
  (match Theme.rgb_of_hex "#12GG56" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "non-hex digit must fail");
  (match Theme.rgb_of_hex "" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "empty must fail");
  Alcotest.(check string) "to_hex uppercases" "#0B0E14" (Theme.rgb_to_hex 0x0B0E14);
  List.iter
    (fun preset ->
      let palette = Theme.builtin_palette preset in
      let roundtrip name rgb =
        match Theme.rgb_of_hex (Theme.rgb_to_hex rgb) with
        | Ok back ->
            Alcotest.(check int)
              (Theme.preset_name preset ^ " " ^ name ^ " round-trip")
              rgb back
        | Error reason ->
            Alcotest.fail (Theme.preset_name preset ^ " " ^ name ^ ": " ^ reason)
      in
      roundtrip "surface_0" palette.surface_0;
      roundtrip "text_bright" palette.text_bright;
      let c0, c1, c2 = palette.cool_stops in
      roundtrip "cool_0" c0;
      roundtrip "cool_1" c1;
      roundtrip "cool_2" c2)
    Theme.all_presets

let test_parse_palette_text () =
  let base = Theme.builtin_palette Theme.Midnight in
  (* A single key keeps every other built-in color. *)
  (match Theme_file.parse_palette_text ~preset:Theme.Midnight ~text:"surface_0 = \"#010203\"\n" with
  | Error reason -> Alcotest.fail ("single key must parse: " ^ reason)
  | Ok palette ->
      Alcotest.(check int) "surface_0 overridden" 0x010203 palette.surface_0;
      Alcotest.(check int) "surface_1 kept" base.surface_1 palette.surface_1;
      Alcotest.(check bool) "rest kept" true
        (Theme.equal_palette { base with surface_0 = 0x010203 } palette));
  (* A stops array replaces all three stops. *)
  (match
     Theme_file.parse_palette_text ~preset:Theme.Midnight
       ~text:"cool_stops = [\"#000000\", \"#FFFFFF\", \"#123456\"]\n"
   with
  | Error reason -> Alcotest.fail ("stops must parse: " ^ reason)
  | Ok palette ->
      let s0, s1, s2 = palette.cool_stops in
      Alcotest.(check int) "cool stops 0" 0x000000 s0;
      Alcotest.(check int) "cool stops 1" 0xFFFFFF s1;
      Alcotest.(check int) "cool stops 2" 0x123456 s2);
  (* Unknown keys, bad hex, wrong shapes all refuse the file. *)
  (match Theme_file.parse_palette_text ~preset:Theme.Midnight ~text:"foo = \"#000000\"\n" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "unknown key must fail");
  (match Theme_file.parse_palette_text ~preset:Theme.Midnight ~text:"surface_0 = \"#GGGGGG\"\n" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "bad hex must fail");
  (match Theme_file.parse_palette_text ~preset:Theme.Midnight ~text:"surface_0 = 123\n" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "non-string color must fail");
  (match
     Theme_file.parse_palette_text ~preset:Theme.Midnight
       ~text:"cool_stops = [\"#000000\", \"#FFFFFF\"]\n"
   with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "short stops must fail");
  (match Theme_file.parse_palette_text ~preset:Theme.Midnight ~text:"surface_0 =\"#000\"" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "short hex must fail")

let test_palette_registry () =
  Theme.clear_palette_overrides ();
  let builtin = Theme.builtin_palette Theme.Midnight in
  Alcotest.(check int) "no override is built-in" builtin.surface_0
    (Theme.of_preset Theme.Midnight).surface_0;
  Fun.protect ~finally:Theme.clear_palette_overrides (fun () ->
      Theme.set_palette_overrides
        [ (Theme.Midnight, { builtin with surface_0 = 0x010203 }) ];
      (match Theme.palette_override Theme.Midnight with
      | Some palette ->
          Alcotest.(check int) "override installed" 0x010203 palette.surface_0
      | None -> Alcotest.fail "override must be installed");
      (match Theme.palette_override Theme.Nord with
      | None -> ()
      | Some _ -> Alcotest.fail "other presets stay built-in");
      Alcotest.(check int) "of_preset uses override" 0x010203
        (Theme.of_preset Theme.Midnight).surface_0);
  Alcotest.(check int) "clear restores built-in" builtin.surface_0
    (Theme.of_preset Theme.Midnight).surface_0;
  (* of_palette with the built-in palette equals of_preset without overrides. *)
  List.iter
    (fun preset ->
      let theme = Theme.of_preset preset in
      let rebuilt = Theme.of_palette preset (Theme.builtin_palette preset) in
      Alcotest.(check int) (Theme.preset_name preset ^ " surfaces match")
        theme.surface_0 rebuilt.surface_0;
      Alcotest.(check int) (Theme.preset_name preset ^ " text matches")
        theme.text_bright rebuilt.text_bright)
    Theme.all_presets

let test_of_preset_returns_stored_theme () =
  Theme.clear_palette_overrides ();
  Fun.protect ~finally:Theme.clear_palette_overrides (fun () ->
      Alcotest.(check bool) "built-in theme is built once" true
        (Theme.of_preset Theme.Midnight == Theme.of_preset Theme.Midnight);
      let builtin = Theme.builtin_palette Theme.Midnight in
      Theme.set_palette_overrides
        [ (Theme.Midnight, { builtin with surface_0 = 0x010203 }) ];
      Alcotest.(check bool) "override theme is built once" true
        (Theme.of_preset Theme.Midnight == Theme.of_preset Theme.Midnight))

let test_cli_themes_dir () =
  (match Cli_args.parse ~env:empty_env ~cwd:"/tmp/cwd" [] with
  | Cli_args.Run cfg ->
      Alcotest.(check (option string)) "omitted is None" None cfg.themes_dir
  | Cli_args.Info _ | Cli_args.Parse_error _ ->
      Alcotest.fail "expected Run without flags");
  (match Cli_args.parse ~env:empty_env ~cwd:"/tmp/cwd" [ "--themes-dir"; "/tmp/extra-themes" ] with
  | Cli_args.Run cfg ->
      Alcotest.(check string) "themes_dir set" "/tmp/extra-themes"
        (Option.value ~default:"" cfg.themes_dir)
  | Cli_args.Info _ | Cli_args.Parse_error _ ->
      Alcotest.fail "expected Run with --themes-dir");
  (match Cli_args.parse ~env:empty_env ~cwd:"/tmp/cwd" [ "--themes-dir="; "" ] with
  | Cli_args.Parse_error _ -> ()
  | Cli_args.Run _ | Cli_args.Info _ ->
      Alcotest.fail "empty --themes-dir must fail");
  (match Cli_args.parse ~env:empty_env ~cwd:"/tmp/cwd" [ "--themes-dir" ] with
  | Cli_args.Parse_error _ -> ()
  | Cli_args.Run _ | Cli_args.Info _ ->
      Alcotest.fail "missing --themes-dir value must fail")

(* Runs [f] with an empty temporary directory. Afterwards the directory and
   whatever [f] installed in the override registry are removed. *)
let with_themes_dir f =
  let dir = Filename.temp_dir "theme-file" "" in
  Fun.protect
    ~finally:(fun () ->
      Theme.clear_palette_overrides ();
      try
        Array.iter (fun name -> Sys.remove (Filename.concat dir name)) (Sys.readdir dir);
        Unix.rmdir dir
      with Sys_error _ | Unix.Unix_error _ -> ())
    (fun () -> f dir)

let write_file dir name text =
  let oc = open_out (Filename.concat dir name) in
  output_string oc text;
  close_out oc

let test_load_overrides_files () =
  with_themes_dir (fun dir ->
      (* An absent directory is quiet: no warnings, built-in kept. *)
      let missing_warnings =
        Theme_file.load_overrides ~base_path:"/tmp/masc-theme-file-missing" ~themes_dir:None
      in
      Alcotest.(check (list string)) "absent dir is quiet" [] missing_warnings;
      (* One valid file overrides midnight only; a broken nord file warns. *)
      write_file dir "midnight.toml" "surface_0 = \"#010203\"\n";
      write_file dir "nord.toml" "foo = \"#000000\"\n";
      let warnings =
        Theme_file.load_overrides ~base_path:"/tmp/ignored"
          ~themes_dir:(Some dir)
      in
      Alcotest.(check bool) "broken nord warns" true (List.length warnings = 1);
      Alcotest.(check int) "midnight overridden" 0x010203
        (Theme.of_preset Theme.Midnight).surface_0;
      Alcotest.(check int) "nord kept built-in"
        (Theme.builtin_palette Theme.Nord).surface_0
        (Theme.of_preset Theme.Nord).surface_0;
      (* The default directory derives from base_path. *)
      Alcotest.(check string) "default dir"
        "/tmp/ws/.masc/config/themes"
        (Theme_file.default_dir ~base_path:"/tmp/ws"))

let test_load_overrides_duplicate_key () =
  with_themes_dir (fun dir ->
      write_file dir "midnight.toml"
        "surface_0 = \"#010203\"\nsurface_0 = \"#040506\"\n";
      let warnings =
        Theme_file.load_overrides ~base_path:"/tmp/ignored" ~themes_dir:(Some dir)
      in
      Alcotest.(check int) "duplicate key warns once" 1 (List.length warnings);
      match Theme.palette_override Theme.Midnight with
      | None -> ()
      | Some _ -> Alcotest.fail "a file with a duplicate key must keep the built-in palette")

(* The files in config/themes/ are the editable copies of the built-in
   palettes. A file that differs from [Theme.builtin_palette] makes the default
   colors depend on whether the user copied the directory. The test runs in
   _build/default/test/masc_tui_v2/app, where the [source_tree] dependency of
   the dune stanza puts the files. *)
let seed_dir = "../../../config/themes"

let test_seed_files_match_builtin () =
  List.iter
    (fun preset ->
      let path = Filename.concat seed_dir (Theme.preset_name preset ^ ".toml") in
      let text = In_channel.with_open_bin path In_channel.input_all in
      match Theme_file.parse_palette_text ~preset ~text with
      | Error reason -> Alcotest.fail (path ^ ": " ^ reason)
      | Ok palette ->
          Alcotest.(check bool) (path ^ " equals the built-in palette") true
            (Theme.equal_palette palette (Theme.builtin_palette preset)))
    Theme.all_presets

let () =
  Alcotest.run "theme_file"
    [
      ( "theme_file"
      , [
          Alcotest.test_case "rgb of hex" `Quick test_rgb_of_hex;
          Alcotest.test_case "parse palette text" `Quick test_parse_palette_text;
          Alcotest.test_case "palette registry" `Quick test_palette_registry;
          Alcotest.test_case "of_preset returns stored theme" `Quick
            test_of_preset_returns_stored_theme;
          Alcotest.test_case "cli themes dir" `Quick test_cli_themes_dir;
          Alcotest.test_case "load overrides files" `Quick test_load_overrides_files;
          Alcotest.test_case "load overrides duplicate key" `Quick
            test_load_overrides_duplicate_key;
          Alcotest.test_case "seed files match built-in" `Quick
            test_seed_files_match_builtin;
        ] );
    ]
