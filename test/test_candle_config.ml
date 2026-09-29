(** candle.toml (RFC-goal-candle-ledger 3.9): off, on, or off with a reason. *)

let pp ppf value = Format.pp_print_string ppf (Candle_config.to_string value)
let config = Alcotest.testable pp ( = )

let disabled_reason = function
  | Candle_config.Disabled { reason } -> reason
  | Candle_config.Off | Candle_config.Enabled ->
    Alcotest.fail "expected a disabled config"
;;

let contains ~affix text =
  let n = String.length affix
  and h = String.length text in
  let rec scan i = i + n <= h && (String.equal (String.sub text i n) affix || scan (i + 1)) in
  scan 0
;;

let test_no_key_is_enabled () =
  Alcotest.check config "an empty file" Candle_config.Enabled (Candle_config.of_toml_string "");
  Alcotest.check
    config
    "comments and blank lines"
    Candle_config.Enabled
    (Candle_config.of_toml_string "# Candle is on.\n\n  # nothing else yet\n")
;;

let test_a_key_this_build_does_not_know_disables () =
  let reason = disabled_reason (Candle_config.of_toml_string "half_life_hours = 72\n") in
  Alcotest.(check bool) "names the key" true (contains ~affix:"half_life_hours" reason);
  let table = disabled_reason (Candle_config.of_toml_string "[prices]\nfoo = 1\n") in
  Alcotest.(check bool) "names the table" true (contains ~affix:"prices" table)
;;

let test_text_that_is_not_toml_disables () =
  let reason = disabled_reason (Candle_config.of_toml_string "this is = = not toml [") in
  Alcotest.(check bool) "says it is not valid TOML" true (contains ~affix:"not valid TOML" reason)
;;

let with_dir f =
  let dir = Filename.temp_file "candle_config_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      Array.iter (fun entry -> Sys.remove (Filename.concat dir entry)) (Sys.readdir dir);
      Unix.rmdir dir)
    (fun () -> f dir)
;;

let test_no_file_is_off () =
  with_dir (fun dir ->
    Alcotest.check
      config
      "nothing at the path"
      Candle_config.Off
      (Candle_config.load_file ~path:(Filename.concat dir "candle.toml")))
;;

let test_a_file_is_read_every_time () =
  with_dir (fun dir ->
    let path = Filename.concat dir "candle.toml" in
    Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc "");
    Alcotest.check config "empty" Candle_config.Enabled (Candle_config.load_file ~path);
    Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc "surprise = true\n");
    ignore (disabled_reason (Candle_config.load_file ~path));
    Sys.remove path;
    Alcotest.check config "removed" Candle_config.Off (Candle_config.load_file ~path))
;;

let test_a_path_that_cannot_be_read_disables () =
  with_dir (fun dir ->
    let path = Filename.concat dir "candle.toml" in
    Unix.mkdir path 0o755;
    Fun.protect
      ~finally:(fun () -> Unix.rmdir path)
      (fun () ->
        let reason = disabled_reason (Candle_config.load_file ~path) in
        Alcotest.(check bool) "says it could not be read" true (contains ~affix:"could not be read" reason)))
;;

let () =
  Alcotest.run
    "candle_config"
    [ ( "content"
      , [ Alcotest.test_case "no key is enabled" `Quick test_no_key_is_enabled
        ; Alcotest.test_case "a key this build does not know disables" `Quick
            test_a_key_this_build_does_not_know_disables
        ; Alcotest.test_case "text that is not TOML disables" `Quick
            test_text_that_is_not_toml_disables
        ] )
    ; ( "file"
      , [ Alcotest.test_case "no file is off" `Quick test_no_file_is_off
        ; Alcotest.test_case "the file is read every time" `Quick test_a_file_is_read_every_time
        ; Alcotest.test_case "a path that cannot be read disables" `Quick
            test_a_path_that_cannot_be_read_disables
        ] )
    ]
;;
