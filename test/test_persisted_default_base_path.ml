(* The installer prepares a workspace and, until #35022's sibling problem was
   fixed, wrote that path nowhere a later command could read. A bare `masc` or
   `masc start` then died with "MASC_BASE_PATH is not set" on a machine where
   setup had just succeeded (measured on a fresh mac, 2026-09-10).

   These cases pin the three answers the resolver can give and the order they
   are given in. *)
open Alcotest
module EC = Env_config_core

let with_config_home run =
  let dir = Filename.temp_file "masc-default-base-path" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let previous = Sys.getenv_opt "XDG_CONFIG_HOME" in
  Unix.putenv "XDG_CONFIG_HOME" dir;
  Unix.putenv "MASC_BASE_PATH" "";
  Unix.putenv "MASC_BASE_PATH_INPUT" "";
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "XDG_CONFIG_HOME" (Option.value ~default:"" previous))
    (fun () -> run dir)

let workspace_with_masc_dir () =
  let dir = Filename.temp_file "masc-workspace" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Unix.mkdir (Filename.concat dir Common.masc_dirname) 0o700;
  dir

let recorded_path outcome =
  match outcome with
  | EC.Recorded path -> path
  | EC.No_record_location -> fail "a config home was set, so a location exists"
  | EC.Refused_under_test ->
    fail "this config home is a temp dir, not the operator's, so it is writable"
  | EC.Record_failed { record; reason } -> failf "recording %s failed: %s" record reason

(* The reason this suite points XDG_CONFIG_HOME at a temp dir. A test binary
   that lets the write land under the real HOME leaves its sandbox path as the
   machine's default, and the next process resolves its base path there --
   measured on 2026-09-10, where it turned two Server_runtime_bootstrap cases
   red in the release build only. *)
let test_a_test_binary_does_not_write_the_operators_default () =
  let previous = Sys.getenv_opt "XDG_CONFIG_HOME" in
  Unix.putenv "XDG_CONFIG_HOME" "";
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "XDG_CONFIG_HOME" (Option.value ~default:"" previous))
    (fun () ->
      match Sys.getenv_opt "HOME" with
      | None | Some "" -> skip ()
      | Some _ ->
        (match EC.record_default_base_path (workspace_with_masc_dir ()) with
         | EC.Refused_under_test -> ()
         | EC.Recorded path ->
           failf "a test binary wrote %s as the operator's default" path
         | EC.No_record_location -> fail "HOME is set, so a location exists"
         | EC.Record_failed { record; reason } ->
           failf "refused for the wrong reason: %s (%s)" record reason))

let test_record_then_read () =
  with_config_home (fun config_home ->
    let workspace = workspace_with_masc_dir () in
    let written = recorded_path (EC.record_default_base_path workspace) in
    check
      bool
      "the record lives under the config home, not inside the workspace"
      true
      (String.length written > 0
       && Sys.file_exists (Filename.concat (Filename.concat config_home "masc") "default-base-path"));
    match EC.persisted_default_base_path () with
    | EC.Usable { base_path; _ } ->
      check string "reads back the workspace" written base_path
    | EC.No_record -> fail "the record was just written"
    | EC.Stale _ -> fail "the workspace holds a .masc directory"
    | EC.Unread_under_test { record } ->
      failf "%s is a temp config home, not the operator's" record)

let test_a_record_without_a_masc_dir_is_stale_not_absent () =
  with_config_home (fun _ ->
    let gone = Filename.temp_file "masc-gone" "" in
    Sys.remove gone;
    Unix.mkdir gone 0o700;
    let written = recorded_path (EC.record_default_base_path gone) in
    match EC.persisted_default_base_path () with
    | EC.Stale { record; recorded_path } ->
      check bool "names the record file" true (Filename.basename record = "default-base-path");
      check string "names the path it read" written recorded_path;
      check
        (option string)
        "and it is not offered as a base path"
        None
        (Option.map snd (EC.base_path_source_opt ()))
    | EC.Usable { base_path; _ } ->
      failf "%s has no %s directory" base_path Common.masc_dirname
    | EC.No_record -> fail "a record exists; it just does not name a workspace"
    | EC.Unread_under_test { record } ->
      failf "%s is a temp config home, not the operator's" record)

let test_explicit_input_wins_over_the_record () =
  with_config_home (fun _ ->
    let recorded = workspace_with_masc_dir () in
    let explicit = workspace_with_masc_dir () in
    let _ = recorded_path (EC.record_default_base_path recorded) in
    check
      (option string)
      "with no env, the record answers"
      (Some (Unix.realpath recorded))
      (Option.map snd (EC.base_path_source_opt ()));
    Unix.putenv "MASC_BASE_PATH" explicit;
    (match EC.base_path_source_opt () with
     | Some (EC.From_env key, value) ->
       check string "env is the source" EC.base_path_env_key key;
       check string "and env wins" explicit value
     | Some (EC.From_persisted_default record, _) ->
       failf "the record %s should not win over an explicit env value" record
     | None -> fail "an explicit env value was set");
    Unix.putenv "MASC_BASE_PATH" "")

let test_relative_record_cannot_select_the_callers_workspace () =
  with_config_home (fun config_home ->
    let workspace = workspace_with_masc_dir () in
    let _ = recorded_path (EC.record_default_base_path workspace) in
    let record = Filename.concat (Filename.concat config_home "masc") "default-base-path" in
    Out_channel.with_open_text record (fun channel -> output_string channel ".\n");
    let original_cwd = Sys.getcwd () in
    Fun.protect ~finally:(fun () -> Sys.chdir original_cwd) (fun () ->
      Sys.chdir workspace;
      (match EC.persisted_default_base_path () with
       | EC.Stale _ -> ()
       | EC.No_record | EC.Usable _ | EC.Unread_under_test _ ->
         fail "a relative record cannot identify the workspace chosen by another process");
      check (option string) "relative record does not select the caller's workspace"
        None (Option.map snd (EC.base_path_source_opt ()))))

(* Removing the record is the uninstall path's job and it is a file delete, so
   this checks the reader against that observable state rather than exporting a
   helper only a test would call. *)
let test_a_deleted_record_reads_as_absent () =
  with_config_home (fun config_home ->
    let workspace = workspace_with_masc_dir () in
    let _ = recorded_path (EC.record_default_base_path workspace) in
    Sys.remove
      (Filename.concat (Filename.concat config_home "masc") "default-base-path");
    match EC.persisted_default_base_path () with
    | EC.No_record -> ()
    | EC.Usable { base_path; _ } -> failf "the record still names %s" base_path
    | EC.Stale { record; _ } -> failf "the record %s still exists" record
    | EC.Unread_under_test { record } ->
      failf "%s is a temp config home, not the operator's" record)

(* The read side of the same rule, and the one that cost a release: the
   evidence run boots the installed binary with --base-path <temp>, which
   records that temp path as the machine default, and the suites that run next
   resolved their config root there. Two Server_runtime_bootstrap cases went
   red in the release build on 2026-09-10 while every local run stayed green,
   because a local run of the sub-script never boots that server.

   Answered from the location alone, so no record has to exist under HOME for
   this to be a real check -- and none is created here. *)
let test_a_test_binary_does_not_read_the_operators_default () =
  let previous = Sys.getenv_opt "XDG_CONFIG_HOME" in
  Unix.putenv "XDG_CONFIG_HOME" "";
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "XDG_CONFIG_HOME" (Option.value ~default:"" previous))
    (fun () ->
      match Sys.getenv_opt "HOME" with
      | None | Some "" -> skip ()
      | Some home ->
        (match EC.persisted_default_base_path () with
         | EC.Unread_under_test { record } ->
           check
             bool
             "and it names the operator's location it declined to read"
             true
             (String.starts_with ~prefix:(home ^ Filename.dir_sep) record);
           check
             (option string)
             "so nothing resolves a base path from it"
             None
             (Option.map snd (EC.base_path_source_opt ()));
           check
             bool
             "and the not-set message says why"
             true
             (String_util.contains_substring
                (EC.base_path_not_set_message ())
                "does not read the recorded default")
         | EC.Usable { base_path; record } ->
           failf "a test binary read %s as the default from %s" base_path record
         | EC.Stale { record; _ } ->
           failf "a test binary read the operator's record %s" record
         | EC.No_record ->
           fail
             "HOME is set, so the operator's record location exists and the \
              answer is that it was not read"))

let () =
  run
    "persisted default base path"
    [ ( "resolution"
      , [ test_case "records under the config home and reads back" `Quick test_record_then_read
        ; test_case
            "a record without a .masc dir is stale, not absent"
            `Quick
            test_a_record_without_a_masc_dir_is_stale_not_absent
        ; test_case
            "explicit input wins over the record"
            `Quick
            test_explicit_input_wins_over_the_record
        ; test_case
            "a relative record cannot select the caller's workspace"
            `Quick
            test_relative_record_cannot_select_the_callers_workspace
        ; test_case
            "a deleted record reads as absent"
            `Quick
            test_a_deleted_record_reads_as_absent
        ; test_case
            "a test binary does not write the operator's default"
            `Quick
            test_a_test_binary_does_not_write_the_operators_default
        ; test_case
            "a test binary does not read the operator's default"
            `Quick
            test_a_test_binary_does_not_read_the_operators_default
        ] )
    ]
