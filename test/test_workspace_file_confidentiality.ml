(** task-1734 / task-1735 — confidentiality guards for the workspace
    file read routes ([/api/v1/workspace/file], [/git/blame], [/git/diff]).

    Two axes, both routed through [resolve_workspace_path]:

    - B1 (secret denylist): a request whose path contains a confidential
      component ([.env], [.masc]*, [credentials]*, [.git], [.ssh]) is
      rejected instead of being served verbatim. The denylist is a single
      SSOT shared with the file tree, so anything blocked from a read is
      also hidden from the tree.
    - B2 (symlink escape): a committed symlink that resolves outside the
      workspace base is rejected. The pre-existing [safe_path] check only
      compared the lexical prefix, so [repo/evil -> /outside/secret]
      satisfied it and the file was read through the link. *)

open Alcotest

module W = Server_routes_http_routes_workspace

let rec rm_rf path =
  (* [lstat], not [stat]: never follow a symlink into the directory it
     targets — the escape tests create links pointing outside [base]. *)
  match Unix.lstat path with
  | exception _ -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
    (try Unix.rmdir path with _ -> ())
  | _ -> (try Sys.remove path with _ -> ())
;;

let with_temp_dir f =
  let path = Filename.temp_file "ide-file-conf" "" in
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

(* Alcotest testable for the resolution variant so failures print the
   actual constructor instead of an opaque bool. *)
let resolution_tag = function
  | W.Path_ok _ -> "ok"
  | W.Path_rejected W.Path_traversal -> "rejected:traversal"
  | W.Path_rejected (W.Confidential_component c) -> "rejected:confidential:" ^ c
  | W.Path_rejected W.Symlink_escape -> "rejected:symlink_escape"
;;

let is_ok = function W.Path_ok _ -> true | _ -> false
let is_confidential = function
  | W.Path_rejected (W.Confidential_component _) -> true
  | _ -> false
;;
let is_symlink_escape = function
  | W.Path_rejected W.Symlink_escape -> true
  | _ -> false
;;
let is_traversal = function
  | W.Path_rejected W.Path_traversal -> true
  | _ -> false
;;

(* --- B1: secret denylist rejects confidential reads --- *)

let confidential_examples =
  (* (requested path, human label). Each must be rejected even when the
     file exists on disk. *)
  [ ".env", "root .env";
    ".env.local", "prefixed .env.local";
    "src/.env.production", "nested .env.production";
    ".masc/config/credentials.toml", "the concrete leak from the report";
    ".masc-ide/by-url/x/annotations.jsonl", "keeper annotation store";
    "credentials.toml", "root credentials file";
    "config/credentials", "nested credentials";
    ".git/config", "git config with credential URLs";
    ".ssh/id_rsa", "private key" ]
;;

let test_confidential_reads_rejected () =
  with_temp_dir (fun base ->
    (* Materialise each secret on disk so the guard — not a missing file —
       is what rejects the request. *)
    List.iter (fun (p, _) -> touch (Filename.concat base p)) confidential_examples;
    List.iter
      (fun (p, label) ->
        let got = W.resolve_workspace_path base p in
        check bool ("confidential rejected: " ^ label) true (is_confidential got);
        (* The rejection must not be a silent fallthrough to Path_ok. *)
        check bool ("not Path_ok: " ^ label) false (is_ok got))
      confidential_examples)
;;

let test_confidential_case_insensitive () =
  (* A case-insensitive filesystem would serve [.ENV] as [.env]; the
     denylist must reject regardless of case rather than be bypassable. *)
  with_temp_dir (fun base ->
    List.iter
      (fun p ->
        check bool ("case-insensitive rejected: " ^ p) true
          (is_confidential (W.resolve_workspace_path base p)))
      [ ".ENV"; ".Env.Local"; "Credentials.TOML"; ".SSH/id_rsa" ])
;;

let test_normal_source_file_allowed () =
  with_temp_dir (fun base ->
    List.iter (fun rel -> touch (Filename.concat base rel))
      [ "lib/main.ml"; "README.md"; "src/deep/nested/thing.ts" ];
    List.iter
      (fun rel ->
        let got = W.resolve_workspace_path base rel in
        check
          string
          ("normal file allowed: " ^ rel)
          "ok" (resolution_tag got))
      [ "lib/main.ml"; "README.md"; "src/deep/nested/thing.ts" ])
;;

let test_parent_traversal_rejected () =
  with_temp_dir (fun base ->
    List.iter
      (fun p ->
        check bool ("traversal rejected: " ^ p) true
          (is_traversal (W.resolve_workspace_path base p)))
      [ "../etc/passwd"; "a/../../b"; ".."; "lib/./../.." ])
;;

(* --- B2: symlink escape guard --- *)

let test_symlink_escape_rejected () =
  with_temp_dir (fun base ->
    (* Secret target lives OUTSIDE base (sibling temp file), reachable
       only by following the committed symlink. *)
    let outside = Filename.temp_file "ide-file-conf-secret" ".txt" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove outside with _ -> ())
      (fun () ->
        let oc = open_out outside in
        output_string oc "TOP SECRET";
        close_out oc;
        let link = Filename.concat base "evil" in
        Unix.symlink outside link;
        let got = W.resolve_workspace_path base "evil" in
        check
          string
          "escaping symlink rejected"
          "rejected:symlink_escape" (resolution_tag got);
        check bool "escaping symlink not Path_ok" false (is_ok got)))
;;

let test_symlink_escape_via_dir_rejected () =
  with_temp_dir (fun base ->
    (* A symlinked *directory* component must also be caught: base/link ->
       /outside, then base/link/secret escapes even though the leaf
       "secret" is innocuous. *)
    let outside_dir = Filename.temp_file "ide-file-conf-dir" "" in
    Sys.remove outside_dir;
    Unix.mkdir outside_dir 0o700;
    Fun.protect
      ~finally:(fun () -> rm_rf outside_dir)
      (fun () ->
        touch (Filename.concat outside_dir "secret");
        Unix.symlink outside_dir (Filename.concat base "link");
        let got = W.resolve_workspace_path base "link/secret" in
        check bool "escape through symlinked dir rejected" true
          (is_symlink_escape got)))
;;

let test_symlink_to_confidential_target_rejected () =
  with_temp_dir (fun base ->
    touch (Filename.concat base ".env");
    Unix.symlink (Filename.concat base ".env") (Filename.concat base "public_link");
    let got = W.resolve_workspace_path base "public_link" in
    check
      string
      "in-base symlink to confidential target rejected"
      "rejected:confidential:.env" (resolution_tag got))
;;

let test_internal_symlink_allowed () =
  with_temp_dir (fun base ->
    (* A symlink pointing back inside the workspace stays allowed: it is a
       legitimate editor scenario and does not escape the base. *)
    touch (Filename.concat base "real.ml");
    Unix.symlink (Filename.concat base "real.ml") (Filename.concat base "link.ml");
    let got = W.resolve_workspace_path base "link.ml" in
    check
      string
      "internal symlink allowed"
      "ok" (resolution_tag got))
;;

(* --- (e) denylist SSOT is consistent with the tree listing --- *)

let test_denylist_matches_tree_hidden () =
  with_temp_dir (fun base ->
    (* Populate the tree with confidential entries + a legit file. Every
       confidential component the read guard blocks must also be absent
       from the tree, proving both consume the same SSOT. *)
    mkdir_p (Filename.concat base ".masc/config");
    touch (Filename.concat base ".masc/config/credentials.toml");
    mkdir_p (Filename.concat base ".masc-ide/by-url");
    touch (Filename.concat base ".masc-ide/by-url/annotations.jsonl");
    mkdir_p (Filename.concat base ".git");
    touch (Filename.concat base ".git/config");
    touch (Filename.concat base ".env");
    touch (Filename.concat base "credentials.toml");
    mkdir_p (Filename.concat base ".ssh");
    touch (Filename.concat base ".ssh/id_rsa");
    touch (Filename.concat base "lib/main.ml");
    let ps = paths (W.scan_dir ~base ~depth:0 ~max_depth:3 ~max_nodes:500 [] base) in
    let top_components =
      [ ".masc"; ".masc-ide"; ".git"; ".env"; "credentials.toml"; ".ssh" ]
    in
    List.iter
      (fun name ->
        (* SSOT predicate agrees the component is confidential ... *)
        check bool (name ^ " is confidential") true (W.component_is_confidential name);
        (* ... and the tree hides it. *)
        check bool (name ^ " hidden from tree") false (List.mem name ps))
      top_components;
    check bool "legit lib file present in tree" true
      (List.exists (fun p -> p = "lib" || p = "lib/main.ml") ps))
;;

let test_tree_does_not_follow_symlinked_dir_escape () =
  with_temp_dir (fun base ->
    let outside_dir = Filename.temp_file "ide-file-conf-tree-dir" "" in
    Sys.remove outside_dir;
    Unix.mkdir outside_dir 0o700;
    Fun.protect
      ~finally:(fun () -> rm_rf outside_dir)
      (fun () ->
        touch (Filename.concat outside_dir "outside_secret_name");
        Unix.symlink outside_dir (Filename.concat base "link");
        let ps =
          paths (W.scan_dir ~base ~depth:0 ~max_depth:3 ~max_nodes:500 [] base)
        in
        check bool "symlink entry itself can be listed" true (List.mem "link" ps);
        check bool "tree does not recurse into escaped symlink dir" false
          (List.mem "link/outside_secret_name" ps)))
;;

let test_noise_dirs_not_confidential () =
  (* Noise dirs are hidden from the tree but are NOT secrets: a read under
     them is allowed, so [component_is_confidential] must stay false for
     them (guards the SSOT split against accidental over-blocking). *)
  List.iter
    (fun name ->
      check bool (name ^ " not confidential") false (W.component_is_confidential name))
    [ "node_modules"; "_build"; "dist"; "build"; ".worktrees"; ".cache" ]
;;

let () =
  run
    "workspace_file_confidentiality"
    [ ( "B1 secret denylist"
      , [ test_case "confidential reads rejected" `Quick test_confidential_reads_rejected
        ; test_case
            "confidential match is case-insensitive"
            `Quick
            test_confidential_case_insensitive
        ; test_case "normal source file allowed" `Quick test_normal_source_file_allowed
        ; test_case "parent traversal rejected" `Quick test_parent_traversal_rejected
        ] )
    ; ( "B2 symlink escape guard"
      , [ test_case "escaping symlink rejected" `Quick test_symlink_escape_rejected
        ; test_case
            "escape through symlinked dir rejected"
            `Quick
            test_symlink_escape_via_dir_rejected
        ; test_case
            "in-base symlink to confidential target rejected"
            `Quick
            test_symlink_to_confidential_target_rejected
        ; test_case "internal symlink allowed" `Quick test_internal_symlink_allowed
        ] )
    ; ( "SSOT consistency"
      , [ test_case "denylist matches tree hidden" `Quick test_denylist_matches_tree_hidden
        ; test_case
            "tree does not follow escaped symlink dirs"
            `Quick
            test_tree_does_not_follow_symlinked_dir_escape
        ; test_case "noise dirs are not confidential" `Quick test_noise_dirs_not_confidential
        ] )
    ]
;;
