(** What [Exec_policy_paths] answers for a path that came from a request.

    The lane-addon package preview takes one filesystem path from its query
    string, and that is the only place this API does. It reads the path
    against the workspace and refuses anything that lands outside, which is
    these two functions in sequence: resolve, then ask whether the result is
    still inside. Each case below is a shape the route used to accept. *)

let check = Alcotest.check Alcotest.bool

(* [Unix.lstat], not [Sys.is_directory]: the walk has to see a symlink as a
   symlink. Following it would ask about the target, and a link whose target
   this test already removed answers with an error rather than a kind --
   which left the link in place and the directory un-removable. *)
let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun e -> remove_tree (Filename.concat path e)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_workspace f =
  let base = Filename.temp_file "masc-containment-" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree base)
    (fun () -> f base)
;;

let write path contents =
  let out = open_out path in
  output_string out contents;
  close_out out
;;

let inside ~base path =
  Exec_policy_paths.is_within_dir
    ~dir:(Exec_policy_paths.resolve_path base)
    (Exec_policy_paths.resolve_path ~base_dir:base path)
;;

let test_relative_name_inside_the_workspace () =
  with_workspace (fun base ->
    write (Filename.concat base "addon.toml") "";
    check "a name under the workspace is admitted" true
      (inside ~base "addon.toml"))
;;

let test_dot_dot_walks_out () =
  with_workspace (fun base ->
    check "a relative name that climbs out is refused" false
      (inside ~base "../escaped.toml");
    check "and so is one that climbs and comes back down elsewhere" false
      (inside ~base "../../etc/hosts"))
;;

let test_absolute_name_outside_is_not_read_as_given () =
  with_workspace (fun base ->
    check "an absolute path outside the workspace is refused" false
      (inside ~base "/etc/hosts"))
;;

let test_symlink_inside_pointing_out () =
  with_workspace (fun base ->
    let outside = Filename.temp_file "masc-outside-" ".toml" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove outside with Sys_error _ -> ())
      (fun () ->
        let link = Filename.concat base "link.toml" in
        Unix.symlink outside link;
        (* Text alone would call this one inside: the name starts with the
           workspace. Resolving first is what refuses it. *)
        check "a link inside the workspace that points out is refused" false
          (inside ~base "link.toml")))
;;

let test_a_missing_name_inside_is_still_inside () =
  with_workspace (fun base ->
    (* The route reports a missing manifest as a load failure, not as a
       containment refusal: a caller may not learn which of the two it hit
       for a path outside, but inside the workspace the ordinary error is
       the useful one. *)
    check "a name that does not exist yet stays inside" true
      (inside ~base "not-written-yet.toml"))
;;

let () =
  Alcotest.run "exec policy containment"
    [ ( "request paths"
      , [ Alcotest.test_case "a relative name inside the workspace" `Quick
            test_relative_name_inside_the_workspace
        ; Alcotest.test_case "dot-dot walks out" `Quick test_dot_dot_walks_out
        ; Alcotest.test_case "an absolute name outside" `Quick
            test_absolute_name_outside_is_not_read_as_given
        ; Alcotest.test_case "a symlink inside pointing out" `Quick
            test_symlink_inside_pointing_out
        ; Alcotest.test_case "a missing name inside" `Quick
            test_a_missing_name_inside_is_still_inside
        ] )
    ]
;;
