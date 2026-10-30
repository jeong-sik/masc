(* The nameserver a microVM guest on the default network is handed.

   Measured 2026-10-16: the host resolved through fe80::f4be:ecff:fee7:64%en0,
   the boot copied that text into the guest's --dns, and no name resolved in
   any guest (#40915). The zone names an interface of the host. The nameserver
   has to be an address the guest can use, the workspace has to be able to name
   one in runtime.toml, and a host whose resolver is none of those has to fail
   the guest's boot -- not the config load that the operator sets the key in,
   and not a guest that is already running and resolving. *)

open Alcotest
module Dns = Env_config_sandbox.Runtime
module Runtime = Masc.Keeper_turn_sandbox_runtime
module Profile = Keeper_types_profile_sandbox
module Backend = Masc.Keeper_microvm_backend

(* The workspace's [sandbox] microvm_dns, as the loader leaves it. *)
let with_file_dns value f =
  Masc_test_deps.with_file_owned_values [ "MASC_KEEPER_MICROVM_DNS", value ] f
;;

let refusal_label = function
  | Dns.Not_an_address -> "not_an_address"
  | Dns.Zone_scoped -> "zone_scoped"
  | Dns.Unspecified -> "unspecified"
  | Dns.Loopback -> "loopback"
  | Dns.Link_local -> "link_local"
  | Dns.Multicast -> "multicast"
;;

let outcome text =
  match Dns.nameserver_of_string text with
  | Ok address -> "ok " ^ Ipaddr.to_string address
  | Error refusal -> refusal_label refusal
;;

let check_table name rows =
  List.iter
    (fun (text, expected) -> check string (name ^ ": " ^ text) expected (outcome text))
    rows
;;

(* ── what a guest can use ───────────────────────────────────────────── *)

let test_a_reachable_address_is_a_nameserver () =
  check_table "usable"
    [ "168.126.63.1", "ok 168.126.63.1"
    ; "1.1.1.1", "ok 1.1.1.1"
    ; "192.168.0.1", "ok 192.168.0.1"
    ; "2001:4860:4860::8888", "ok 2001:4860:4860::8888"
    ; "  1.1.1.1\t", "ok 1.1.1.1"
    ]
;;

let test_an_address_that_means_something_only_on_the_host_is_refused () =
  check_table "refused"
    [ (* The resolver that left every guest without DNS on 2026-10-16. *)
      "fe80::f4be:ecff:fee7:64%en0", "zone_scoped"
    ; "fe80::1%eth0", "zone_scoped"
    ; "fe80::f4be:ecff:fee7:64", "link_local"
    ; (* fe80::/10, not the /64 that Ipaddr calls link-local. *)
      "febf::1", "link_local"
    ; "fe81::1", "link_local"
    ; "169.254.1.1", "link_local"
    ; "::1", "loopback"
    ; "127.0.0.1", "loopback"
    ; (* systemd-resolved's stub, which a Linux host's resolv.conf names. *)
      "127.0.0.53", "loopback"
    ; "::", "unspecified"
    ; "0.0.0.0", "unspecified"
    ; "0.1.2.3", "unspecified"
    ; "ff02::1", "multicast"
    ; "224.0.0.251", "multicast"
    ]
;;

let test_a_name_is_not_an_address () =
  check_table "not an address"
    [ "dns.google", "not_an_address"
    ; "", "not_an_address"
    ; "1.1.1.1:53", "not_an_address"
    ]
;;

(* ── what the host's file says ──────────────────────────────────────── *)

let test_the_first_nameserver_line_is_read_in_every_spelling_of_the_file () =
  let first = Dns.first_nameserver_of in
  check (option string) "one space" (Some "10.0.0.1") (first "nameserver 10.0.0.1\n");
  check (option string) "a tab" (Some "10.0.0.1") (first "nameserver\t10.0.0.1\n");
  check (option string) "two spaces" (Some "10.0.0.1") (first "nameserver  10.0.0.1\n");
  check (option string) "text after the address" (Some "10.0.0.1")
    (first "nameserver 10.0.0.1 # lan\n");
  check (option string) "after other lines" (Some "fe80::1%en0")
    (first "# macOS Notice\n\ndomain lan\nnameserver fe80::1%en0\nnameserver 10.0.0.1\n");
  check (option string) "no nameserver" None (first "search lan\n");
  check (option string) "a keyword without an address" None (first "nameserver\n")
;;

(* ── who decides ────────────────────────────────────────────────────── *)

let resolve ~configured ~host =
  match Dns.microvm_dns_from ~configured ~host with
  | Ok address -> "ok " ^ Ipaddr.to_string address
  | Error _ -> "error"
;;

let scoped_host = Some "fe80::f4be:ecff:fee7:64%en0"

let test_the_workspace_names_the_resolver_before_the_host_does () =
  check string "configured wins" "ok 1.1.1.1"
    (resolve ~configured:"1.1.1.1" ~host:(Some "168.126.63.1"));
  check string "blank is unset" "ok 168.126.63.1"
    (resolve ~configured:"" ~host:(Some "168.126.63.1"));
  check string "whitespace is blank" "ok 168.126.63.1"
    (resolve ~configured:"  " ~host:(Some "168.126.63.1"))
;;

(* The operator asked for a resolver. Booting on the host's instead would say
   nothing, which is how a guest ends up resolving through a server nobody
   chose. *)
let test_a_configured_value_that_is_not_usable_never_falls_back_to_the_host () =
  check string "zone" "error"
    (resolve ~configured:"fe80::1%en0" ~host:(Some "168.126.63.1"));
  check string "name" "error"
    (resolve ~configured:"dns.google" ~host:(Some "168.126.63.1"));
  check string "loopback" "error"
    (resolve ~configured:"127.0.0.1" ~host:(Some "168.126.63.1"))
;;

let test_a_host_resolver_a_guest_cannot_use_fails_until_the_workspace_names_one () =
  check string "scoped host, nothing configured" "error"
    (resolve ~configured:"" ~host:scoped_host);
  check string "no host resolver, nothing configured" "error"
    (resolve ~configured:"" ~host:None);
  check string "scoped host, configured" "ok 168.126.63.1"
    (resolve ~configured:"168.126.63.1" ~host:scoped_host);
  check string "no host resolver, configured" "ok 168.126.63.1"
    (resolve ~configured:"168.126.63.1" ~host:None)
;;

(* The operator reads the refusal to learn what to set. *)
let test_the_refusal_of_the_host_resolver_names_the_toml_key () =
  match Dns.microvm_dns_from ~configured:"" ~host:scoped_host with
  | Ok address ->
    failf "a zone-scoped host resolver was handed on as %s" (Ipaddr.to_string address)
  | Error detail ->
    check bool "names sandbox.microvm_dns" true
      (String_util.contains_substring detail "sandbox.microvm_dns")
;;

(* What the settings surface shows. It is read for every setting before
   runtime.toml is applied, and a [Config_error] there stops the server, so it
   may fail for a value the operator set and for nothing else. *)
let shown ~configured ~host =
  match Dns.microvm_dns_effective_from ~configured ~host with
  | Ok text -> text
  | Error _ -> "error"
;;

let test_the_settings_surface_fails_only_for_a_value_the_operator_set () =
  check string "named" "168.126.63.1"
    (shown ~configured:"168.126.63.1" ~host:scoped_host);
  check string "unset shows the host's resolver" "168.126.63.1"
    (shown ~configured:"" ~host:(Some "168.126.63.1"));
  check string "named and unusable" "error"
    (shown ~configured:"fe80::1%en0" ~host:(Some "168.126.63.1"));
  (* The cases that stopped the server on the reporter's Mac: nothing named,
     and a host resolver a guest cannot use, or none. *)
  List.iter
    (fun host ->
       let text = shown ~configured:"" ~host in
       check bool "unset is shown, not raised" true
         (text <> "error" && String_util.contains_substring text "unusable: "))
    [ scoped_host; Some "127.0.0.53"; None ]
;;

(* ── runtime.toml ───────────────────────────────────────────────────── *)

let parse_or_fail source =
  match Keeper_toml_loader.parse_toml source with
  | Ok doc -> doc
  | Error detail -> fail detail
;;

let test_runtime_toml_sandbox_table_seeds_the_nameserver () =
  let doc = parse_or_fail "[sandbox]\nmicrovm_dns = \"168.126.63.1\"\n" in
  check bool "the key is a known Keeper setting" true
    (Keeper_runtime_config.validation_report_is_valid
       (Keeper_runtime_config.validate_doc doc));
  let _count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:(fun _ -> None) doc
  in
  check (option string) "the variable it seeds" (Some "168.126.63.1")
    (List.assoc_opt "MASC_KEEPER_MICROVM_DNS" overrides);
  let not_text = parse_or_fail "[sandbox]\nmicrovm_dns = 168\n" in
  check bool "a number is not a nameserver" false
    (Keeper_runtime_config.validation_report_is_valid
       (Keeper_runtime_config.validate_doc not_text))
;;

(* The registry row is the surface above, read through the projection. The
   unset case depends on the host's own resolv.conf, so the cases pinned here
   are the ones that do not. *)
let dns_row_error () =
  let open Yojson.Safe.Util in
  Keeper_runtime_config.settings_projection_to_yojson (parse_or_fail "")
  |> to_list
  |> List.find_opt (fun row ->
    String.equal (row |> member "env" |> to_string) "MASC_KEEPER_MICROVM_DNS")
  |> function
  | Some row -> row |> member "effective_error"
  | None -> fail "MASC_KEEPER_MICROVM_DNS is not a registered setting"
;;

let test_the_registry_row_reads_through_the_surface () =
  with_file_dns "168.126.63.1" (fun () ->
    check bool "a usable value reads" true (dns_row_error () = `Null));
  with_file_dns "fe80::1%en0" (fun () ->
    check bool "an unusable value is a configuration error" true
      (dns_row_error () <> `Null))
;;

(* ── the boot ───────────────────────────────────────────────────────── *)

let boot_nameserver ~backend ~network_mode =
  match Runtime.For_testing.microvm_boot_nameserver ~backend ~network_mode with
  | Ok None -> "none"
  | Ok (Some address) -> "ok " ^ Ipaddr.to_string address
  | Error _ -> "error"
;;

(* [Network_none] has nothing to resolve on and [Network_policy] boots with
   [--no-dns]. A keeper on either must still start when the workspace's value
   is wrong: its boot never reads it. Microsandbox spells its own flag and
   refuses the default network later, with a refusal about msb: a nameserver
   requirement must not come first. *)
let test_only_a_boot_that_spells_dns_reads_the_setting () =
  with_file_dns "fe80::1%en0" (fun () ->
    List.iter
      (fun backend ->
         check string "inherit refuses" "error"
           (boot_nameserver ~backend ~network_mode:Profile.Network_inherit))
      [ Backend.Apple_container; Backend.Nerdctl_kata ];
    List.iter
      (fun backend ->
         List.iter
           (fun network_mode ->
              check string "no --dns here" "none" (boot_nameserver ~backend ~network_mode))
           [ Profile.Network_none; Profile.Network_policy ])
      [ Backend.Apple_container; Backend.Nerdctl_kata; Backend.Microsandbox ];
    check string "microsandbox is not asked" "none"
      (boot_nameserver ~backend:Backend.Microsandbox ~network_mode:Profile.Network_inherit));
  with_file_dns "168.126.63.1" (fun () ->
    List.iter
      (fun backend ->
         check string "the named nameserver is handed on" "ok 168.126.63.1"
           (boot_nameserver ~backend ~network_mode:Profile.Network_inherit))
      [ Backend.Apple_container; Backend.Nerdctl_kata ])
;;

let () =
  run
    "keeper_microvm_dns"
    [ ( "nameserver"
      , [ test_case "a reachable address is a nameserver" `Quick
            test_a_reachable_address_is_a_nameserver
        ; test_case "a host-only address is refused" `Quick
            test_an_address_that_means_something_only_on_the_host_is_refused
        ; test_case "a name is not an address" `Quick test_a_name_is_not_an_address
        ] )
    ; ( "host_file"
      , [ test_case "the first nameserver line in every spelling" `Quick
            test_the_first_nameserver_line_is_read_in_every_spelling_of_the_file
        ] )
    ; ( "resolution"
      , [ test_case "the workspace names it before the host" `Quick
            test_the_workspace_names_the_resolver_before_the_host_does
        ; test_case "a bad configured value never falls back" `Quick
            test_a_configured_value_that_is_not_usable_never_falls_back_to_the_host
        ; test_case "a host resolver a guest cannot use fails" `Quick
            test_a_host_resolver_a_guest_cannot_use_fails_until_the_workspace_names_one
        ; test_case "the refusal names the toml key" `Quick
            test_the_refusal_of_the_host_resolver_names_the_toml_key
        ; test_case "the settings surface fails only for a set value" `Quick
            test_the_settings_surface_fails_only_for_a_value_the_operator_set
        ] )
    ; ( "runtime_toml"
      , [ test_case "[sandbox] seeds the nameserver" `Quick
            test_runtime_toml_sandbox_table_seeds_the_nameserver
        ; test_case "the registry row reads through the surface" `Quick
            test_the_registry_row_reads_through_the_surface
        ] )
    ; ( "boot"
      , [ test_case "only a boot that spells --dns reads the setting" `Quick
            test_only_a_boot_that_spells_dns_reads_the_setting
        ] )
    ]
;;
