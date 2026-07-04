(** RFC-0128 §4.6 — [.masc-ide/] must not appear in the workspace
    file tree returned by [/api/v1/workspace/tree].

    Before this PR, [scan_dir] excluded [.masc/] (the keeper
    workspace store) but not [.masc-ide/] (the keeper annotation
    store). With [?repo_id=<id>] resolving the workspace base to a
    registered repository and the IDE seeding its file explorer from
    the response, the agent's own annotation directory was leaking
    into the file picker. This regression test pins
    [.masc-ide/]-exclusion alongside the other internal dirs. *)

open Alcotest

module W = Server_routes_http_routes_workspace

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

let field_of_node key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let bool_field node key =
  match field_of_node key node with Some (`Bool b) -> b | _ -> false

let int_field node key =
  match field_of_node key node with Some (`Int n) -> n | _ -> -1

let string_field node key =
  match field_of_node key node with Some (`String s) -> s | _ -> ""

let find_node nodes p = List.find_opt (fun n -> path_of_node n = p) nodes

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

(* --- Lazy children (RFC-0014 amendment) --- *)

let test_boundary_directory_is_expandable () =
  with_temp_dir (fun base ->
    touch (Filename.concat base "a/b/c.ml");
    (* Scan two levels: root [a] recurses to [a/b], which sits at the boundary
       (depth 1 = max_depth) so its own children are not scanned. With lazy
       children [a/b] must still report hasChildren=true so the client renders a
       chevron and fetches its entries from /api/v1/workspace/children on
       expand. Before the change it was is_dir && depth < max_depth = false. *)
    let nodes = W.scan_dir ~base ~depth:0 ~max_depth:1 ~max_nodes:200 [] base in
    match find_node nodes "a/b" with
    | None -> Alcotest.fail "boundary directory a/b missing from scan"
    | Some node ->
      check bool "boundary directory a/b is expandable" true (bool_field node "hasChildren"))
;;

let test_one_level_children_scan () =
  with_temp_dir (fun base ->
    touch (Filename.concat base "a/b/c.ml");
    touch (Filename.concat base "a/x.ml");
    (* Emulate /api/v1/workspace/children: scan exactly one level of [a] with
       ~depth = ~max_depth = 1 rooted at base/a while ~base stays the whole
       tree. Returns a's immediate entries only (a/b, a/x.ml) — never the
       grandchild a/b/c.ml — and anchors each node's path/parent/depth to the
       whole tree so the client merges them into its flat node array. *)
    let sub = Filename.concat base "a" in
    let nodes = W.scan_dir ~base ~depth:1 ~max_depth:1 ~max_nodes:200 [] sub in
    let ps = List.sort String.compare (paths nodes) in
    check (list string) "returns exactly a's immediate children" [ "a/b"; "a/x.ml" ] ps;
    match find_node nodes "a/b" with
    | None -> Alcotest.fail "a/b missing from children scan"
    | Some node ->
      check string "child parent anchored to whole tree" "a" (string_field node "parent");
      check int "child depth anchored to whole tree" 1 (int_field node "depth"))
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
    ; ( "RFC-0014 lazy children"
      , [ test_case
            "boundary directory reports hasChildren"
            `Quick
            test_boundary_directory_is_expandable
        ; test_case
            "children scan returns exactly one level"
            `Quick
            test_one_level_children_scan
        ] )
    ]
;;
