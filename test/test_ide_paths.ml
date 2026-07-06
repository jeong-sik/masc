(** Tests for [Ide_paths] — RFC-0128 §6.1 unit tests.

    Verifies that {!Ide_paths.canonical_url_of_remote} is total,
    deterministic, and produces the same slug regardless of which
    transport the remote was registered with. *)

open Alcotest

module Paths = Ide_paths

let check_some_slug ~expected ~input () =
  match Paths.canonical_url_of_remote input with
  | Some s -> check string ("slug for " ^ input) expected s
  | None -> failf "expected Some %s for %s, got None" expected input
;;

let check_none ~input () =
  match Paths.canonical_url_of_remote input with
  | None -> ()
  | Some s -> failf "expected None for %s, got Some %s" input s
;;

let test_https_simple () =
  check_some_slug
    ~expected:"github.com_jeong-sik_masc"
    ~input:"https://github.com/jeong-sik/masc"
    ()
;;

let test_https_dot_git () =
  check_some_slug
    ~expected:"github.com_jeong-sik_masc"
    ~input:"https://github.com/jeong-sik/masc.git"
    ()
;;

let test_http_scheme () =
  check_some_slug
    ~expected:"example.com_owner_repo"
    ~input:"http://example.com/owner/repo"
    ()
;;

let test_ssh_url () =
  check_some_slug
    ~expected:"github.com_jeong-sik_masc"
    ~input:"ssh://git@github.com/jeong-sik/masc.git"
    ()
;;

let test_scp_form () =
  check_some_slug
    ~expected:"github.com_jeong-sik_masc"
    ~input:"git@github.com:jeong-sik/masc.git"
    ()
;;

let test_scp_form_no_dot_git () =
  check_some_slug
    ~expected:"github.com_jeong-sik_masc"
    ~input:"git@github.com:jeong-sik/masc"
    ()
;;

let test_https_uppercase () =
  (* RFC-0128 §4.1 rule 1: lowercase normalisation precedes parsing. *)
  check_some_slug
    ~expected:"github.com_jeong-sik_masc"
    ~input:"HTTPS://GitHub.com/Jeong-Sik/MASC.GIT"
    ()
;;

let test_nested_path () =
  check_some_slug
    ~expected:"gitlab.example.com_group_subgroup_repo"
    ~input:"https://gitlab.example.com/group/subgroup/repo"
    ()
;;

let test_join_invariant_https_ssh () =
  (* RFC-0128 §4.1 invariant: same upstream in different transport
     forms must produce the same slug. Without this property
     sandbox/working-tree join across keepers cannot work. *)
  let a = Paths.canonical_url_of_remote "https://github.com/jeong-sik/masc.git" in
  let b = Paths.canonical_url_of_remote "git@github.com:jeong-sik/masc.git" in
  let c = Paths.canonical_url_of_remote "ssh://git@github.com/jeong-sik/masc" in
  check (option string) "https == scp" a b;
  check (option string) "https == ssh-url" a c
;;

let test_empty () = check_none ~input:"" ()
let test_whitespace () = check_none ~input:"   " ()
let test_host_only () = check_none ~input:"https://github.com" ()
let test_host_only_no_scheme () = check_none ~input:"github.com" ()

let test_path_with_space () =
  (* Space is not in [a-z0-9._-]. Reject rather than silently slug-replace. *)
  check_none ~input:"https://github.com/foo bar/baz" ()
;;

let test_path_traversal () =
  check_none ~input:"https://github.com/../etc/passwd" ()
;;

let test_segment_with_colon () =
  (* ':' inside a path segment (after scp-form already disambiguated)
     is not a slug character. *)
  check_none ~input:"https://example.com/foo:bar/baz" ()
;;

(* Store path constructors. *)

let test_by_url_path () =
  let p =
    Paths.by_url_path
      ~base_dir:"/tmp/base"
      ~canonical_url:"github.com_jeong-sik_masc"
  in
  check string
    "by-url path layout"
    "/tmp/base/.masc-ide/by-url/github.com_jeong-sik_masc"
    p
;;

let test_orphan_path () =
  check string
    "orphan path layout"
    "/tmp/base/.masc-ide/_orphan"
    (Paths.orphan_path ~base_dir:"/tmp/base")
;;

let check_partition_metadata ~name ~partition ~kind ~is_orphan =
  check string (name ^ " kind") kind (Paths.partition_kind partition);
  check bool (name ^ " orphan") is_orphan (Paths.partition_is_orphan partition)
;;

let test_partition_metadata () =
  check_partition_metadata
    ~name:"by_url"
    ~partition:(Paths.By_url "github.com_jeong-sik_masc")
    ~kind:"by_url"
    ~is_orphan:false;
  check_partition_metadata
    ~name:"no_canonical_url"
    ~partition:Paths.No_canonical_url
    ~kind:"no_canonical_url"
    ~is_orphan:true;
  check_partition_metadata
    ~name:"unmatched"
    ~partition:Paths.Unmatched
    ~kind:"unmatched"
    ~is_orphan:true;
  check_partition_metadata
    ~name:"base_unresolved"
    ~partition:Paths.Base_unresolved
    ~kind:"base_unresolved"
    ~is_orphan:true;
  check_partition_metadata
    ~name:"legacy_default"
    ~partition:Paths.Legacy_default
    ~kind:"legacy_default"
    ~is_orphan:true
;;

let () =
  run
    "ide_paths"
    [ ( "canonical_url_of_remote — accept"
      , [ test_case "https simple" `Quick test_https_simple
        ; test_case "https .git suffix" `Quick test_https_dot_git
        ; test_case "http scheme" `Quick test_http_scheme
        ; test_case "ssh:// URL" `Quick test_ssh_url
        ; test_case "scp form" `Quick test_scp_form
        ; test_case "scp form no .git" `Quick test_scp_form_no_dot_git
        ; test_case "uppercase normalised" `Quick test_https_uppercase
        ; test_case "nested path" `Quick test_nested_path
        ; test_case "join invariant" `Quick test_join_invariant_https_ssh
        ] )
    ; ( "canonical_url_of_remote — reject"
      , [ test_case "empty" `Quick test_empty
        ; test_case "whitespace" `Quick test_whitespace
        ; test_case "host only with scheme" `Quick test_host_only
        ; test_case "host only no scheme" `Quick test_host_only_no_scheme
        ; test_case "path with space" `Quick test_path_with_space
        ; test_case "path traversal" `Quick test_path_traversal
        ; test_case "segment with colon" `Quick test_segment_with_colon
        ] )
    ; ( "store path constructors"
      , [ test_case "by_url_path" `Quick test_by_url_path
        ; test_case "orphan_path" `Quick test_orphan_path
        ] )
    ; "partition metadata", [ test_case "kind and orphan flag" `Quick test_partition_metadata ]
    ]
;;
