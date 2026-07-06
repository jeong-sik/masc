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

let write_file path content =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
      output_string oc content)
;;

let write_runtime_catalog
    ?(default = "ollama_cloud.deepseek-v4-flash")
    ?(deepseek_display_name = "DeepSeek API")
    base_path
  =
  let config_dir = Filename.concat base_path ".masc/config" in
  let runtime_file = Filename.concat config_dir "runtime.toml" in
  ignore (Sys.command ("mkdir -p " ^ Filename.quote config_dir));
  write_file
    runtime_file
    (Printf.sprintf
       {|
[runtime]
default = "%s"

[providers.ollama_cloud]
display-name = "Ollama Cloud"
protocol = "openai-compatible-http"
endpoint = "https://ollama.com/v1"

[providers.ollama_cloud.healthcheck]
path = "/models"

[providers.ollama_cloud.credentials]
type = "env"
key = "OLLAMA_CLOUD_API_KEY"

[providers.deepseek]
display-name = "%s"
protocol = "openai-compatible-http"
endpoint = "https://api.deepseek.com"

[providers.deepseek.healthcheck]
path = "/models"

[providers.deepseek.credentials]
type = "env"
key = "DEEPSEEK_API_KEY"

[providers.ollama]
display-name = "Local Ollama"
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[providers.ollama.healthcheck]
path = "/api/tags"

[models.deepseek-v4-flash]
api-name = "deepseek-v4-flash"
max-context = 1048576
tools-support = true
thinking-support = true
streaming = true

[models.gemma4-26b-a4b-qat]
api-name = "gemma4-26b-a4b-qat"
max-context = 262144
tools-support = true
thinking-support = true
streaming = true

[ollama_cloud.deepseek-v4-flash]
wizard-default = true

[deepseek.deepseek-v4-flash]
wizard-default = true

[ollama.gemma4-26b-a4b-qat]
wizard-default = true
|}
       default
       deepseek_display_name);
  runtime_file
;;

let write_runtime_catalog_with_invalid_key base_path =
  let config_dir = Filename.concat base_path ".masc/config" in
  let runtime_file = Filename.concat config_dir "runtime.toml" in
  ignore (Sys.command ("mkdir -p " ^ Filename.quote config_dir));
  write_file
    runtime_file
    {|
[runtime]
default = "deepseek.deepseek-v4-flash"

[providers.deepseek]
display-name = "DeepSeek API"
protocol = "openai-compatible-http"
endpoint = "https://api.deepseek.com"

[providers.deepseek.credentials]
type = "env"
key = "BAD-KEY"

[models.deepseek-v4-flash]
api-name = "deepseek-v4-flash"
max-context = 1048576
tools-support = true
thinking-support = true
streaming = true

[deepseek.deepseek-v4-flash]
wizard-default = true
|};
  runtime_file
;;

let write_runtime_catalog_with_masc_api_key_provider base_path =
  let config_dir = Filename.concat base_path ".masc/config" in
  let runtime_file = Filename.concat config_dir "runtime.toml" in
  ignore (Sys.command ("mkdir -p " ^ Filename.quote config_dir));
  write_file
    runtime_file
    {|
[runtime]
default = "generic.deepseek-v4-flash"

[providers.generic]
display-name = "Generic OpenAI-compatible"
protocol = "openai-compatible-http"
endpoint = "https://example.invalid"

[providers.generic.healthcheck]
path = "/models"

[providers.generic.credentials]
type = "env"
key = "MASC_API_KEY"

[models.deepseek-v4-flash]
api-name = "deepseek-v4-flash"
max-context = 1048576
tools-support = true
thinking-support = true
streaming = true

[generic.deepseek-v4-flash]
wizard-default = true
|};
  runtime_file
;;

let write_runtime_catalog_with_dotted_provider_id base_path =
  let config_dir = Filename.concat base_path ".masc/config" in
  let runtime_file = Filename.concat config_dir "runtime.toml" in
  ignore (Sys.command ("mkdir -p " ^ Filename.quote config_dir));
  write_file
    runtime_file
    {|
[runtime]
default = "deep.seek.deepseek-v4-flash"

[providers."deep.seek"]
display-name = "Dotted DeepSeek"
protocol = "openai-compatible-http"
endpoint = "https://api.deepseek.com"

[providers."deep.seek".healthcheck]
path = "/models"

[providers."deep.seek".credentials]
type = "env"
key = "DEEPSEEK_API_KEY"

[models.deepseek-v4-flash]
api-name = "deepseek-v4-flash"
max-context = 1048576
tools-support = true
thinking-support = true
streaming = true

["deep.seek".deepseek-v4-flash]
wizard-default = true
|};
  runtime_file
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

let project_version () =
  let raw = read_file (Filename.concat (source_root ()) "dune-project") in
  let prefix = "(version " in
  raw
  |> String.split_on_char '\n'
  |> List.find_map (fun line ->
    let line = String.trim line in
    let prefix_len = String.length prefix in
    if String.length line > prefix_len
       && String.sub line 0 prefix_len = prefix
       && line.[String.length line - 1] = ')'
    then
      Some
        (String.sub line prefix_len (String.length line - prefix_len - 1))
    else None)
  |> function
  | Some version -> version
  | None -> fail "could not parse dune-project version"
;;

let release_tag () =
  let version = project_version () in
  if String.length version > 0 && version.[0] = 'v' then version else "v" ^ version
;;

let real_masc_binary () =
  match Sys.getenv_opt "MASC_INSTALL_TEST_MASC" with
  | Some path when String.trim path <> "" ->
    if Sys.file_exists path then path
    else failf "MASC_INSTALL_TEST_MASC does not exist: %s" path
  | _ ->
    let root = source_root () in
    let candidates =
      [ Filename.concat root "_build/default/bin/main_eio.exe"
      ; Filename.concat (Sys.getcwd ()) "_build/default/bin/main_eio.exe"
      ]
    in
    (match List.find_opt Sys.file_exists candidates with
     | Some path -> path
     | None ->
       fail
         "main_eio executable not found. Build dependency ../bin/main_eio.exe or set MASC_INSTALL_TEST_MASC.")
;;

let unlink_if_exists path =
  try Unix.unlink path with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let install_real_masc_binary prefix =
  let dest = Filename.concat prefix "masc" in
  ignore (Sys.command ("mkdir -p " ^ Filename.quote prefix));
  unlink_if_exists dest;
  Unix.symlink (Unix.realpath (real_masc_binary ())) dest
;;

let assert_contains label text needle =
  check bool label true (string_contains text needle)
;;

let assert_not_contains label text needle =
  check bool label false (string_contains text needle)
;;

(* Mirror install.sh's detect_asset so the staged release names the asset the
   script will request for this platform. *)
let platform_release_asset () =
  let uname flag =
    let ic = Unix.open_process_in ("uname " ^ flag) in
    let line = try String.trim (input_line ic) with End_of_file -> "" in
    ignore (Unix.close_process_in ic);
    line
  in
  match uname "-s", uname "-m" with
  | "Darwin", "arm64" -> "masc-macos-arm64"
  | "Linux", "x86_64" -> "masc-linux-x64"
  | os, arch -> failf "unsupported test platform for release asset: %s/%s" os arch
;;

(* Stage a file:// release mirror under [base_path] so install paths that
   download (e.g. the --force refresh) exercise the real curl+install flow
   hermetically instead of depending on a published GitHub release for the
   HEAD version — the forced-wizard tests broke on exactly that 404 when
   dune-project moved past the latest published release. SHA256SUMS is
   deliberately absent: the harness passes --allow-unverified, which
   downgrades missing checksums to a warning. *)
let stage_release_mirror base_path =
  let dir = Filename.concat base_path (Filename.concat ".release" (release_tag ())) in
  ignore (Sys.command ("mkdir -p " ^ Filename.quote dir));
  let asset = Filename.concat dir (platform_release_asset ()) in
  unlink_if_exists asset;
  Unix.symlink (Unix.realpath (real_masc_binary ())) asset;
  "file://" ^ Filename.concat base_path ".release"
;;

let run_install_status ?(extra_env = "") args base_path =
  let root = source_root () in
  let script = Filename.concat root "scripts/install.sh" in
  let prefix = Filename.concat base_path ".local" in
  install_real_masc_binary prefix;
  let release_base_url = stage_release_mirror base_path in
  let quoted_args = String.concat " " (List.map Filename.quote args) in
  let cmd =
    Printf.sprintf
      "%s%sMASC_RELEASE_BASE_URL=%s MASC_PREFIX=%s MASC_VERSION=%s MASC_BASE_PATH=%s bash %s --allow-unverified --no-seed --base-path %s %s 2>&1"
      extra_env
      (if String.equal extra_env "" then "" else " ")
      (Filename.quote release_base_url)
      (Filename.quote prefix)
      (Filename.quote (release_tag ()))
      (Filename.quote base_path)
      (Filename.quote script)
      (Filename.quote base_path)
      quoted_args
  in
  let ic = Unix.open_process_in cmd in
  let closed = ref false in
  Fun.protect
    ~finally:(fun () -> if not !closed then ignore (Unix.close_process_in ic))
    (fun () ->
       let output = In_channel.input_all ic in
       closed := true;
       let status = Unix.close_process_in ic in
       output, status)
;;

let run_install_status_with_stdin stdin args base_path =
  let root = source_root () in
  let script = Filename.concat root "scripts/install.sh" in
  let prefix = Filename.concat base_path ".local" in
  install_real_masc_binary prefix;
  let release_base_url = stage_release_mirror base_path in
  let quoted_args = String.concat " " (List.map Filename.quote args) in
  let cmd =
    Printf.sprintf
      "printf '%%s\\n' %s | MASC_RELEASE_BASE_URL=%s MASC_PREFIX=%s MASC_VERSION=%s \
       MASC_BASE_PATH=%s bash %s --allow-unverified --no-seed --base-path %s %s 2>&1"
      (Filename.quote stdin)
      (Filename.quote release_base_url)
      (Filename.quote prefix)
      (Filename.quote (release_tag ()))
      (Filename.quote base_path)
      (Filename.quote script)
      (Filename.quote base_path)
      quoted_args
  in
  let ic = Unix.open_process_in cmd in
  let closed = ref false in
  Fun.protect
    ~finally:(fun () -> if not !closed then ignore (Unix.close_process_in ic))
    (fun () ->
       let output = In_channel.input_all ic in
       closed := true;
       let status = Unix.close_process_in ic in
       output, status)
;;

let run_install args base_path =
  let output, status = run_install_status args base_path in
  match status with
  | Unix.WEXITED 0 -> output
  | _ ->
    Alcotest.fail
      (Printf.sprintf "install.sh exited with non-zero status: %s"
         (String.concat " " (List.map Filename.quote args)))
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
    "required release asset missing: $asset";
  assert_contains
    "release hashes seeded model catalog"
    workflow
    "(cd .. && sha256sum oas-models.toml) >> SHA256SUMS"
;;

let test_binary_checks_use_install_environment () =
  let script = install_script () in
  assert_contains
    "model catalog file lives under config root"
    script
    {|MODEL_CATALOG_FILE="$BASE_PATH/.masc/config/oas-models.toml"|};
  assert_contains
    "binary helper exports base path"
    script
    {|MASC_BASE_PATH="$BASE_PATH"|};
  assert_contains
    "binary helper documents dual base path env"
    script
    "MASC_BASE_PATH is the resolved runtime root";
  assert_contains
    "binary helper exports base path input"
    script
    {|MASC_BASE_PATH_INPUT="$BASE_PATH"|};
  assert_contains
    "binary helper exports model catalog"
    script
    {|OAS_MODEL_CATALOG="$catalog"|};
  assert_contains
    "binary smoke helper isolates runtime events by default"
    script
    {|MASC_RUNTIME_EVENTS="${MASC_RUNTIME_EVENTS:-0}"|};
  assert_contains
    "existing binary check uses install env"
    script
    {|if masc_responds_to_version "$DEST"; then|};
  assert_contains
    "start hint preserves explicit runtime events override"
    script
    {|runtime_events_start_env="MASC_RUNTIME_EVENTS=\"$MASC_RUNTIME_EVENTS\" "|};
  assert_contains
    "start hint omits runtime events default"
    script
    {|start_env="${runtime_events_start_env}MASC_BASE_PATH=\"$BASE_PATH\" MASC_BASE_PATH_INPUT=\"$BASE_PATH\""|};
  assert_contains
    "start hint documents dual base path env"
    script
    "let the binary's default-on contract apply";
  assert_not_contains
    "start hint does not disable runtime events by default"
    script
    {|start_env="MASC_RUNTIME_EVENTS=\"${MASC_RUNTIME_EVENTS:-0}\" MASC_BASE_PATH=\"$BASE_PATH\" MASC_BASE_PATH_INPUT=\"$BASE_PATH\""|};
  assert_contains
    "smoke reads reported version through install env"
    script
    {|reported=$(masc_reported_version "$DEST")|};
  assert_not_contains
    "existing binary check does not call bare DEST --version"
    script
    {|if "$DEST" --version >/dev/null 2>&1; then|};
  assert_not_contains
    "smoke check does not call bare DEST --version"
    script
    {|reported=$("$DEST" --version 2>/dev/null | tail -n1)|}
;;

let test_force_refreshes_same_version_existing_binary () =
  let tmpdir = Filename.temp_file "masc-install-force-refresh-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
       let output = run_install [ "--dry-run"; "--force"; "--no-wizard" ] tmpdir in
       assert_contains
         "force refreshes same-version binary"
         output
         "refreshing because --force is set";
       assert_contains
         "force reaches download path"
         output
         "[dry-run] would download to";
       assert_not_contains "force does not skip binary download" output "skipping download")
;;

let test_wizard_flags_exist () =
  let script = install_script () in
  assert_contains "wizard flag" script "--wizard";
  assert_contains "no-wizard flag" script "--no-wizard";
  assert_contains "provider flag" script "--provider";
  assert_contains "api-key flag" script "--api-key";
  assert_contains "api-key stdin flag" script "--api-key-stdin";
  assert_contains "api-key argv warning" script "visible in ps"
;;

let test_wizard_prompts_exist () =
  let script = install_script () in
  assert_contains "provider prompt" script "Choose your default provider";
  assert_contains "key prompt" script "Enter %s";
  assert_contains "connectivity prompt" script "Test connectivity"
;;

let test_env_local_writer_exists () =
  let script = install_script () in
  assert_contains "write_env_local function" script "write_env_local()";
  assert_contains "env.local created under private umask" script "( umask 077";
  assert_contains
    "env.local uses private temp before replace"
    script
    {|mktemp "$env_dir/.env.local.tmp.XXXXXX"|};
  assert_contains
    "env.local atomically replaces final path"
    script
    {|mv -f "$tmp" "$env_file"|};
  assert_contains "env.local chmod 600" script "chmod 600";
  assert_contains
    "env.local chmod failure is fatal"
    script
    "could not restrict permissions on $env_file"
;;

let test_partial_files_are_cleaned_by_exit_trap () =
  let script = install_script () in
  assert_contains "partial tracker exists" script "PARTIAL_FILES=()";
  assert_contains "download partial is tracked" script {|PARTIAL_FILES+=("$tmp")|};
  assert_contains "trap cleans partials" script "for partial in";
  assert_contains "trap removes partials" script {|rm -f "$partial"|}
;;

let test_provider_catalog_comes_from_runtime_toml () =
  let script = install_script () in
  assert_contains
    "provider catalog loader calls typed binary export"
    script
    {|runtime-wizard-catalog --base-path "$base_path"|};
  assert_contains "runtime id array exists" script "PROVIDER_DEFAULT_RUNTIME_IDS=()";
  assert_contains "provider ping path array exists" script "PROVIDER_PING_PATHS=()";
  assert_not_contains "installer does not strip TOML comments" script "strip_toml_comment()";
  assert_not_contains "installer does not parse TOML strings" script "toml_string_value()";
  assert_not_contains
    "installer does not parse provider sections with bash regex"
    script
    {|^\\[providers\\.|};
  assert_contains
    "provider catalog parser reads binary-safe fields"
    script
    {|read -r -d ''|};
  assert_not_contains
    "provider catalog parser does not use pipe-delimited fields"
    script
    {|IFS='|'|};
  assert_not_contains
    "provider catalog parser has no pipe-delimited TODO"
    script
    "pipe-delimited";
  assert_not_contains
    "no hardcoded provider id catalog"
    script
    "PROVIDER_IDS=(ollama_cloud deepseek glm-coding ollama)";
  assert_not_contains
    "no hardcoded endpoint catalog"
    script
    "https://api.deepseek.com";
  assert_not_contains
    "no hardcoded provider ping endpoint"
    script
    "/v1/models"
;;

let test_provider_display_name_with_pipe_round_trips () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      ignore (write_runtime_catalog ~deepseek_display_name:"Deep|Seek API" tmpdir);
      let output, status =
        run_install_status
          [ "--dry-run"; "--provider"; "deepseek"; "--api-key"; "fake-key" ]
          tmpdir
      in
      check bool "display name with pipe exits 0" true (status = Unix.WEXITED 0);
      assert_contains
        "dry-run default update logged"
        output
        "[dry-run] would set [runtime].default";
      assert_not_contains
        "display name pipe does not corrupt catalog"
        output
        "invalid provider wizard catalog";
      assert_not_contains
        "display name pipe does not truncate catalog"
        output
        "truncated provider wizard catalog record")
;;

let test_default_provider_uses_binding_lookup () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      ignore (write_runtime_catalog_with_dotted_provider_id tmpdir);
      let output, status =
        run_install_status
          [ "--dry-run"; "--provider"; "deep.seek"; "--api-key"; "fake-key" ]
          tmpdir
      in
      check bool "dotted provider id exits 0" true (status = Unix.WEXITED 0);
      assert_contains
        "dotted provider default logged"
        output
        {|[dry-run] would set [runtime].default = "deep.seek.deepseek-v4-flash"|};
      assert_not_contains
        "dotted provider id is not split at dot"
        output
        "default runtime id is not present in provider bindings";
      assert_not_contains
        "dotted provider id is not treated as missing provider"
        output
        "default-provider is not present in provider entries")
;;

let test_provider_ping_does_not_expose_key_in_curl_argv () =
  let script = install_script () in
  assert_contains
    "provider ping uses curl header file descriptor"
    script
    {|-H @<(printf 'Authorization: Bearer %s\n' "$key")|};
  assert_not_contains
    "provider ping does not pass key in argv"
    script
    {|-H "Authorization: Bearer $key"|}
;;

let test_no_wizard_does_not_write_env_local () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  let env_file = Filename.concat tmpdir ".masc/config/.env.local" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      let _output = run_install [ "--no-wizard" ] tmpdir in
      check bool "env.local not written with --no-wizard" false (Sys.file_exists env_file))
;;

let test_dry_run_masks_key () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  let env_file = Filename.concat tmpdir ".masc/config/.env.local" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      ignore (write_runtime_catalog tmpdir);
      let output =
        run_install [ "--dry-run"; "--provider"; "deepseek"; "--api-key"; "supersecret123" ] tmpdir
      in
      assert_contains "masked key in dry-run" output "DEEPSEEK_API_KEY=***";
      assert_not_contains "raw key not in dry-run" output "supersecret123";
      check bool "env.local not written in dry-run" false (Sys.file_exists env_file))
;;

let test_wizard_writes_env_local () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  let env_file = Filename.concat tmpdir ".masc/config/.env.local" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      ignore (write_runtime_catalog tmpdir);
      let _output = run_install [ "--provider"; "deepseek"; "--api-key"; "fake-key-123" ] tmpdir in
      check bool "env.local written" true (Sys.file_exists env_file);
      let content = read_file env_file in
      assert_contains "export line" content "export DEEPSEEK_API_KEY=";
      assert_contains "key value" content "fake-key-123";
      let st = Unix.stat env_file in
      check int "env.local permissions are 0o600" 0o600 (st.Unix.st_perm land 0o777))
;;

let test_forced_env_local_replaces_symlink_without_touching_target () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  let env_file = Filename.concat tmpdir ".masc/config/.env.local" in
  let symlink_target = Filename.concat tmpdir "outside-target" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      ignore (write_runtime_catalog tmpdir);
      write_file symlink_target "do-not-touch\n";
      Unix.symlink symlink_target env_file;
      let _output =
        run_install
          [ "--force"; "--provider"; "deepseek"; "--api-key"; "replacement-key" ]
          tmpdir
      in
      check string "symlink target unchanged" "do-not-touch\n" (read_file symlink_target);
      check
        bool
        "env.local is regular file"
        true
        ((Unix.lstat env_file).Unix.st_kind = Unix.S_REG);
      let content = read_file env_file in
      assert_contains "replacement key written to env.local" content "replacement-key";
      let st = Unix.stat env_file in
      check int "replacement env.local permissions are 0o600" 0o600 (st.Unix.st_perm land 0o777))
;;

let test_api_key_stdin_writes_env_local () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  let env_file = Filename.concat tmpdir ".masc/config/.env.local" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      ignore (write_runtime_catalog tmpdir);
      let output, status =
        run_install_status_with_stdin
          "stdin-key-123"
          [ "--provider"; "deepseek"; "--api-key-stdin" ]
          tmpdir
      in
      check bool "api-key-stdin exits zero" true (status = Unix.WEXITED 0);
      assert_not_contains "stdin key not echoed" output "stdin-key-123";
      check bool "env.local written" true (Sys.file_exists env_file);
      let content = read_file env_file in
      assert_contains "stdin key value" content "stdin-key-123")
;;

let test_empty_api_key_stdin_errors () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      ignore (write_runtime_catalog tmpdir);
      let output, status =
        run_install_status_with_stdin "" [ "--provider"; "deepseek"; "--api-key-stdin" ] tmpdir
      in
      check bool "empty api-key-stdin exits nonzero" true (status <> Unix.WEXITED 0);
      assert_contains "empty stdin key is fatal" output "requires a non-empty key")
;;

let test_wizard_updates_runtime_default () =
  let script = install_script () in
  assert_contains
    "runtime default uses masc typed writer"
    script
    {|"$DEST" runtime-default-set --base-path "$base_path" "$runtime_id"|};
  assert_not_contains
    "runtime default writer no longer shells out to sed"
    script
    "sed -E";
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      let runtime_file = write_runtime_catalog tmpdir in
      let _output = run_install [ "--provider"; "deepseek"; "--api-key"; "fake-key" ] tmpdir in
      let content = read_file runtime_file in
      assert_contains
        "default updated to concrete deepseek runtime"
        content
        "default = \"deepseek.deepseek-v4-flash\"")
;;

let test_unknown_provider_aborts () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      ignore (write_runtime_catalog tmpdir);
      let output, status = run_install_status [ "--provider"; "not-a-real-provider"; "--api-key"; "x" ] tmpdir in
      check bool "script fails for unknown provider" true (status <> Unix.WEXITED 0);
      assert_contains "unknown provider message" output "unknown provider")
;;

let test_unknown_default_provider_aborts () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      ignore (write_runtime_catalog ~default:"missing.deepseek-v4-flash" tmpdir);
      let output, status =
        run_install_status [ "--dry-run"; "--provider"; "deepseek"; "--api-key"; "fake-key" ] tmpdir
      in
      check bool "script fails for unknown default provider" true (status <> Unix.WEXITED 0);
      assert_contains
        "unknown default provider message"
        output
        "default runtime id is not present in provider bindings")
;;

let test_key_with_shell_metachars_is_safely_quoted () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  let env_file = Filename.concat tmpdir ".masc/config/.env.local" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      ignore (write_runtime_catalog tmpdir);
      let key = "fake\"key'$HOME`date`" in
      let _output =
        run_install [ "--provider"; "deepseek"; "--api-key"; key ] tmpdir
      in
      let cmd =
        Printf.sprintf
          "bash -c 'source %s && printf \"%%s\" \"$DEEPSEEK_API_KEY\"' 2>&1"
          (Filename.quote env_file)
      in
      let ic = Unix.open_process_in cmd in
      let sourced =
        Fun.protect
          ~finally:(fun () -> ignore (Unix.close_process_in ic))
          (fun () -> In_channel.input_all ic)
      in
      check string "sourced key matches original" key sourced)
;;

let test_local_provider_omits_env_local () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  let env_file = Filename.concat tmpdir ".masc/config/.env.local" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      ignore (write_runtime_catalog tmpdir);
      let _output = run_install [ "--provider"; "ollama"; "--api-key"; "ignored" ] tmpdir in
      check bool "env.local not written for local provider" false (Sys.file_exists env_file))
;;

let runtime_toml_or_fail path =
  match Otoml.Parser.from_file_result path with
  | Ok toml -> toml
  | Error msg -> failf "runtime TOML parse failed: %s" msg
;;

let provider_entries_in_runtime_toml path =
  let toml = runtime_toml_or_fail path in
  match Otoml.find_opt toml Fun.id [ "providers" ] with
  | None -> fail "runtime.toml should define [providers]"
  | Some providers -> Otoml.get_table providers
;;

let provider_ids_in_runtime_toml path =
  provider_entries_in_runtime_toml path |> List.map fst |> List.sort String.compare
;;

let provider_healthcheck_path provider_tbl =
  Otoml.find_opt provider_tbl Otoml.get_string [ "healthcheck"; "path" ]
;;

let test_wizard_skips_existing_env_local () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  let env_file = Filename.concat tmpdir ".masc/config/.env.local" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      ignore (write_runtime_catalog tmpdir);
      write_file env_file "# existing\n";
      let output = run_install [ "--provider"; "deepseek"; "--api-key"; "fake" ] tmpdir in
      assert_contains "skip message" output "already exists; skipping";
      check string "existing env.local preserved" "# existing\n" (read_file env_file))
;;

let test_wizard_dry_run_no_seed_skips () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      let output, status = run_install_status [ "--dry-run"; "--no-seed" ] tmpdir in
      check bool "dry-run + no-seed exits 0" true (status = Unix.WEXITED 0);
      assert_contains "skip message" output "runtime.toml not found; skipping")
;;

let test_wizard_forced_without_catalog_errors () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      let output, status = run_install_status [ "--dry-run"; "--no-seed"; "--wizard" ] tmpdir in
      check bool "forced wizard without catalog fails" true (status <> Unix.WEXITED 0);
      assert_contains "catalog missing message" output "runtime.toml not found")
;;

let test_masc_api_key_does_not_cross_provider () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      ignore (write_runtime_catalog tmpdir);
      let output, status =
        run_install_status
          ~extra_env:"env -u DEEPSEEK_API_KEY MASC_API_KEY=envsecret123"
          [ "--dry-run"; "--provider"; "deepseek" ]
          tmpdir
      in
      check bool "MASC_API_KEY for different provider exits nonzero" true
        (status <> Unix.WEXITED 0);
      assert_contains
        "missing provider-specific key message"
        output
        "API key for DEEPSEEK_API_KEY is required in non-TTY mode";
      assert_not_contains "raw env key not leaked" output "envsecret123")
;;

let test_masc_api_key_env_var_when_provider_declares_it () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  let env_file = Filename.concat tmpdir ".masc/config/.env.local" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      ignore (write_runtime_catalog_with_masc_api_key_provider tmpdir);
      let output, status =
        run_install_status
          ~extra_env:"MASC_API_KEY=envsecret123"
          [ "--dry-run"; "--provider"; "generic" ]
          tmpdir
      in
      check bool "MASC_API_KEY-declared provider dry-run exits 0" true
        (status = Unix.WEXITED 0);
      assert_contains "masked key from env" output "MASC_API_KEY=***";
      assert_not_contains "raw env key not leaked" output "envsecret123";
      check bool "env.local not written in dry-run" false (Sys.file_exists env_file))
;;

let test_provider_key_env_var_precedes_masc_api_key () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  let env_file = Filename.concat tmpdir ".masc/config/.env.local" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      ignore (write_runtime_catalog tmpdir);
      let output, status =
        run_install_status
          ~extra_env:"DEEPSEEK_API_KEY=providersecret123 MASC_API_KEY=genericsecret456"
          [ "--provider"; "deepseek" ]
          tmpdir
      in
      check bool "provider-specific env exits 0" true (status = Unix.WEXITED 0);
      assert_not_contains "provider key not printed" output "providersecret123";
      assert_not_contains "generic key not printed" output "genericsecret456";
      let content = read_file env_file in
      assert_contains "provider-specific key written" content "providersecret123";
      assert_not_contains "generic fallback not written" content "genericsecret456")
;;

let test_provider_without_key_errors_in_non_tty () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      ignore (write_runtime_catalog tmpdir);
      let output, status =
        run_install_status
          ~extra_env:"env -u DEEPSEEK_API_KEY -u MASC_API_KEY"
          [ "--dry-run"; "--provider"; "deepseek" ]
          tmpdir
      in
      check bool "provider without key exits nonzero" true (status <> Unix.WEXITED 0);
      assert_contains
        "missing key message"
        output
        "API key for DEEPSEEK_API_KEY is required in non-TTY mode")
;;

let test_invalid_provider_key_env_name_errors () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      ignore (write_runtime_catalog_with_invalid_key tmpdir);
      let output, status =
        run_install_status [ "--dry-run"; "--provider"; "deepseek"; "--api-key"; "x" ] tmpdir
      in
      check bool "invalid credential key exits nonzero" true (status <> Unix.WEXITED 0);
      assert_contains
        "invalid credential key message"
        output
        "credential key must be a valid environment variable name")
;;

let test_wizard_parses_real_runtime_toml () =
  let root = source_root () in
  let real_runtime = Filename.concat root "config/runtime.toml" in
  let ids = provider_ids_in_runtime_toml real_runtime in
  check bool "real runtime.toml has providers" true (ids <> []);
  List.iter
    (fun id ->
       let tmpdir = Filename.temp_file "masc-install-ratchet-" "" in
       Sys.remove tmpdir;
       Unix.mkdir tmpdir 0o700;
       Fun.protect
         ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
         (fun () ->
            let config_dir = Filename.concat tmpdir ".masc/config" in
            ignore (Sys.command ("mkdir -p " ^ Filename.quote config_dir));
            ignore
              (Sys.command
                 (Printf.sprintf
                    "cp %s %s"
                    (Filename.quote real_runtime)
                    (Filename.quote (Filename.concat config_dir "runtime.toml"))));
            let output, status =
              run_install_status
                [ "--dry-run"; "--provider"; id; "--api-key"; "x" ]
                tmpdir
            in
            check bool ("dry-run succeeds for provider " ^ id) true (status = Unix.WEXITED 0);
            assert_contains
              ("dry-run default update logged for provider " ^ id)
              output
              "[dry-run] would set [runtime].default"))
    ids
;;

let test_real_runtime_toml_provider_healthchecks () =
  let root = source_root () in
  let real_runtime = Filename.concat root "config/runtime.toml" in
  provider_entries_in_runtime_toml real_runtime
  |> List.iter (fun (id, provider_tbl) ->
    match provider_healthcheck_path provider_tbl with
    | Some path when String.length path > 0 && path.[0] = '/' -> ()
    | Some path -> failf "provider %s healthcheck.path must be absolute, got %s" id path
    | None ->
        (* Missing healthcheck.path is advisory; the installer skips the ping. *)
        ())
;;

let test_missing_provider_flag_value_errors () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      let output, status = run_install_status [ "--provider" ] tmpdir in
      check bool "missing provider value exits nonzero" true (status <> Unix.WEXITED 0);
      assert_contains "missing provider value message" output "--provider requires a value")
;;

let test_runtime_default_failure_does_not_write_env_local () =
  if Unix.geteuid () = 0 then Alcotest.skip ();
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  let env_file = Filename.concat tmpdir ".masc/config/.env.local" in
  let runtime_file = write_runtime_catalog tmpdir in
  let config_dir = Filename.dirname runtime_file in
  Unix.chmod config_dir 0o500;
  Fun.protect
    ~finally:(fun () ->
      (try Unix.chmod config_dir 0o700 with
       | _ -> ());
      ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      let output, status =
        run_install_status [ "--provider"; "deepseek"; "--api-key"; "fake-key" ] tmpdir
      in
      check bool "runtime update failure exits nonzero" true (status <> Unix.WEXITED 0);
      assert_contains
        "runtime update failure message"
        output
        "could not update runtime.toml default";
      check bool "env.local not written after runtime update failure" false
        (Sys.file_exists env_file))
;;

let test_runtime_default_update_preserves_comments_and_leaves_no_temp () =
  let tmpdir = Filename.temp_file "masc-install-wizard-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote tmpdir)))
    (fun () ->
      let config_dir = Filename.concat tmpdir ".masc/config" in
      let runtime_file = Filename.concat config_dir "runtime.toml" in
      ignore (Sys.command ("mkdir -p " ^ Filename.quote config_dir));
      write_file
        runtime_file
        {|
# top comment
[runtime]
default = "ollama_cloud.deepseek-v4-flash"
# keep this comment

[providers.deepseek]
display-name = "DeepSeek API"
protocol = "openai-compatible-http"
endpoint = "https://api.deepseek.com"

[providers.deepseek.healthcheck]
path = "/models"

[providers.deepseek.credentials]
type = "env"
key = "DEEPSEEK_API_KEY"

[models.deepseek-v4-flash]
api-name = "deepseek-v4-flash"
max-context = 1048576
tools-support = true
thinking-support = true
streaming = true

[deepseek.deepseek-v4-flash]
wizard-default = true
|};
      let _output =
        run_install [ "--provider"; "deepseek"; "--api-key"; "fake-key" ] tmpdir
      in
      let updated = read_file runtime_file in
      assert_contains
        "default updated to concrete deepseek runtime"
        updated
        "default = \"deepseek.deepseek-v4-flash\"";
      assert_contains "pre-existing comment preserved" updated "# keep this comment";
      assert_contains "top comment preserved" updated "# top comment";
      check bool "no runtime.toml.bak file" false (Sys.file_exists (runtime_file ^ ".bak"));
      let stale_atomic_tmps =
        Sys.readdir (Filename.dirname runtime_file)
        |> Array.to_list
        |> List.filter Fs_compat.is_atomic_orphan_name
      in
      check (list string) "no stale atomic tmp files" [] stale_atomic_tmps)
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
            "binary checks use install environment"
            `Quick
            test_binary_checks_use_install_environment
        ; test_case
            "--force refreshes same-version existing binary"
            `Quick
            test_force_refreshes_same_version_existing_binary
        ; test_case
            "release checksums include model catalog seed"
            `Quick
            test_release_checksums_include_model_catalog_seed
        ] )
    ; ( "wizard"
      , [ test_case "wizard flags exist" `Quick test_wizard_flags_exist
        ; test_case "wizard prompts exist" `Quick test_wizard_prompts_exist
        ; test_case "env.local writer exists" `Quick test_env_local_writer_exists
        ; test_case "provider catalog comes from runtime.toml" `Quick test_provider_catalog_comes_from_runtime_toml
        ; test_case
            "provider display names with pipes round-trip"
            `Quick
            test_provider_display_name_with_pipe_round_trips
        ; test_case
            "default provider uses typed binding lookup"
            `Quick
            test_default_provider_uses_binding_lookup
        ; test_case
            "provider ping does not expose key in curl argv"
            `Quick
            test_provider_ping_does_not_expose_key_in_curl_argv
        ; test_case
            "partial files are cleaned by exit trap"
            `Quick
            test_partial_files_are_cleaned_by_exit_trap
        ; test_case "--no-wizard does not write env.local" `Quick test_no_wizard_does_not_write_env_local
        ; test_case "dry-run masks the api key" `Quick test_dry_run_masks_key
        ; test_case "wizard writes env.local with 0o600 permissions" `Quick test_wizard_writes_env_local
        ; test_case
            "forced env.local overwrite does not follow symlinks"
            `Quick
            test_forced_env_local_replaces_symlink_without_touching_target
        ; test_case "api key can be read from stdin" `Quick test_api_key_stdin_writes_env_local
        ; test_case "empty api key stdin is rejected" `Quick test_empty_api_key_stdin_errors
        ; test_case "wizard updates runtime.toml default" `Quick test_wizard_updates_runtime_default
        ; test_case "unknown provider aborts" `Quick test_unknown_provider_aborts
        ; test_case
            "unknown default provider aborts"
            `Quick
            test_unknown_default_provider_aborts
        ; test_case "shell metachars in key are safely quoted" `Quick test_key_with_shell_metachars_is_safely_quoted
        ; test_case "local provider omits env.local" `Quick test_local_provider_omits_env_local
        ; test_case "existing env.local is skipped by default" `Quick test_wizard_skips_existing_env_local
        ; test_case "dry-run + no-seed skips wizard when catalog is absent" `Quick test_wizard_dry_run_no_seed_skips
        ; test_case "forced wizard without catalog errors" `Quick test_wizard_forced_without_catalog_errors
        ; test_case
            "MASC_API_KEY does not cross provider credential keys"
            `Quick
            test_masc_api_key_does_not_cross_provider
        ; test_case
            "MASC_API_KEY works when provider declares it"
            `Quick
            test_masc_api_key_env_var_when_provider_declares_it
        ; test_case
            "provider-specific env key precedes MASC_API_KEY"
            `Quick
            test_provider_key_env_var_precedes_masc_api_key
        ; test_case
            "non-TTY provider without key errors"
            `Quick
            test_provider_without_key_errors_in_non_tty
        ; test_case
            "invalid provider key env name errors"
            `Quick
            test_invalid_provider_key_env_name_errors
        ; test_case "wizard parses the real runtime.toml catalog" `Quick test_wizard_parses_real_runtime_toml
        ; test_case
            "real runtime.toml providers declare healthcheck paths"
            `Quick
            test_real_runtime_toml_provider_healthchecks
        ; test_case "--provider requires a value" `Quick test_missing_provider_flag_value_errors
        ; test_case
            "runtime default failure does not write env.local"
            `Quick
            test_runtime_default_failure_does_not_write_env_local
        ; test_case
            "runtime default update preserves comments and leaves no temp/bak files"
            `Quick
            test_runtime_default_update_preserves_comments_and_leaves_no_temp
        ] )
    ]
;;
