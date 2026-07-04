open Alcotest

let string_contains haystack needle =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen > hlen then false
  else
    let found = ref false in
    for i = 0 to hlen - nlen do
      if not !found && String.sub haystack i nlen = needle then found := true
    done;
    !found
;;

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      In_channel.input_all ic)
;;

let rec find_source_root_from dir hops rel =
  if hops > 8 then None
  else if Sys.file_exists (Filename.concat dir rel) then Some dir
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then None
    else find_source_root_from parent (hops + 1) rel
;;

let source_root () =
  let anchor = "scripts/install.sh" in
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root
    when String.trim root <> "" && Sys.file_exists (Filename.concat root anchor) ->
    root
  | _ ->
    (match find_source_root_from (Sys.getcwd ()) 0 anchor with
     | Some root -> root
     | None -> fail "could not locate repo source root")
;;

let install_script () = read_file (Filename.concat (source_root ()) "scripts/install.sh")

let release_workflow () =
  read_file (Filename.concat (source_root ()) ".github/workflows/release.yml")
;;

let assert_contains label text needle =
  check bool label true (string_contains text needle)
;;

let assert_not_contains label text needle =
  check bool label false (string_contains text needle)
;;

let test_config_seed_skips_each_existing_file_without_force () =
  let script = install_script () in
  assert_contains
    "per-file seed helper exists"
    script
    "seed_config_if_missing()";
  assert_contains
    "existing config file skips without force"
    script
    {|if [ -e "$dest" ] && [ "$FORCE" -eq 0 ]; then|};
  assert_contains
    "tool policy uses per-file seed"
    script
    {|seed_config_if_missing "tool_policy.toml" "$CONFIG_FILE"|};
  assert_contains
    "runtime uses per-file seed"
    script
    {|seed_config_if_missing "runtime.toml" "$RUNTIME_FILE"|};
  assert_contains
    "model catalog has config-root destination"
    script
    {|MODEL_CATALOG_FILE="$CONFIG_DIR/oas-models.toml"|};
  assert_contains
    "model catalog uses root release seed"
    script
    {|seed_raw_if_missing "oas-models.toml" "oas-models.toml" "$MODEL_CATALOG_FILE"|};
  assert_not_contains
    "no all-or-nothing seed calls"
    script
    {|seed_config "tool_policy.toml" "$CONFIG_FILE"
    seed_config "runtime.toml" "$RUNTIME_FILE"|}
;;

let test_release_requires_advertised_binary_assets () =
  let workflow = release_workflow () in
  assert_contains
    "release checks advertised asset list"
    workflow
    "for asset in masc-macos-arm64 masc-linux-x64; do";
  assert_contains
    "release fails when required asset is absent"
    workflow
    "required release asset missing: $asset"
;;

let test_release_checksums_include_model_catalog_seed () =
  let workflow = release_workflow () in
  assert_contains
    "release checksum includes runtime config seeds"
    workflow
    "(cd ../config && sha256sum tool_policy.toml runtime.toml) >> SHA256SUMS";
  assert_contains
    "release checksum includes model catalog seed"
    workflow
    "(cd .. && sha256sum oas-models.toml) >> SHA256SUMS"
;;

let () =
  run
    "install_script"
    [ ( "config_seed"
      , [ test_case
            "partial existing config is not overwritten without force"
            `Quick
            test_config_seed_skips_each_existing_file_without_force
        ; test_case
            "advertised binary assets are release-required"
            `Quick
            test_release_requires_advertised_binary_assets
        ; test_case
            "release checksums include model catalog seed"
            `Quick
            test_release_checksums_include_model_catalog_seed
        ] )
    ]
;;
