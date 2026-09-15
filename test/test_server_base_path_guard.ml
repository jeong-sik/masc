open Alcotest

(* Workspace_root.resolve is pure: these observations name every input it reads,
   so no case depends on the machine's HOME, cwd or recorded default. *)
let observation ?flag ?environment ?cwd ?(recorded = Workspace_root.No_record)
    ?(workspaces = []) ?(links = []) () =
  { Workspace_root.flag
  ; environment
  ; cwd
  ; recorded
  ; is_workspace = (fun dir -> List.mem dir workspaces)
  ; realpath = (fun path -> List.assoc_opt path links)
  }

let source_label = function
  | Ok root -> Workspace_root.source_label root.Workspace_root.source
  | Error (Workspace_root.No_workspace _) -> "no_workspace"
  | Error (Workspace_root.Unanchored _) -> "unanchored"

let root_of = function
  | Ok root -> root.Workspace_root.root
  | Error (Workspace_root.No_workspace _ | Workspace_root.Unanchored _) -> "(none)"

let resolves label ~source ~root observed =
  let resolved = Workspace_root.resolve observed in
  check string (label ^ ": source") source (source_label resolved);
  check string (label ^ ": root") root (root_of resolved)

let a_record = Workspace_root.Record { record = "/cfg/default-base-path"; path = "/recorded" }

let flag_wins_over_everything () =
  resolves "flag" ~source:"explicit_cli" ~root:"/from-flag"
    (observation ~flag:"/from-flag" ~environment:"/from-env" ~cwd:"/ws"
       ~recorded:a_record ~workspaces:[ "/ws"; "/recorded" ] ())

let environment_wins_over_cwd_and_record () =
  resolves "environment" ~source:"explicit_env" ~root:"/from-env"
    (observation ~environment:"/from-env" ~cwd:"/ws" ~recorded:a_record
       ~workspaces:[ "/ws"; "/recorded" ] ())

(* Measured on 0.35.16: inside a workspace, `masc init`, `masc` and `masc start`
   exited 1 with "MASC_BASE_PATH is not set" right after logging the cwd. *)
let a_workspace_cwd_wins_over_the_record () =
  resolves "cwd" ~source:"current_directory" ~root:"/ws"
    (observation ~cwd:"/ws" ~recorded:a_record ~workspaces:[ "/ws"; "/recorded" ] ())

let a_cwd_without_config_falls_to_the_record () =
  resolves "record" ~source:"persisted_default" ~root:"/recorded"
    (observation ~cwd:"/home/me" ~recorded:a_record ~workspaces:[ "/recorded" ] ())

let blank_named_values_count_as_absent () =
  resolves "blank" ~source:"current_directory" ~root:"/ws"
    (observation ~flag:"  " ~environment:"" ~cwd:"/ws" ~workspaces:[ "/ws" ] ())

let a_stale_record_is_named_in_the_error () =
  match
    Workspace_root.resolve
      (observation ~cwd:"/elsewhere" ~recorded:a_record ~workspaces:[] ())
  with
  | Ok root ->
    failf "a record without .masc/config resolved to %s" root.Workspace_root.root
  | Error (Workspace_root.No_workspace { cwd; stale_record } as error) ->
    check (option string) "cwd" (Some "/elsewhere") cwd;
    check (option (pair string string)) "stale record"
      (Some ("/cfg/default-base-path", "/recorded")) stale_record;
    let message = Workspace_root.error_message error in
    check bool "message names the ignored record" true
      (String_util.contains_substring message "/recorded");
    check bool "message offers --base-path" true
      (String_util.contains_substring message "--base-path")

let a_relative_record_is_stale () =
  let relative = Workspace_root.Record { record = "/cfg/r"; path = "ws" } in
  check string "relative record" "no_workspace"
    (source_label
       (Workspace_root.resolve
          (observation ~recorded:relative ~workspaces:[ "ws" ] ())))

let named_roots_are_absolute_and_canonical () =
  resolves "relative flag" ~source:"explicit_cli" ~root:"/cwd/ws"
    (observation ~flag:"ws" ~cwd:"/cwd" ());
  resolves "flag naming .masc" ~source:"explicit_cli" ~root:"/cwd/ws"
    (observation ~flag:"/cwd/ws/.masc" ~cwd:"/cwd" ());
  resolves "linked flag" ~source:"explicit_cli" ~root:"/private/tmp/ws"
    (observation ~flag:"/tmp/ws" ~links:[ "/tmp/ws", "/private/tmp/ws" ] ())

(* Reported by review of #36447: with an unreadable cwd a relative flag used to
   come back as a relative root, although the interface promises an absolute one. *)
let a_relative_named_value_without_a_cwd_is_unanchored () =
  check string "relative flag" "unanchored"
    (source_label (Workspace_root.resolve (observation ~flag:"ws" ())));
  check string "relative environment" "unanchored"
    (source_label (Workspace_root.resolve (observation ~environment:"ws" ())));
  check string "absolute flag needs no cwd" "explicit_cli"
    (source_label (Workspace_root.resolve (observation ~flag:"/ws" ())))

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

(* observe is the only reader of the process; its workspace test is the one a
   real directory decides. *)
let observe_requires_masc_config () =
  with_temp_dir "masc-workspace-root-" @@ fun dir ->
  let masc = Filename.concat dir ".masc" in
  Unix.mkdir masc 0o755;
  let observed = Workspace_root.observe ~flag:None () in
  check bool ".masc alone is not a workspace" false
    (observed.Workspace_root.is_workspace dir);
  Unix.mkdir (Filename.concat masc "config") 0o755;
  check bool ".masc/config is a workspace" true
    (observed.Workspace_root.is_workspace dir)

let test_canonicalize_existing_freezes_symlink_target () =
  with_temp_dir "masc-canonical-path-" @@ fun dir ->
  let target = Filename.concat dir "target" in
  let alias = Filename.concat dir "alias" in
  Unix.mkdir target 0o755;
  Unix.symlink target alias;
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists alias then Sys.remove alias)
    (fun () ->
       match Server_base_path_guard.canonicalize_existing alias with
       | Ok canonical ->
         check string "canonical target" (Unix.realpath target) canonical
       | Error error ->
         fail
           (Server_base_path_guard.format_canonicalization_error error))

let test_canonicalize_existing_retains_failure () =
  with_temp_dir "masc-canonical-missing-" @@ fun dir ->
  let missing = Filename.concat dir "missing" in
  match Server_base_path_guard.canonicalize_existing missing with
  | Error { base_path; cause = _; backtrace = _ } ->
    check string "failed path" missing base_path
  | Ok canonical ->
    failf "missing BasePath unexpectedly resolved to %s" canonical

let () =
  Alcotest.run "Server_base_path_guard"
    [ ( "workspace root order"
      , [ test_case "flag wins over everything" `Quick flag_wins_over_everything
        ; test_case "environment wins over cwd and record" `Quick
            environment_wins_over_cwd_and_record
        ; test_case "a workspace cwd wins over the record" `Quick
            a_workspace_cwd_wins_over_the_record
        ; test_case "a cwd without .masc/config falls to the record" `Quick
            a_cwd_without_config_falls_to_the_record
        ; test_case "blank named values count as absent" `Quick
            blank_named_values_count_as_absent
        ; test_case "a stale record is named in the error" `Quick
            a_stale_record_is_named_in_the_error
        ; test_case "a relative record is stale" `Quick a_relative_record_is_stale
        ; test_case "named roots are absolute and canonical" `Quick
            named_roots_are_absolute_and_canonical
        ; test_case "a relative named value without a cwd is unanchored" `Quick
            a_relative_named_value_without_a_cwd_is_unanchored
        ; test_case "observe requires .masc/config" `Quick
            observe_requires_masc_config
        ] )
    ; ( "canonicalization"
      , [ test_case "existing symlink target is frozen" `Quick
            test_canonicalize_existing_freezes_symlink_target
        ; test_case "canonicalization failure is retained" `Quick
            test_canonicalize_existing_retains_failure
        ] )
    ]
