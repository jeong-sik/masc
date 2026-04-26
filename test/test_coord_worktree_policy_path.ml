(** Regression test for [Coord_worktree.load_git_clone_policy] path resolution.

    Bug: prior to this fix, the loader read [<base_path>/config/tool_policy.toml]
    only, but the canonical config root is [<base_path>/.masc/config/]. Result
    was empty [allowed_orgs] for keepers whose lookup goes through this loader,
    surfacing as [No allowed orgs configured for git clone] in clone attempts.

    These tests pin the new behaviour: canonical path takes precedence, legacy
    path is honoured as a fallback, and absence of both is a clean empty
    return.
*)

open Alcotest
module CW = Coord_worktree

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let rec rm_rf path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path)
      else Sys.remove path
  in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/"
  then ()
  else if Sys.file_exists dir
  then ()
  else (
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755)
;;

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)
;;

let policy_with_orgs orgs =
  let arr = orgs |> List.map (Printf.sprintf "%S") |> String.concat ", " in
  Printf.sprintf "[git_clone]\nallowed_orgs = [%s]\n" arr
;;

let test_canonical_masc_config () =
  with_temp_dir "coord-worktree-policy-canon"
  @@ fun base ->
  let dir = Filename.concat (Filename.concat base ".masc") "config" in
  mkdir_p dir;
  write_file
    (Filename.concat dir "tool_policy.toml")
    (policy_with_orgs [ "jeong-sik"; "kidsnote" ]);
  let allowed, _denied = CW.load_git_clone_policy ~base_path:base in
  check
    (list string)
    "canonical .masc/config/ resolves orgs"
    [ "jeong-sik"; "kidsnote" ]
    allowed
;;

let test_legacy_config_dir () =
  with_temp_dir "coord-worktree-policy-legacy"
  @@ fun base ->
  let dir = Filename.concat base "config" in
  mkdir_p dir;
  write_file (Filename.concat dir "tool_policy.toml") (policy_with_orgs [ "legacy-org" ]);
  let allowed, _denied = CW.load_git_clone_policy ~base_path:base in
  check
    (list string)
    "legacy <base>/config/ honoured when canonical missing"
    [ "legacy-org" ]
    allowed
;;

let test_canonical_takes_priority () =
  with_temp_dir "coord-worktree-policy-priority"
  @@ fun base ->
  let canon = Filename.concat (Filename.concat base ".masc") "config" in
  mkdir_p canon;
  write_file (Filename.concat canon "tool_policy.toml") (policy_with_orgs [ "canonical" ]);
  let legacy = Filename.concat base "config" in
  mkdir_p legacy;
  write_file (Filename.concat legacy "tool_policy.toml") (policy_with_orgs [ "legacy" ]);
  let allowed, _denied = CW.load_git_clone_policy ~base_path:base in
  check (list string) "canonical wins over legacy when both exist" [ "canonical" ] allowed
;;

let test_neither_present () =
  with_temp_dir "coord-worktree-policy-none"
  @@ fun base ->
  let allowed, denied = CW.load_git_clone_policy ~base_path:base in
  check (list string) "no policy file → empty allowed" [] allowed;
  check (list string) "no policy file → empty denied" [] denied
;;

let () =
  Alcotest.run
    "coord_worktree policy path"
    [ ( "load_git_clone_policy"
      , [ test_case "canonical .masc/config/" `Quick test_canonical_masc_config
        ; test_case "legacy <base>/config/" `Quick test_legacy_config_dir
        ; test_case "canonical takes priority" `Quick test_canonical_takes_priority
        ; test_case "neither path present" `Quick test_neither_present
        ] )
    ]
;;
