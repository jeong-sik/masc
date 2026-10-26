module Inventory = Masc.Keeper_microvm_guest_inventory
module Backend = Masc.Keeper_microvm_backend
module Cli = Masc.Keeper_microvm_cli_output

let guest = "masc-keeper-vm-inventory-none-12345678"
let other = "masc-keeper-vm-other-none-12345678"

let presence = Alcotest.testable
    (fun formatter -> function
      | Inventory.Present -> Format.pp_print_string formatter "Present"
      | Inventory.Absent -> Format.pp_print_string formatter "Absent")
    ( = )

let error = Alcotest.testable
    (fun formatter value -> Format.pp_print_string formatter (Inventory.error_message value))
    ( = )

let decode raw = Inventory.For_testing.presence_of_apple_json ~guest_name:guest raw

let expect_presence expected = function
  | Ok actual -> Alcotest.check presence "presence" expected actual
  | Error failure -> Alcotest.fail (Inventory.error_message failure)
;;

let expect_error expected = function
  | Error actual -> Alcotest.check error "typed inventory error" expected actual
  | Ok actual -> Alcotest.failf "unreadable inventory returned %a" (Alcotest.pp presence) actual
;;

let test_complete_inventory_matches_names_without_labels () =
  List.iter (fun raw -> expect_presence Inventory.Present (decode raw))
    [ Printf.sprintf {|[{"id":%S}]|} guest
    ; Printf.sprintf {|[{"configuration":{"id":%S}}]|} guest
    ; Printf.sprintf {|[{"id":%S,"configuration":{"id":%S}}]|} guest guest
    ; Printf.sprintf {|[{"id":%S,"labels":{"masc.mcp.base_path_hash":"foreign"}}]|} guest
    ; Printf.sprintf {|[{"configuration":{"id":%S,"labels":42},"labels":null}]|} guest
    ; Printf.sprintf {|[{"id":%S,"status":{"state":"stopped"}}]|} guest
    ];
  expect_presence Inventory.Absent (decode "[]");
  expect_presence Inventory.Absent (decode (Printf.sprintf {|[{"id":%S}]|} other));
  expect_presence Inventory.Absent (decode (Printf.sprintf {|[{"id":%S}]|} (guest ^ "-extra")))
;;

let test_every_row_must_be_unambiguous () =
  let open Inventory in
  List.iter (fun (reason, raw) -> expect_error (Invalid_inventory reason) (decode raw))
    [ Invalid_json, "[{invalid-secret-bearing-json"
    ; Expected_array, "{}"
    ; Expected_row_object, "[null]"
    ; Missing_identity, "[{}]"
    ; Invalid_identity, {|[{"id":""}]|}
    ; Invalid_identity, {|[{"id":"   "}]|}
    ; Invalid_identity, {|[{"id":42,"configuration":{"id":"other"}}]|}
    ; Invalid_identity, {|[{"configuration":{"id":null}}]|}
    ; Invalid_configuration, Printf.sprintf {|[{"id":%S,"configuration":null}]|} guest
    ; Duplicate_row_key, Printf.sprintf {|[{"id":%S,"id":%S}]|} other guest
    ; Duplicate_row_key, {|[{"id":"other","extension":1,"extension":2}]|}
    ; Duplicate_configuration_key, {|[{"configuration":{"id":"other","id":"other"}}]|}
    ; Duplicate_configuration_key, {|[{"configuration":{"id":"other","extension":1,"extension":2}}]|}
    ; Conflicting_identity, Printf.sprintf {|[{"id":%S,"configuration":{"id":%S}}]|} other guest
    ; Conflicting_identity, Printf.sprintf {|[{"id":%S,"configuration":{"id":%S}}]|} guest other
    ; Duplicate_guest_name, Printf.sprintf {|[{"id":%S},{"configuration":{"id":%S}}]|} other other
    ; Duplicate_guest_name, Printf.sprintf {|[{"id":%S},{"id":%S}]|} guest guest
    ; Expected_row_object, Printf.sprintf {|[{"id":%S},false]|} guest
    ; Missing_identity, Printf.sprintf {|[{"id":%S},{}]|} guest
    ];
  expect_error Invalid_guest_name
    (For_testing.presence_of_apple_json ~guest_name:" " "[]")
;;

let scope_labels ~component ~base_path_hash ~kind ~keeper =
  Printf.sprintf
    {|{"masc.mcp.component":%S,"masc.mcp.base_path_hash":%S,"masc.mcp.kind":%S,"masc.mcp.keeper":%S}|}
    component base_path_hash kind keeper
;;

let test_scope_projection_preserves_foreign_and_malformed_rows () =
  let expected : Inventory.scoping_labels =
    {component = "keeper-sandbox"; base_path_hash = "this-base"; kind = "keeper-vm"; keeper = "keeper"} in
  let labels = scope_labels ~component:expected.component ~base_path_hash:expected.base_path_hash
      ~kind:expected.kind ~keeper:expected.keeper in
  let foreign = scope_labels ~component:"foreign-component" ~base_path_hash:"another-base"
      ~kind:"another-kind" ~keeper:"foreign-keeper" in
  let cases =
    [ "scoped", Printf.sprintf {|{"configuration":{"id":"scoped","labels":%s}}|} labels, Some expected
    ; "foreign", Printf.sprintf {|{"id":"foreign","labels":%s}|} foreign,
      Some Inventory.{component="foreign-component"; base_path_hash="another-base";
        kind="another-kind"; keeper="foreign-keeper"}
    ; "missing", {|{"id":"missing"}|}, None
    ; "malformed", {|{"id":"malformed","labels":42}|}, None
    ; "incomplete", {|{"id":"incomplete","labels":{"masc.mcp.keeper":"keeper"}}|}, None
    ; "duplicate-label",
        {|{"id":"duplicate-label","labels":{"masc.mcp.component":"keeper-sandbox","masc.mcp.component":"other","masc.mcp.base_path_hash":"this-base","masc.mcp.kind":"keeper-vm","masc.mcp.keeper":"keeper"}}|}, None
    ; "conflict", Printf.sprintf {|{"id":"conflict","labels":%s,"configuration":{"labels":%s}}|}
        labels foreign, None
    ; "malformed-top", Printf.sprintf {|{"id":"malformed-top","labels":null,"configuration":{"labels":%s}}|}
        labels, None
    ] in
  let raw = "[" ^ String.concat "," (List.map (fun (_, raw, _) -> raw) cases) ^ "]" in
  let inventory = match Inventory.For_testing.inventory_of_apple_json raw with
    | Ok inventory -> inventory | Error failure -> Alcotest.fail (Inventory.error_message failure) in
  let rows = Inventory.rows inventory in
  Alcotest.(check (list string)) "complete original row order is retained"
    (List.map (fun (name, _, _) -> name) cases) (List.map (fun (row : Inventory.row) -> row.name) rows);
  List.iter2 (fun (name, _, expected) (row : Inventory.row) ->
    expect_presence Inventory.Present (Inventory.presence ~guest_name:name inventory);
    Alcotest.(check bool) "only consistent complete labels are projected" true
      (row.scoping_labels = expected)) cases rows
;;

let write path contents =
  Out_channel.with_open_bin path (fun channel -> output_string channel contents)
;;

let with_fake_cli use =
  let directory = Filename.temp_dir "masc-full-guest-inventory-" "" in
  let cli = Filename.concat directory "container" in
  let log = Filename.concat directory "calls" in
  let previous_path = Sys.getenv_opt "PATH" in
  let script ~status ~stdout ~stderr =
    write cli (Printf.sprintf
      "#!/bin/sh\nprintf '%%s\\n' \"$@\" >> %s\nprintf '%%s' %s\nprintf '%%s' %s >&2\nexit %d\n"
      (Filename.quote log) (Filename.quote stdout) (Filename.quote stderr) status);
    Unix.chmod cli 0o700 in
  let calls () =
    if Sys.file_exists log then In_channel.with_open_bin log In_channel.input_all
    else "" in
  Fun.protect ~finally:(fun () ->
    (match previous_path with
     | Some path -> Unix.putenv "PATH" path
     | None -> Unix.unsetenv "PATH");
    Sys.readdir directory |> Array.iter (fun leaf -> Unix.unlink (Filename.concat directory leaf));
    Unix.rmdir directory)
    (fun () ->
      Unix.putenv "PATH" directory;
      Eio_main.run (fun env ->
        let previous_fs = Fs_compat.get_fs_opt () in
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        Process_eio.init
          ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
          ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
        Fun.protect ~finally:(fun () ->
          Process_eio.reset_for_testing ();
          match previous_fs with
          | None -> Fs_compat.clear_fs ()
          | Some fs -> Fs_compat.set_fs fs)
          (fun () -> use ~script ~calls)))
;;

let read backend = Inventory.read ~backend ~guest_name:guest ~timeout_sec:5.

let test_actual_cli_uses_full_listing () =
  with_fake_cli (fun ~script ~calls ->
    script ~status:0 ~stdout:(Printf.sprintf {|[{"id":%S,"labels":"foreign"}]|} guest)
      ~stderr:"";
    expect_presence Inventory.Present (read Backend.Apple_container);
    Alcotest.(check string) "canonical full unfiltered argv reached the child"
      "list\n--all\n--format\njson\n" (calls ());
    script ~status:0 ~stdout:"[]" ~stderr:"";
    expect_presence Inventory.Absent (read Backend.Apple_container))
;;

let test_failed_cli_never_proves_absence_or_leaks_output () =
  with_fake_cli (fun ~script ~calls:_ ->
    script ~status:1 ~stdout:"[]" ~stderr:"credential-marker-must-not-leak";
    let expected = Inventory.Command_failed (Unix.WEXITED 1) in
    expect_error expected (read Backend.Apple_container);
    Alcotest.(check string) "failure explanation contains only typed status"
      "full guest inventory command failed: exit 1" (Inventory.error_message expected);
    script ~status:0 ~stdout:"credential-marker-must-not-leak" ~stderr:"private stderr";
    expect_error (Inventory.Invalid_inventory Inventory.Invalid_json) (read Backend.Apple_container))
;;

let test_guest_in_the_middle_of_large_inventory_is_present () =
  with_fake_cli (fun ~script ~calls:_ ->
    (* Both padding fields exceed the actual preview retention. The requested
       guest is visible only in the authoritative capture, not its head/tail. *)
    let padding = String.make
        (Common.max_process_capture_head_bytes + Common.max_process_capture_tail_bytes) 'x' in
    let stdout = Printf.sprintf
        {|[{"id":"first","labels":{"padding":"%s"}},{"id":%S},{"id":"last","labels":{"padding":"%s"}}]|}
        padding guest padding in
    script ~status:0 ~stdout ~stderr:"";
    expect_presence Inventory.Present (read Backend.Apple_container))
;;

let test_fallback_preview_cannot_establish_absence () =
  with_fake_cli (fun ~script ~calls ->
    script ~status:0 ~stdout:"[]" ~stderr:"";
    Process_eio.reset_for_testing ();
    expect_error (Inventory.Output_unavailable Inventory.Capture_failed) (read Backend.Apple_container);
    Alcotest.(check string) "fallback did run the canonical listing"
      "list\n--all\n--format\njson\n" (calls ());
    script ~status:1 ~stdout:"[]" ~stderr:"private failure";
    expect_error (Inventory.Command_failed (Unix.WEXITED 1)) (read Backend.Apple_container))
;;

let test_actual_full_inventory_read_exposes_scope_without_filtering () =
  with_fake_cli (fun ~script ~calls:_ ->
    let labels = scope_labels ~component:"foreign-component" ~base_path_hash:"foreign-base"
        ~kind:"foreign-kind" ~keeper:"foreign-keeper" in
    script ~status:0 ~stdout:(Printf.sprintf
      {|[{"id":%S,"configuration":{"labels":%s}},{"id":"unscoped","labels":null}]|} guest labels) ~stderr:"";
    match Inventory.read_apple ~timeout_sec:5. with
    | Error failure -> Alcotest.fail (Inventory.error_message failure)
    | Ok inventory ->
      expect_presence Inventory.Present (Inventory.presence ~guest_name:guest inventory);
      match Inventory.rows inventory with
      | [{name; scoping_labels = Some labels}; {name = "unscoped"; scoping_labels = None}] ->
        Alcotest.(check string) "actual name retained" guest name;
        Alcotest.(check string) "foreign scope is not rewritten" "foreign-base" labels.base_path_hash
      | [] | _ :: _ -> Alcotest.fail "actual inventory rows changed or disappeared")
;;

let test_cli_helper_retains_complete_stdout_for_nonzero_child () =
  with_fake_cli (fun ~script ~calls:_ ->
    let stdout = String.make
        (Common.max_process_capture_head_bytes + Common.max_process_capture_tail_bytes + 1) 'x' in
    script ~status:7 ~stdout ~stderr:"must-not-enter-stdout";
    match Cli.read ~timeout_sec:5. ~argv:["container"; "inspect"; guest] with
    | Error failure -> Alcotest.fail (Cli.error_message failure)
    | Ok (status, actual) ->
      Alcotest.(check bool) "actual nonzero termination retained" true (status = Unix.WEXITED 7);
      Alcotest.(check bool) "stdout remains complete and excludes stderr" true (stdout = actual))
;;

let test_cancelled_cli_call_removes_private_capture_directory () =
  let directory = Filename.temp_dir "masc-cli-cancellation-" "" in
  let previous_temp_dir = Filename.get_temp_dir_name () in
  Fun.protect ~finally:(fun () ->
    Filename.set_temp_dir_name previous_temp_dir;
    Fs_compat.remove_tree directory)
    (fun () ->
      Filename.set_temp_dir_name directory;
      with_fake_cli (fun ~script ~calls:_ ->
        script ~status:0 ~stdout:"[]" ~stderr:"";
        let entries () = Sys.readdir directory |> Array.to_list |> List.sort String.compare in
        let before = entries () in
        let cancelled = try
          Eio.Cancel.sub (fun context ->
            Eio.Cancel.cancel context Exit;
            ignore (Cli.read ~timeout_sec:5. ~argv:["container"; "inspect"; guest]);
            Eio.Fiber.check ());
          false
        with Eio.Cancel.Cancelled _ -> true in
        Alcotest.(check bool) "original cancellation remains visible" true cancelled;
        Alcotest.(check (list string)) "private capture directory was removed" before (entries ())))
;;

let test_unsupported_or_empty_query_never_starts_cli () =
  with_fake_cli (fun ~script ~calls ->
    script ~status:0 ~stdout:"[]" ~stderr:"";
    List.iter (fun backend -> expect_error (Inventory.Unsupported backend) (read backend))
      [Backend.Microsandbox; Backend.Nerdctl_kata];
    expect_error Inventory.Invalid_guest_name
      (Inventory.read ~backend:Backend.Apple_container ~guest_name:"" ~timeout_sec:5.);
    Alcotest.(check string) "no unsupported or invalid query executed a command" "" (calls ()))
;;

let () =
  Alcotest.run "keeper_microvm_guest_inventory"
    [ "full inventory",
      [ Alcotest.test_case "exact presence ignores labels and state" `Quick
          test_complete_inventory_matches_names_without_labels
      ; Alcotest.test_case "every row must be unambiguous" `Quick test_every_row_must_be_unambiguous
      ; Alcotest.test_case "scope projection retains foreign and malformed rows" `Quick
          test_scope_projection_preserves_foreign_and_malformed_rows
      ; Alcotest.test_case "actual CLI uses full listing" `Quick test_actual_cli_uses_full_listing
      ; Alcotest.test_case "failed CLI is unknown and output stays private" `Quick
          test_failed_cli_never_proves_absence_or_leaks_output
      ; Alcotest.test_case "middle of large inventory stays visible" `Quick
          test_guest_in_the_middle_of_large_inventory_is_present
      ; Alcotest.test_case "fallback preview cannot prove absence" `Quick
          test_fallback_preview_cannot_establish_absence
      ; Alcotest.test_case "actual full inventory exposes reported scope" `Quick
          test_actual_full_inventory_read_exposes_scope_without_filtering
      ; Alcotest.test_case "shared CLI reader retains complete nonzero stdout" `Quick
          test_cli_helper_retains_complete_stdout_for_nonzero_child
      ; Alcotest.test_case "cancelled CLI reader removes private capture" `Quick
          test_cancelled_cli_call_removes_private_capture_directory
      ; Alcotest.test_case "unsupported and invalid queries never execute" `Quick
          test_unsupported_or_empty_query_never_starts_cli
      ] ]
