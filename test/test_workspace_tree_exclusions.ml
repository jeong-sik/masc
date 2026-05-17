(** RFC-0128 §4.6 — [.masc-ide/] must not appear in the workspace
    file tree returned by [/api/v1/workspace/tree].

    Before this PR, [scan_dir] excluded [.masc/] (the keeper
    coordination store) but not [.masc-ide/] (the keeper annotation
    store). With [?repo_id=<id>] resolving the workspace base to a
    registered repository and the IDE seeding its file explorer from
    the response, the agent's own annotation directory was leaking
    into the file picker. This regression test pins
    [.masc-ide/]-exclusion alongside the other internal dirs. *)

open Alcotest

module W = Masc_mcp.Server_routes_http_routes_workspace

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_dir f =
  let path = Filename.temp_file "rfc-0128-tree" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)
;;

let mkdir_p path =
  let rec loop p =
    if p = "" || p = "/" || (Sys.file_exists p && Sys.is_directory p)
    then ()
    else (
      loop (Filename.dirname p);
      try Unix.mkdir p 0o755 with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  loop path
;;

let touch path =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  close_out oc
;;

let path_of_node = function
  | `Assoc fields ->
    (match List.assoc_opt "path" fields with
     | Some (`String s) -> s
     | _ -> failwith "node missing path")
  | _ -> failwith "node not an Assoc"
;;

let paths nodes = List.map path_of_node nodes

let test_masc_ide_excluded () =
  with_temp_dir (fun base ->
    mkdir_p (Filename.concat base ".masc-ide/by-url/some_slug");
    touch (Filename.concat base ".masc-ide/by-url/some_slug/annotations.jsonl");
    touch (Filename.concat base "lib/bar.ml");
    let nodes = W.scan_dir ~base ~depth:0 ~max_depth:3 ~max_nodes:200 [] base in
    let ps = paths nodes in
    let has_masc_ide = List.exists (fun p -> p = ".masc-ide" || String.length p > 10 && String.sub p 0 10 = ".masc-ide/") ps in
    let has_lib = List.exists (fun p -> p = "lib" || p = "lib/bar.ml") ps in
    check bool ".masc-ide must not appear in tree" false has_masc_ide;
    check bool "lib must appear in tree" true has_lib)
;;

let test_other_internal_dirs_still_excluded () =
  (* Defence-in-depth: verify the existing excluded entries did not
     regress when [.masc-ide] was added to the list. *)
  with_temp_dir (fun base ->
    List.iter
      (fun d -> mkdir_p (Filename.concat base d))
      [ ".git"; ".masc"; "node_modules"; "_build"; ".worktrees" ];
    touch (Filename.concat base "lib/bar.ml");
    let nodes = W.scan_dir ~base ~depth:0 ~max_depth:2 ~max_nodes:200 [] base in
    let ps = paths nodes in
    List.iter
      (fun forbidden ->
        check bool (forbidden ^ " must not appear") false (List.mem forbidden ps))
      [ ".git"; ".masc"; "node_modules"; "_build"; ".worktrees" ];
    check bool "lib must appear in tree" true (List.exists (fun p -> p = "lib") ps))
;;

let () =
  run
    "workspace_tree_exclusions"
    [ ( "RFC-0128 §4.6"
      , [ test_case ".masc-ide is excluded from tree" `Quick test_masc_ide_excluded
        ; test_case
            "other internal dirs still excluded"
            `Quick
            test_other_internal_dirs_still_excluded
        ] )
    ]
;;
