open Alcotest

(** RFC-0084 host-config-cleanup-A — credential root migration.

    PR-A delegates [Host_config_provider.cred_root] to
    [Host_config.legacy_macos_default ().cred_root] instead of the
    ad-hoc literal ["/tmp/keeper-creds"], establishing a single
    source of truth for the constant.

    Behaviour is byte-identical today; the migration is structural
    (single literal -> typed surface) so that subsequent PRs can flip
    [Host_config.legacy_macos_default] to a [resolve ~base_path]-relative
    value without touching [host_config_provider.ml]. *)

let pinned_tmp_keeper_creds_literal = 0

let read_file path =
  match In_channel.with_open_text path In_channel.input_all with
  | exception _ -> ""
  | content -> content
;;

let count_substring ~haystack ~needle =
  let rec loop i acc =
    let next = String.index_from_opt haystack i needle.[0] in
    match next with
    | None -> acc
    | Some j ->
      let len = String.length needle in
      if j + len <= String.length haystack
         && String.sub haystack j len = needle
      then loop (j + len) (acc + 1)
      else loop (j + 1) acc
  in
  loop 0 0
;;

let test_no_tmp_keeper_creds_literal_in_provider () =
  let content = read_file "lib/keeper/host_config_provider.ml" in
  let occurrences =
    count_substring ~haystack:content ~needle:{|"/tmp/keeper-creds"|}
  in
  (check int)
    "literal `\"/tmp/keeper-creds\"` must be 0 in \
     lib/keeper/host_config_provider.ml after PR-A"
    pinned_tmp_keeper_creds_literal occurrences
;;

let test_host_config_called_in_provider () =
  let content = read_file "lib/keeper/host_config_provider.ml" in
  let occurrences =
    count_substring ~haystack:content
      ~needle:"Host_config.legacy_macos_default"
  in
  (check bool)
    "Host_config.legacy_macos_default must be invoked from \
     lib/keeper/host_config_provider.ml after PR-A"
    true (occurrences >= 1)
;;

let test_cred_root_byte_identical_to_typed_surface () =
  (* Today's behaviour is preserved: [Host_config_provider.cred_root]
     and [Host_config.legacy_macos_default ().cred_root] must hold
     the same string at module-init time. *)
  let typed = (Masc_mcp.Host_config.legacy_macos_default ()).cred_root in
  let provider = Masc_mcp.Host_config_provider.cred_root in
  (check string)
    "Host_config_provider.cred_root must equal \
     Host_config.legacy_macos_default ().cred_root"
    typed provider
;;

let () =
  run
    "PR-A host-config-cleanup-A (cred_root)"
    [ ( "pr-a-cred-root"
      , [ test_case "no-tmp-keeper-creds-literal-in-provider" `Quick
            test_no_tmp_keeper_creds_literal_in_provider
        ; test_case "host-config-called-in-provider" `Quick
            test_host_config_called_in_provider
        ; test_case "cred-root-byte-identical-to-typed-surface" `Quick
            test_cred_root_byte_identical_to_typed_surface
        ] )
    ]
;;
