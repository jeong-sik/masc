(** test_keeper_create_no_boot — create-without-boot acceptance (WO-A5-3a/3b/3c).

    [Keeper_tool_persona_runtime.create_configured_only] writes the durable
    TOML (pinned autoboot_enabled=false, pinned sandbox_profile) and the
    list-visible meta with no boot side effect: the keeper must appear in
    [keeper_names], must NOT be registered, and reconcile must classify it
    [Declarative_autoboot_disabled]. Duplicate names and an explicit
    autoboot_enabled=true are explicit errors, and a post-persist failure
    removes the freshly written TOML instead of leaving an orphan. *)

module Workspace = Masc.Workspace
module Store = Masc.Keeper_meta_store
module Profile = Masc.Keeper_types_profile
module Persona_runtime = Masc.Keeper_tool_persona_runtime
module Keeper_runtime = Masc.Keeper_runtime
module Keeper_registry = Masc.Keeper_registry

let temp_dir () =
  let path = Filename.temp_file "keeper-create-no-boot-" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    Unix.mkdir path 0o755)

let rec rm_rf path =
  try
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Sys.readdir path
        |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path)
      else Sys.remove path
  with _ -> ()

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""

let contains ~affix s =
  let n = String.length affix and m = String.length s in
  let rec go i = i + n <= m && (String.sub s i n = affix || go (i + 1)) in
  n = 0 || go 0

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let with_config_dir f =
  let base = temp_dir () in
  let config_dir = Filename.concat base ".masc/config" in
  mkdir_p (Filename.concat config_dir "keepers");
  let previous = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_CONFIG_DIR" previous;
      Config_dir_resolver.reset ();
      rm_rf base)
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Config_dir_resolver.reset ();
      f ~base)

let with_ctx f =
  with_config_dir @@ fun ~base ->
  let config = Workspace.default_config base in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let ctx : _ Profile.context =
    {
      config;
      agent_name = "test-agent";
      sw;
      clock = Eio.Stdenv.clock env;
      proc_mgr = None;
      net = None;
    }
  in
  f ~base ~config ~ctx

let resolved_args ?(extra = []) name =
  `Assoc
    ([
       ("name", `String name);
       ("persona_name", `String "probe");
       ("goal", `String "configured only probe");
       ("instructions", `String "");
       ("mention_targets", `List [ `String name ]);
     ]
    @ extra)

let test_configured_only_create () =
  with_ctx @@ fun ~base ~config ~ctx ->
  let name = "noboot-probe" in
  match Persona_runtime.create_configured_only ctx (resolved_args name) with
  | Error e -> Alcotest.failf "create_configured_only failed: %s" e
  | Ok payload ->
      (match payload with
       | `Assoc fields ->
           Alcotest.(check (option bool))
             "payload booted=false" (Some false)
             (match List.assoc_opt "booted" fields with
              | Some (`Bool b) -> Some b
              | _ -> None);
           (match List.assoc_opt "path" fields with
            | Some (`String path) ->
                Alcotest.(check bool) "TOML written" true (Sys.file_exists path);
                let toml = read_file path in
                Alcotest.(check bool)
                  "TOML pins autoboot_enabled=false" true
                  (contains ~affix:"autoboot_enabled = false" toml);
                Alcotest.(check bool)
                  "TOML pins sandbox_profile" true
                  (contains ~affix:{|sandbox_profile = "docker"|} toml)
            | _ -> Alcotest.fail "payload missing path")
       | _ -> Alcotest.fail "payload must be an object");
      Alcotest.(check bool)
        "meta visible in keeper_names" true
        (List.mem name (Store.keeper_names config));
      Alcotest.(check bool)
        "not registered" false
        (Keeper_registry.is_registered ~base_path:base name);
      (* [autoboot_enabled] is a TOML-owned field: [meta_to_json] scrubs it
         from the persisted JSON and the read-back default is true, so the
         raw meta field is NOT the contract — the TOML pin is. Assert the
         effective (TOML-aware) value instead. *)
      (match Store.read_meta config name with
       | Ok (Some meta) ->
           Alcotest.(check bool)
             "effective autoboot disabled" false
             (Store.effective_autoboot_enabled config name meta)
       | Ok None -> Alcotest.fail "meta missing after configured-only create"
       | Error e -> Alcotest.failf "read_meta failed: %s" e);
      Alcotest.(check (option string))
        "reconcile classifies Declarative_autoboot_disabled"
        (Some "declarative_autoboot_disabled")
        (Keeper_runtime.autoboot_exclusion_reason config name
        |> Option.map Keeper_runtime.autoboot_exclusion_reason_to_string)

let test_duplicate_rejected () =
  with_ctx @@ fun ~base:_ ~config:_ ~ctx ->
  let name = "noboot-dup" in
  (match Persona_runtime.create_configured_only ctx (resolved_args name) with
   | Error e -> Alcotest.failf "first create failed: %s" e
   | Ok _ -> ());
  match Persona_runtime.create_configured_only ctx (resolved_args name) with
  | Ok _ -> Alcotest.fail "duplicate create must be an explicit error"
  | Error e ->
      Alcotest.(check bool)
        "error names the existing config" true
        (contains ~affix:"already exists" e)

let test_autoboot_conflict_rejected () =
  with_ctx @@ fun ~base ~config:_ ~ctx ->
  let name = "noboot-conflict" in
  match
    Persona_runtime.create_configured_only ctx
      (resolved_args ~extra:[ ("autoboot_enabled", `Bool true) ] name)
  with
  | Ok _ -> Alcotest.fail "autoboot_enabled=true must conflict with no_boot"
  | Error e ->
      Alcotest.(check bool)
        "error explains the conflict" true
        (contains ~affix:"autoboot_enabled=true" e);
      let path =
        Filename.concat
          (Config_dir_resolver.keepers_dir_for_base_path ~base_path:base)
          (name ^ ".toml")
      in
      Alcotest.(check bool) "no TOML written" false (Sys.file_exists path)

let test_orphan_toml_removed_on_parse_failure () =
  with_ctx @@ fun ~base ~config:_ ~ctx ->
  let name = "noboot-orphan" in
  (* [tool_access] passes the persist layer (it renders only known fields)
     but is a removed input key for the keeper_up parser, so the failure
     fires after the TOML write — exactly the orphan-compensation path. *)
  match
    Persona_runtime.create_configured_only ctx
      (resolved_args ~extra:[ ("tool_access", `String "full") ] name)
  with
  | Ok _ -> Alcotest.fail "removed input key must fail the parse"
  | Error _ ->
      let path =
        Filename.concat
          (Config_dir_resolver.keepers_dir_for_base_path ~base_path:base)
          (name ^ ".toml")
      in
      Alcotest.(check bool)
        "freshly written TOML removed on failure" false
        (Sys.file_exists path)

let () =
  Alcotest.run "keeper_create_no_boot"
    [
      ( "configured_only",
        [
          Alcotest.test_case
            "create writes TOML+meta, no registry, autoboot excluded" `Quick
            test_configured_only_create;
          Alcotest.test_case "duplicate name is an explicit error" `Quick
            test_duplicate_rejected;
          Alcotest.test_case "autoboot_enabled=true conflicts" `Quick
            test_autoboot_conflict_rejected;
          Alcotest.test_case "orphan TOML removed on post-persist failure"
            `Quick test_orphan_toml_removed_on_parse_failure;
        ] );
    ]
