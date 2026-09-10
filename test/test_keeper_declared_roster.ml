open Alcotest
open Masc

let with_workspace f =
  let base = Filename.temp_file "declared-keeper-roster" "" in
  Unix.unlink base;
  Unix.mkdir base 0o700;
  let masc = Filename.concat base ".masc" in
  let config = Filename.concat masc "config" in
  let declarations = Filename.concat config "keepers" in
  List.iter (fun path -> Unix.mkdir path 0o700) [masc; config; declarations];
  let path = Filename.concat declarations "imp.toml" in
  Out_channel.with_open_bin path (fun out -> output_string out
    "[keeper]\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\ninstructions = \"Help the operator.\"\n");
  Fun.protect ~finally:(fun () ->
    Unix.unlink path;
    List.iter Unix.rmdir [declarations; config; masc; base])
    (fun () -> f base)

let test_declared_keeper_is_visible_without_materialization () =
  with_workspace (fun base ->
    let rows = Keeper_declared_roster.missing ~base_path:base ~persisted_names:[] in
    check int "one declaration" 1 (List.length rows);
    let row = List.hd rows in
    check string "actual declaration name" "imp" row.name;
    check int "independent runtime and sandbox checks" 2 (List.length row.requirements);
    let summary = Tui_decode.keeper_of_declaration row in
    (match summary.k_origin with
     | Declared_keeper [ Runtime_check_required; Sandbox_check_required ] -> ()
     | _ -> fail "must retain both unverified preparation requirements");
    check string "no fabricated trace" "" summary.k_trace_id;
    let wire = Keeper_declared_roster.to_json row in
    check string "web lifecycle" "unbooted"
      Yojson.Safe.Util.(wire |> member "status" |> to_string);
    check bool "no persisted runtime directory" false
      (Sys.file_exists (Filename.concat base ".masc/keepers")))

let test_persisted_keeper_is_not_duplicated () =
  with_workspace (fun base ->
    check int "persisted metadata name wins the roster join" 0
      (List.length (Keeper_declared_roster.missing ~base_path:base ~persisted_names:["imp"])))

let () = run "declared keeper roster"
  [ "first startup", [test_case "visible before first boot" `Quick test_declared_keeper_is_visible_without_materialization;
                       test_case "persisted keeper replaces declaration row" `Quick test_persisted_keeper_is_not_duplicated] ]
