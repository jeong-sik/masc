open Alcotest
open Masc

let remote_workspace_root = "/srv/masc/playground/keeper-a"
let base_path = "/workspace"
let host_file = "/workspace/.masc/playground/keeper-a/src/main.ml"
let remote_file = "/srv/masc/playground/keeper-a/src/main.ml"

(* The SSH lane unless a test names the guest. A refusal is compared by the
   text the Keeper reads. *)
let host_to_remote ?(lane = Keeper_remote_path.Ssh_endpoint) ~base_path
      ~remote_workspace_root ~keeper path =
  Keeper_remote_path.host_to_remote ~lane ~base_path ~remote_workspace_root ~keeper path
  |> Result.map_error Keeper_remote_path.jail_refusal_to_string
;;

let test_host_to_remote () =
  check (result string string) "absolute host path" (Ok remote_file)
    (host_to_remote ~base_path ~remote_workspace_root ~keeper:"keeper-a"
       host_file);
  check (result string string) "relative logical path" (Ok remote_file)
    (host_to_remote ~base_path ~remote_workspace_root ~keeper:"keeper-a"
       "src/main.ml")
;;

let test_remote_to_logical () =
  check string "relative logical path" "src/main.ml"
    (Keeper_remote_path.remote_to_logical ~remote_workspace_root remote_file);
  check string "root" "."
    (Keeper_remote_path.remote_to_logical ~remote_workspace_root
       "/srv/masc/playground/keeper-a");
  check string "outside unchanged" "/etc/passwd"
    (Keeper_remote_path.remote_to_logical ~remote_workspace_root "/etc/passwd")
;;

let test_jail_and_endpoint_isolation () =
  let outside = "/workspace/.masc/playground/keeper-b/src/main.ml" in
  let outside_result =
    host_to_remote ~base_path ~remote_workspace_root ~keeper:"keeper-a"
      outside
  in
  (match outside_result with
   | Ok path -> failf "outside path translated to %s" path
   | Error error ->
     check bool "named jail error" true
       (String.starts_with ~prefix:"remote_ssh_path_jail_violation:" error));
  check (result string string) "different endpoint root"
    (Ok "/srv/other/playground/keeper-a/src/main.ml")
    (host_to_remote ~base_path
       ~remote_workspace_root:"/srv/other/playground/keeper-a"
       ~keeper:"keeper-a" host_file)
;;

(* A guest work volume contains another resolved workspace root: the translation does
   not know which transport reaches it. *)
let test_guest_volume_root () =
  check (result string string) "host bookkeeping path lands on the volume"
    (Ok "/masc-work/keeper-a/src/main.ml")
    (host_to_remote ~lane:Keeper_remote_path.Microvm_guest ~base_path
       ~remote_workspace_root:"/masc-work/keeper-a"
       ~keeper:"keeper-a" host_file);
  check string "volume path maps back to the logical path" "src/main.ml"
    (Keeper_remote_path.remote_to_logical
       ~remote_workspace_root:"/masc-work/keeper-a"
       "/masc-work/keeper-a/src/main.ml")
;;

(* The remote namespace must not be resolved against the host filesystem: a
   host symlink (stand-in for the macOS /home firmlink) under the endpoint
   root's prefix must not leak its target into translated paths. *)
let test_host_symlink_does_not_rewrite_remote_paths () =
  let tmp = Filename.temp_file "remote-path" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o700;
  Fun.protect
    ~finally:(fun () ->
      Unix.unlink (Filename.concat tmp "link");
      Unix.rmdir (Filename.concat tmp "target");
      Unix.rmdir tmp)
    (fun () ->
      Unix.mkdir (Filename.concat tmp "target") 0o700;
      Unix.symlink
        (Filename.concat tmp "target")
        (Filename.concat tmp "link");
      let linked_workspace_root = Filename.concat tmp "link/playground/keeper-a" in
      check (result string string) "host symlink not substituted"
        (Ok (linked_workspace_root ^ "/src/main.ml"))
        (host_to_remote ~base_path
           ~remote_workspace_root:linked_workspace_root
           ~keeper:"keeper-a" host_file);
      check string "remote output maps back through the symlink form"
        "src/main.ml"
        (Keeper_remote_path.remote_to_logical
           ~remote_workspace_root:linked_workspace_root
           (linked_workspace_root ^ "/src/main.ml")))
;;

let test_relative_dot_segments () =
  check (result string string) "dot-segment cleanup stays lexical"
    (Ok remote_file)
    (host_to_remote ~base_path ~remote_workspace_root ~keeper:"keeper-a"
       "./src/../src/main.ml");
  check (result string string) "bare dot is the keeper root"
    (Ok "/srv/masc/playground/keeper-a")
    (host_to_remote ~base_path ~remote_workspace_root ~keeper:"keeper-a"
       ".");
  (match
     host_to_remote ~base_path ~remote_workspace_root ~keeper:"keeper-a"
       "src/../../escape"
   with
   | Ok path -> failf "escaping relative path translated to %s" path
   | Error error ->
     check bool "escape is a named jail error" true
       (String.starts_with ~prefix:"remote_ssh_path_jail_violation:" error))
;;

(* A microVM Keeper sees only its guest. A refused path names the guest lane
   and the guest root, never the host bookkeeping root it cannot reach. *)
let test_microvm_refusal_names_the_guest_root () =
  let lane = Keeper_remote_path.Microvm_guest in
  let remote_workspace_root = "/masc-work/keeper-a" in
  check (result string string) "a sibling guest root"
    (Error
       "microvm_remote_path_jail_violation: /masc-work/keeper-b/src is outside \
        the Keeper's guest root /masc-work/keeper-a")
    (host_to_remote ~lane ~base_path ~remote_workspace_root ~keeper:"keeper-a"
       "/masc-work/keeper-b/src");
  check (result string string) "a relative path that climbs out"
    (Error
       "microvm_remote_path_jail_violation: keeper-relative path ../keeper-b \
        escapes the Keeper's guest root /masc-work/keeper-a")
    (host_to_remote ~lane ~base_path ~remote_workspace_root ~keeper:"keeper-a"
       "../keeper-b");
  match
    Keeper_remote_path.host_to_remote ~lane ~base_path ~remote_workspace_root
      ~keeper:"keeper-a" "/masc-work/keeper-b/src"
  with
  | Ok path -> failf "sibling guest root translated to %s" path
  | Error
      { Keeper_remote_path.lane = Keeper_remote_path.Microvm_guest
      ; breach = Keeper_remote_path.Outside_keeper_root
      ; path
      ; endpoint_root
      ; host_root = _
      } ->
    check string "the refused path as given" "/masc-work/keeper-b/src" path;
    check string "the guest root" remote_workspace_root endpoint_root
  | Error { Keeper_remote_path.lane = Keeper_remote_path.Ssh_endpoint; _ } ->
    fail "a guest refusal carried the SSH lane"
  | Error { Keeper_remote_path.breach = Keeper_remote_path.Relative_escape; _ } ->
    fail "an absolute path read as a relative escape"
;;

let () =
  run "keeper_remote_path"
    [ ( "mapping"
      , [ test_case "host to remote" `Quick test_host_to_remote
        ; test_case "remote to logical" `Quick test_remote_to_logical
        ; test_case "jail + endpoint isolation" `Quick
            test_jail_and_endpoint_isolation
        ; test_case "guest work volume root" `Quick test_guest_volume_root
        ; test_case "host symlink immunity" `Quick
            test_host_symlink_does_not_rewrite_remote_paths
        ; test_case "relative dot segments" `Quick test_relative_dot_segments
        ; test_case "microVM refusal names the guest root" `Quick
            test_microvm_refusal_names_the_guest_root
        ] )
    ]
