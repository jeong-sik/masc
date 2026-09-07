open Alcotest

let test_missing_cartridge_can_be_repaired_and_reopened () =
  let path = Filename.temp_file "masc-msx-cart-" ".rom" in
  Sys.remove path;
  let previous_cart = Sys.getenv_opt "MSX_CART" in
  let previous_roms = Sys.getenv_opt "MSX_ROMS" in
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "MSX_CART" (Option.value ~default:"" previous_cart);
      Unix.putenv "MSX_ROMS" (Option.value ~default:"" previous_roms);
      if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Unix.putenv "MSX_CART" path;
      Unix.putenv "MSX_ROMS" "";
      let state = Masc_tui_types.create_state
          ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
      let frames = ref [] in
      let write text = frames := text :: !frames in
      (match Masc_tui_msx.open_screen ~write state with
       | Error error ->
           check string "failure identifies cartridge" path error.path;
           check bool "failure explains read error" true (error.detail <> "")
       | Ok () -> fail "missing cartridge opened a machine");
      check bool "normal TUI retains keyboard and rendering" false state.msx_open;
      check bool "failed image never publishes a machine" true (Option.is_none state.msx);
      check int "failure never replaces the terminal frame" 0 (List.length !frames);
      Out_channel.with_open_bin path
        (fun channel -> output_string channel (String.make 16384 '\000'));
      (match Masc_tui_msx.open_screen ~write state with
       | Ok () -> ()
       | Error error -> fail error.detail);
      check bool "retry opens repaired cartridge" true state.msx_open;
      check bool "retry draws the screen" true (!frames <> []);
      let machine = state.msx in
      check bool "Esc returns to normal TUI" false (Masc_tui_msx.consume ~write state "esc");
      check bool "screen closed" false state.msx_open;
      (match Masc_tui_msx.open_screen ~write state with
       | Ok () -> ()
       | Error error -> fail error.detail);
      check bool "reopening retains the loaded machine" true (state.msx == machine))

let () = run "MSX cartridge load recovery"
  ["operator recovery", [test_case "missing image then repair and reopen" `Quick
      test_missing_cartridge_can_be_repaired_and_reopened]]
