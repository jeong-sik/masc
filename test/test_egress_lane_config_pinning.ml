(* Which runtime.toml a policy keeper is judged by.

   The lane re-reads its allowlist per request so an operator's edit reaches
   the next connection. For a while it re-decided *which file* per request
   too, and that is a different thing: an editor saving by temp-and-rename
   unlinks the workspace file for a moment, and a request landing in that
   moment was answered by the global runtime.toml instead -- different rules,
   reported as an ordinary read, and then cached as the last set that
   parsed. *)

open Alcotest

module Lane = Masc.Keeper_egress_lane
module Resolver = Config_dir_resolver

let temp_base () =
  let base = Filename.temp_file "egress_lane_pin_" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  base
;;

let write path content =
  let dir = Filename.dirname path in
  let rec ensure d =
    if not (Sys.file_exists d)
    then (
      ensure (Filename.dirname d);
      Unix.mkdir d 0o700)
  in
  ensure dir;
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let rec remove_tree path =
  if Sys.is_directory path
  then (
    Array.iter (fun entry -> remove_tree (Filename.concat path entry)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path
;;

let allowlist_toml = {|
[egress.keepers.pinned]
allow = ["github.com"]
|}

let test_the_lane_reads_the_file_it_was_given () =
  let base = temp_base () in
  Fun.protect ~finally:(fun () -> remove_tree base) @@ fun () ->
  let workspace = Resolver.runtime_toml_path_for_base_path ~base_path:base in
  write workspace allowlist_toml;
  match Lane.resolve_config_path ~base_path:base ~keeper_name:"pinned" with
  | Error detail -> failf "the workspace file did not resolve: %s" detail
  | Ok config_path ->
    check string "the workspace file governs" workspace config_path;
    (match Lane.read_allowlist ~config_path ~keeper_name:"pinned" with
     | Error detail -> failf "the allowlist did not read: %s" detail
     | Ok rules ->
       check (list string) "and it is the one that was written"
         [ "github.com" ]
         (List.map Egress_host.rule_to_string rules))
;;

(* The save window. The path is already settled, so the read simply fails and
   the caller holds the rules it had. Nothing here reaches another file. *)
let test_a_vanished_file_fails_rather_than_finding_another () =
  let base = temp_base () in
  Fun.protect ~finally:(fun () -> remove_tree base) @@ fun () ->
  let workspace = Resolver.runtime_toml_path_for_base_path ~base_path:base in
  write workspace allowlist_toml;
  let config_path =
    match Lane.resolve_config_path ~base_path:base ~keeper_name:"pinned" with
    | Ok path -> path
    | Error detail -> failf "the workspace file did not resolve: %s" detail
  in
  Sys.remove workspace;
  check bool "the read fails rather than answering from somewhere else"
    true
    (Result.is_error (Lane.read_allowlist ~config_path ~keeper_name:"pinned"));
  (* And this is why the path is settled once: asked again in the same
     window, the answer moves. Either it names a different file -- whichever
     global runtime.toml this machine has -- or it names none at all. What it
     never names is the keeper's own file, because that file is not there,
     which is the whole of the defect. *)
  let answer_moved =
    match Lane.resolve_config_path ~base_path:base ~keeper_name:"pinned" with
    | Error _ -> true
    | Ok resolved_again -> not (String.equal resolved_again workspace)
  in
  check bool "re-resolving in the save window never finds the keeper's file"
    true
    answer_moved
;;

let () =
  run "egress_lane_config_pinning"
    [ ( "pinning"
      , [ test_case "the lane reads the file it was given" `Quick
            test_the_lane_reads_the_file_it_was_given
        ; test_case "a vanished file fails rather than finding another" `Quick
            test_a_vanished_file_fails_rather_than_finding_another
        ] )
    ]
;;
