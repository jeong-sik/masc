(* The size a keeper's microVM guest boots with, from the operator's text to
   the decision whether a running guest may be kept.

   Measured 2026-09-18: guests booted with 2 GiB and 4 CPUs, keeper builds
   inside them timed out or were killed (exit 137), and the only knob was an
   environment variable the TUI's respawned server never saw. A size a keeper
   names, or the workspace sets in runtime.toml, has to reach the boot -- and a
   guest already running with the old size must not be adopted in its place. *)

open Alcotest
module Size = Keeper_microvm_guest_size
module Runtime = Masc.Keeper_turn_sandbox_runtime
module Profile = Keeper_types_profile_sandbox
module Sandbox_runtime = Env_config_sandbox.Runtime

let contains haystack needle = String_util.contains_substring haystack needle

let memory_exn raw =
  match Size.memory_of_string raw with
  | Ok memory -> memory
  | Error detail -> fail detail
;;

let cpus_exn count =
  match Size.cpus_of_int count with
  | Ok cpus -> cpus
  | Error detail -> fail detail
;;

let size ~memory ~cpus = { Size.memory = memory_exn memory; cpus = cpus_exn cpus }

let size_testable =
  testable (fun fmt value -> Format.pp_print_string fmt (Size.to_string value)) Size.equal
;;

(* ── what an operator may write ─────────────────────────────────────── *)

let test_memory_takes_mib_and_gib_in_either_case () =
  List.iter
    (fun (raw, mib) ->
       check int (raw ^ " in MiB") mib (Size.memory_mib (memory_exn raw)))
    [ "512m", 512; "512M", 512; "8g", 8192; "8G", 8192; "08g", 8192; "1m", 1 ];
  check string "rendered for --memory in MiB" "8192m" (Size.memory_argv (memory_exn "8g"))
;;

(* Each class is a way a size was plausibly mistyped, and each has to be a
   refusal that quotes what was written rather than a default. A bare number
   is the one that matters most: the runtimes read it as bytes. *)
let test_memory_refuses_every_other_spelling () =
  let too_large_for_gib = string_of_int ((max_int / 1024) + 1) ^ "g" in
  List.iter
    (fun raw ->
       match Size.memory_of_string raw with
       | Ok memory ->
         failf "%S was accepted as %s" raw (Size.memory_argv memory)
       | Error detail ->
         check bool (raw ^ " is named in the refusal") true (contains detail (Printf.sprintf "%S" raw));
         check bool (raw ^ " refusal names the accepted form") true (contains detail "m or g"))
    [ ""
    ; "8"
    ; "g"
    ; "m"
    ; "8 g"
    ; " 8g"
    ; "8g "
    ; "8gb"
    ; "8k"
    ; "8t"
    ; "-8g"
    ; "+8g"
    ; "8.5g"
    ; "0x10m"
    ; "1_024m"
    ; "0m"
    ; "0g"
    ; "99999999999999999999999m"
    ; too_large_for_gib
    ]
;;

let test_cpus_are_a_positive_whole_number () =
  check int "from a TOML integer" 6 (Size.cpus_count (cpus_exn 6));
  (match Size.cpus_of_string "6" with
   | Ok cpus -> check int "from the environment" 6 (Size.cpus_count cpus)
   | Error detail -> fail detail);
  List.iter
    (fun count ->
       match Size.cpus_of_int count with
       | Ok _ -> failf "%d CPUs was accepted" count
       | Error detail ->
         check bool (string_of_int count ^ " is named") true (contains detail (string_of_int count)))
    [ 0; -1 ];
  List.iter
    (fun raw ->
       match Size.cpus_of_string raw with
       | Ok cpus -> failf "%S was accepted as %d CPUs" raw (Size.cpus_count cpus)
       | Error detail ->
         check bool (raw ^ " is named") true (contains detail (Printf.sprintf "%S" raw)))
    [ ""; "0"; "6.0"; "+6"; " 6"; "six"; "0x6" ]
;;

(* ── which size a keeper gets ───────────────────────────────────────── *)

let never_read label () = failf "the workspace %s default was read" label

let test_a_keeper_that_names_both_never_reads_the_defaults () =
  match
    Size.resolve
      ~memory:(Some (memory_exn "16g"))
      ~cpus:(Some (cpus_exn 8))
      ~default_memory:(never_read "memory")
      ~default_cpus:(never_read "cpu")
  with
  | Ok resolved -> check size_testable "the keeper's own size" (size ~memory:"16g" ~cpus:8) resolved
  | Error detail -> fail detail
;;

(* The two dimensions are independent: a keeper that raises only memory keeps
   the workspace's CPU count, and the unused memory default is not read. *)
let test_each_dimension_falls_back_on_its_own () =
  (match
     Size.resolve
       ~memory:(Some (memory_exn "8g"))
       ~cpus:None
       ~default_memory:(never_read "memory")
       ~default_cpus:(fun () -> Ok (cpus_exn 4))
   with
   | Ok resolved -> check size_testable "memory own, cpus default" (size ~memory:"8g" ~cpus:4) resolved
   | Error detail -> fail detail);
  match
    Size.resolve
      ~memory:None
      ~cpus:(Some (cpus_exn 6))
      ~default_memory:(fun () -> Ok (memory_exn "2g"))
      ~default_cpus:(never_read "cpu")
  with
  | Ok resolved -> check size_testable "memory default, cpus own" (size ~memory:"2g" ~cpus:6) resolved
  | Error detail -> fail detail
;;

let test_an_unreadable_default_refuses_only_who_leans_on_it () =
  let bad_memory () = Error "memory default unreadable" in
  let bad_cpus () = Error "cpu default unreadable" in
  (match
     Size.resolve
       ~memory:(Some (memory_exn "8g"))
       ~cpus:(Some (cpus_exn 6))
       ~default_memory:bad_memory
       ~default_cpus:bad_cpus
   with
   | Ok _ -> ()
   | Error detail -> failf "a keeper naming both was refused: %s" detail);
  (match
     Size.resolve ~memory:None ~cpus:(Some (cpus_exn 6)) ~default_memory:bad_memory
       ~default_cpus:bad_cpus
   with
   | Ok _ -> fail "a keeper leaning on an unreadable memory default booted"
   | Error detail -> check string "the memory default's error" "memory default unreadable" detail);
  match Size.resolve ~memory:None ~cpus:None ~default_memory:bad_memory ~default_cpus:bad_cpus with
  | Ok _ -> fail "a keeper leaning on two unreadable defaults booted"
  | Error detail ->
    check bool "both are reported" true
      (contains detail "memory default unreadable" && contains detail "cpu default unreadable")
;;

(* The workspace default as the boot reads it. runtime.toml reaches it through
   the same variable, so this is also what a [sandbox] table sets. *)
let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv name (Option.value previous ~default:""))
    f
;;

let test_the_workspace_default_is_typed_and_refuses_a_bad_value () =
  with_env "MASC_KEEPER_MICROVM_MEMORY" "" @@ fun () ->
  with_env "MASC_KEEPER_MICROVM_CPUS" "" @@ fun () ->
  (match Sandbox_runtime.microvm_guest_size ~memory:None ~cpus:None with
   | Ok resolved ->
     check size_testable "unset is the built-in size"
       (size
          ~memory:Sandbox_runtime.microvm_memory_default
          ~cpus:Sandbox_runtime.microvm_cpus_default)
       resolved
   | Error detail -> fail detail);
  with_env "MASC_KEEPER_MICROVM_MEMORY" "12g" (fun () ->
    match Sandbox_runtime.microvm_memory () with
    | Ok memory -> check int "the variable's size" 12288 (Size.memory_mib memory)
    | Error detail -> fail detail);
  with_env "MASC_KEEPER_MICROVM_MEMORY" "12" (fun () ->
    match Sandbox_runtime.microvm_memory () with
    | Ok memory -> failf "a bare number was read as %s" (Size.memory_argv memory)
    | Error detail ->
      check bool "the refusal names the variable" true
        (contains detail "MASC_KEEPER_MICROVM_MEMORY"));
  with_env "MASC_KEEPER_MICROVM_CPUS" "0" (fun () ->
    match Sandbox_runtime.microvm_cpus () with
    | Ok cpus -> failf "0 CPUs was read as %d" (Size.cpus_count cpus)
    | Error detail ->
      check bool "the refusal names the variable" true
        (contains detail "MASC_KEEPER_MICROVM_CPUS"))
;;

(* ── runtime.toml ───────────────────────────────────────────────────── *)

let parse_or_fail source =
  match Keeper_toml_loader.parse_toml source with
  | Ok doc -> doc
  | Error detail -> fail detail
;;

let test_runtime_toml_sandbox_table_seeds_the_variables () =
  let doc = parse_or_fail "[sandbox]\nmicrovm_memory = \"8g\"\nmicrovm_cpus = 6\n" in
  check bool "the table is a known Keeper setting" true
    (Keeper_runtime_config.validation_report_is_valid (Keeper_runtime_config.validate_doc doc));
  let _count, overrides = Keeper_runtime_config.resolve_overrides ~env_lookup:(fun _ -> None) doc in
  check (option string) "memory" (Some "8g")
    (List.assoc_opt "MASC_KEEPER_MICROVM_MEMORY" overrides);
  check (option string) "cpus" (Some "6") (List.assoc_opt "MASC_KEEPER_MICROVM_CPUS" overrides);
  let zero_cpus = parse_or_fail "[sandbox]\nmicrovm_cpus = 0\n" in
  check bool "zero CPUs fails validation" false
    (Keeper_runtime_config.validation_report_is_valid (Keeper_runtime_config.validate_doc zero_cpus))
;;

(* ── the keeper TOML ────────────────────────────────────────────────── *)

let profile_of source = Masc.Keeper_types_profile.profile_defaults_of_toml (parse_or_fail source)

let test_a_keeper_names_its_own_size () =
  match
    profile_of
      "[keeper]\nsandbox_profile = \"microvm\"\nmicrovm_backend = \"apple_container\"\nmicrovm_memory = \"8g\"\nmicrovm_cpus = 6\n"
  with
  | Error detail -> fail detail
  | Ok defaults ->
    check (option int) "memory" (Some 8192) (Option.map Size.memory_mib defaults.microvm_memory);
    check (option int) "cpus" (Some 6) (Option.map Size.cpus_count defaults.microvm_cpus)
;;

let test_either_dimension_may_be_left_out () =
  match profile_of "[keeper]\nsandbox_profile = \"microvm\"\nmicrovm_cpus = 2\n" with
  | Error detail -> fail detail
  | Ok defaults ->
    check (option int) "memory unset" None (Option.map Size.memory_mib defaults.microvm_memory);
    check (option int) "cpus" (Some 2) (Option.map Size.cpus_count defaults.microvm_cpus)
;;

let test_a_size_that_does_not_parse_fails_the_load () =
  List.iter
    (fun (source, expected) ->
       match profile_of source with
       | Ok _ -> failf "loaded: %s" source
       | Error detail -> check bool (expected ^ " is named") true (contains detail expected))
    [ "[keeper]\nsandbox_profile = \"microvm\"\nmicrovm_memory = \"8\"\n", "microvm_memory_invalid"
    ; "[keeper]\nsandbox_profile = \"microvm\"\nmicrovm_cpus = 0\n", "microvm_cpus_invalid"
    ; ( "[keeper]\nsandbox_profile = \"microvm\"\nmicrovm_cpus = \"6\"\n"
      , "keeper.microvm_cpus must be a TOML integer" )
    ; ( "[keeper]\nsandbox_profile = \"microvm\"\nmicrovm_memory = 8\n"
      , "keeper.microvm_memory must be a TOML string" )
    ]
;;

let placeholder_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String "sized"; "trace_id", `String "trace-sized" ])
  with
  | Ok meta -> meta
  | Error detail -> fail detail
;;

(* Durable meta carries no size; the TOML overlay is what reaches the boot.
   Off Micro_vm there is no guest, so the size does not travel. *)
let test_the_profile_overlay_carries_the_size_to_a_microvm_keeper_only () =
  let defaults profile =
    { Masc.Keeper_types_profile.empty_keeper_profile_defaults with
      manifest_path = Some ".masc/config/keepers/sized.toml"
    ; sandbox_profile = Some profile
    ; microvm_backend =
        (match profile with
         | Profile.Micro_vm -> Some Masc.Keeper_microvm_backend.Apple_container
         | Profile.Docker | Profile.Remote_ssh -> None)
    ; microvm_memory = Some (memory_exn "8g")
    ; microvm_cpus = Some (cpus_exn 6)
    }
  in
  (match
     Masc.Keeper_meta_contract.effective_meta_of_profile_defaults
       (defaults Profile.Micro_vm)
       (placeholder_meta ())
   with
   | Error detail -> fail detail
   | Ok meta ->
     check (option int) "microvm memory" (Some 8192) (Option.map Size.memory_mib meta.microvm_memory);
     check (option int) "microvm cpus" (Some 6) (Option.map Size.cpus_count meta.microvm_cpus));
  match
    Masc.Keeper_meta_contract.effective_meta_of_profile_defaults
      (defaults Profile.Docker)
      (placeholder_meta ())
  with
  | Error detail -> fail detail
  | Ok meta ->
    check (option int) "docker memory" None (Option.map Size.memory_mib meta.microvm_memory);
    check (option int) "docker cpus" None (Option.map Size.cpus_count meta.microvm_cpus)
;;

(* ── adopting a running guest ───────────────────────────────────────── *)

let reason_label = function
  | Runtime.Boot_not_recorded -> "boot_not_recorded"
  | Runtime.Image_changed _ -> "image"
  | Runtime.Memory_changed _ -> "memory"
  | Runtime.Cpus_changed _ -> "cpus"
  | Runtime.Policy_route_stale _ -> "policy_route"
;;

let adoption_labels = function
  | Runtime.Adopt_running_guest -> []
  | Runtime.Replace_running_guest reasons -> List.map reason_label reasons
;;

let booted ?(policy_port = None) ?(image = "keeper:1") ?(memory = "2g") ?(cpus = 4) () =
  Some { Runtime.policy_port; image; guest_size = size ~memory ~cpus }
;;

let decide ?(network_mode = Profile.Network_none) ?(bound_port = None)
      ?(image = "keeper:1") ?(memory = "2g") ?(cpus = 4) booted_with =
  Runtime.For_testing.microvm_adoption
    ~booted:booted_with
    ~image
    ~guest_size:(size ~memory ~cpus)
    ~network_mode
    ~bound_port
  |> adoption_labels
;;

let test_a_guest_booted_with_what_the_keeper_asks_for_is_adopted () =
  check (list string) "same image and size" [] (decide (booted ()));
  (* "2g" and "2048m" are one size: the comparison is in MiB, not text. *)
  check (list string) "same size spelled differently" []
    (decide ~memory:"2048m" (booted ~memory:"2g" ()))
;;

let test_a_guest_this_process_has_no_record_of_is_replaced () =
  List.iter
    (fun network_mode ->
       check (list string)
         (Profile.network_mode_to_string network_mode ^ " without a record")
         [ "boot_not_recorded" ]
         (decide ~network_mode ~bound_port:(Some 51_022) None))
    Profile.all_network_modes
;;

(* The bug this closes: the keeper's TOML raised the guest, and the running
   2 GiB guest was adopted by name until the server restarted. *)
let test_a_changed_image_or_size_replaces_the_guest_and_names_what_changed () =
  check (list string) "image" [ "image" ] (decide ~image:"keeper:2" (booted ()));
  check (list string) "memory" [ "memory" ] (decide ~memory:"8g" (booted ()));
  check (list string) "cpus" [ "cpus" ] (decide ~cpus:6 (booted ()));
  check (list string) "all of them at once"
    [ "image"; "memory"; "cpus" ]
    (decide ~image:"keeper:2" ~memory:"8g" ~cpus:6 (booted ()))
;;

(* The policy rule is the one [policy_route_holds] already pins; this says it
   still decides adoption alongside the new comparisons. *)
let test_the_policy_route_rule_is_unchanged () =
  check (list string) "the port still bound" []
    (decide ~network_mode:Profile.Network_policy ~bound_port:(Some 51_022)
       (booted ~policy_port:(Some 51_022) ()));
  check (list string) "the lane rebound" [ "policy_route" ]
    (decide ~network_mode:Profile.Network_policy ~bound_port:(Some 51_099)
       (booted ~policy_port:(Some 51_022) ()));
  check (list string) "no listener" [ "policy_route" ]
    (decide ~network_mode:Profile.Network_policy ~bound_port:None
       (booted ~policy_port:(Some 51_022) ()));
  List.iter
    (fun network_mode ->
       check (list string)
         (Profile.network_mode_to_string network_mode ^ " carries no route")
         []
         (decide ~network_mode ~bound_port:None (booted ())))
    [ Profile.Network_none; Profile.Network_inherit ]
;;

let () =
  run
    "keeper_microvm_guest_size"
    [ ( "spelling"
      , [ test_case "memory takes MiB and GiB" `Quick
            test_memory_takes_mib_and_gib_in_either_case
        ; test_case "memory refuses every other spelling" `Quick
            test_memory_refuses_every_other_spelling
        ; test_case "cpus are a positive whole number" `Quick
            test_cpus_are_a_positive_whole_number
        ] )
    ; ( "resolution"
      , [ test_case "a keeper naming both never reads the defaults" `Quick
            test_a_keeper_that_names_both_never_reads_the_defaults
        ; test_case "each dimension falls back on its own" `Quick
            test_each_dimension_falls_back_on_its_own
        ; test_case "an unreadable default refuses only who leans on it" `Quick
            test_an_unreadable_default_refuses_only_who_leans_on_it
        ; test_case "the workspace default is typed" `Quick
            test_the_workspace_default_is_typed_and_refuses_a_bad_value
        ] )
    ; ( "runtime_toml"
      , [ test_case "[sandbox] seeds the variables" `Quick
            test_runtime_toml_sandbox_table_seeds_the_variables
        ] )
    ; ( "keeper_toml"
      , [ test_case "a keeper names its own size" `Quick test_a_keeper_names_its_own_size
        ; test_case "either dimension may be left out" `Quick
            test_either_dimension_may_be_left_out
        ; test_case "a size that does not parse fails the load" `Quick
            test_a_size_that_does_not_parse_fails_the_load
        ; test_case "the overlay carries the size to microvm keepers only" `Quick
            test_the_profile_overlay_carries_the_size_to_a_microvm_keeper_only
        ] )
    ; ( "adoption"
      , [ test_case "a guest booted as asked is adopted" `Quick
            test_a_guest_booted_with_what_the_keeper_asks_for_is_adopted
        ; test_case "an unrecorded guest is replaced" `Quick
            test_a_guest_this_process_has_no_record_of_is_replaced
        ; test_case "a changed image or size replaces the guest" `Quick
            test_a_changed_image_or_size_replaces_the_guest_and_names_what_changed
        ; test_case "the policy route rule is unchanged" `Quick
            test_the_policy_route_rule_is_unchanged
        ] )
    ]
;;
