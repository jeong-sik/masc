(* Phase 1 task 2: the [exec.ssh.endpoints.<name>] registry in runtime config
   parses into typed Exec_ssh_endpoint records, applies the spec defaults
   (port 22, connect_timeout_sec 10, max_concurrent_sessions 8,
   env_allowlist [], capabilities [], and name-derived base-relative
   identity_file / known_hosts_file paths), and fails closed on unknown keys,
   missing required keys, and invalid endpoint names — an endpoint that did not
   parse cleanly must never reach dispatch half-populated. *)

open Alcotest

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  scan 0

(* The name is always quoted so invalid characters exercise the registry's own
   name validation instead of dying earlier as TOML syntax errors. *)
let endpoint_toml name extra =
  Printf.sprintf
    {|
[exec.ssh.endpoints."%s"]
host = "builder.local"
user = "masc-exec"
remote_root = "/srv/masc/playground"
%s
|}
    name
    extra

let parse_cfg toml = Runtime_toml.parse_string toml

let render_errors (errors : Runtime_toml.parse_error list) =
  String.concat
    "\n"
    (List.map
       (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message)
       errors)

let endpoint_exn cfg name =
  match Runtime_schema.exec_ssh_endpoint cfg name with
  | Some endpoint -> endpoint
  | None -> fail (Printf.sprintf "endpoint %S not found in registry" name)

let test_parse_minimal_endpoint () =
  match parse_cfg (endpoint_toml "dev" "") with
  | Error errors -> fail (render_errors errors)
  | Ok cfg ->
    let endpoint = endpoint_exn cfg "dev" in
    check string "host" "builder.local" endpoint.Exec_ssh_endpoint.host;
    check string "user" "masc-exec" endpoint.Exec_ssh_endpoint.user;
    check int "port default" 22 endpoint.Exec_ssh_endpoint.port;
    check string "identity_file default" ".masc/ssh/dev.key"
      endpoint.Exec_ssh_endpoint.identity_file;
    check string "known_hosts_file default" ".masc/ssh/known_hosts.d/dev"
      endpoint.Exec_ssh_endpoint.known_hosts_file;
    check string "remote_root" "/srv/masc/playground"
      endpoint.Exec_ssh_endpoint.remote_root;
    check int "connect_timeout_sec default" 10
      endpoint.Exec_ssh_endpoint.connect_timeout_sec;
    check int "max_concurrent_sessions default" 8
      endpoint.Exec_ssh_endpoint.max_concurrent_sessions;
    check (list string) "env_allowlist default" []
      endpoint.Exec_ssh_endpoint.env_allowlist;
    check (list string) "capabilities default" []
      endpoint.Exec_ssh_endpoint.capabilities;
    check bool "unknown name absent" true
      (Option.is_none (Runtime_schema.exec_ssh_endpoint cfg "nope"))

let test_explicit_overrides () =
  let extra =
    {|
port = 2222
identity_file = "/keys/dev.key"
known_hosts_file = "/keys/dev.known_hosts"
connect_timeout_sec = 3
max_concurrent_sessions = 2
env_allowlist = ["PATH", "HOME"]
capabilities = ["kvm"]
|}
  in
  match parse_cfg (endpoint_toml "dev" extra) with
  | Error errors -> fail (render_errors errors)
  | Ok cfg ->
    let endpoint = endpoint_exn cfg "dev" in
    check int "port" 2222 endpoint.Exec_ssh_endpoint.port;
    check string "identity_file" "/keys/dev.key"
      endpoint.Exec_ssh_endpoint.identity_file;
    check string "known_hosts_file" "/keys/dev.known_hosts"
      endpoint.Exec_ssh_endpoint.known_hosts_file;
    check int "connect_timeout_sec" 3
      endpoint.Exec_ssh_endpoint.connect_timeout_sec;
    check int "max_concurrent_sessions" 2
      endpoint.Exec_ssh_endpoint.max_concurrent_sessions;
    check (list string) "env_allowlist" [ "PATH"; "HOME" ]
      endpoint.Exec_ssh_endpoint.env_allowlist;
    check (list string) "capabilities" [ "kvm" ]
      endpoint.Exec_ssh_endpoint.capabilities

(* --- R00 encoder roundtrip (task-888) ----------------------------------

   Exec_ssh_endpoint.to_toml is the type-derived mirror of the strict
   decoder in this suite: whatever the encoder emits must load back
   through Runtime_toml into the very record that produced it. A field
   rename or a stray key (for example a duplicated name entry) that drifts
   between encoder and decoder fails here instead of letting every fixture
   silently feed a dead table. *)

let test_roundtrip_full_fields () =
  let endpoint =
    Exec_ssh_endpoint.
      { name = "build-box"
      ; host = "builder.local"
      ; user = "masc-exec"
      ; port = 2222
      ; identity_file = "/keys/dev.key"
      ; known_hosts_file = "/keys/dev.known_hosts"
      ; remote_root = "/srv/masc/playground"
      ; connect_timeout_sec = 3
      ; max_concurrent_sessions = 2
      ; env_allowlist = [ "PATH"; "HOME" ]
      ; capabilities = [ "kvm" ]
      }
  in
  match parse_cfg (Exec_ssh_endpoint.to_toml endpoint) with
  | Error errors -> fail (render_errors errors)
  | Ok cfg ->
    let decoded = endpoint_exn cfg "build-box" in
    check bool "full-field roundtrip equal" true
      (Exec_ssh_endpoint.equal endpoint decoded)

let test_roundtrip_defaults () =
  let endpoint =
    Exec_ssh_endpoint.
      { name = "dev"
      ; host = "builder.local"
      ; user = "masc-exec"
      ; port = default_port
      ; identity_file = default_identity_file ~name:"dev"
      ; known_hosts_file = default_known_hosts_file ~name:"dev"
      ; remote_root = "/srv/masc/playground"
      ; connect_timeout_sec = default_connect_timeout_sec
      ; max_concurrent_sessions = default_max_concurrent_sessions
      ; env_allowlist = []
      ; capabilities = []
      }
  in
  match parse_cfg (Exec_ssh_endpoint.to_toml endpoint) with
  | Error errors -> fail (render_errors errors)
  | Ok cfg ->
    let decoded = endpoint_exn cfg "dev" in
    check bool "defaults roundtrip equal" true
      (Exec_ssh_endpoint.equal endpoint decoded)

let test_roundtrip_no_stray_name_field () =
  (* The registry name is the table header key, never a body field: a
     duplicated name entry is an unknown key and fails the whole load. *)
  let endpoint =
    Exec_ssh_endpoint.
      { name = "dev"
      ; host = "builder.local"
      ; user = "masc-exec"
      ; port = default_port
      ; identity_file = default_identity_file ~name:"dev"
      ; known_hosts_file = default_known_hosts_file ~name:"dev"
      ; remote_root = "/srv/masc/playground"
      ; connect_timeout_sec = default_connect_timeout_sec
      ; max_concurrent_sessions = default_max_concurrent_sessions
      ; env_allowlist = []
      ; capabilities = []
      }
  in
  let text = Exec_ssh_endpoint.to_toml endpoint in
  check bool "no name body field" false (contains "name = " text);
  check bool "header names the endpoint" true (contains "endpoints.dev]" text)

let test_unknown_capability_warn_and_ignore () =
  let extra = "capabilities = [\"kvm\", \"time-travel\"]" in
  match parse_cfg (endpoint_toml "dev" extra) with
  | Error errors -> fail (render_errors errors)
  | Ok cfg ->
    let endpoint = endpoint_exn cfg "dev" in
    check (list string) "unknown capability dropped" [ "kvm" ]
      endpoint.Exec_ssh_endpoint.capabilities

let test_unknown_key_rejected () =
  match parse_cfg (endpoint_toml "dev" "bogus_key = 1") with
  | Ok _ -> fail "unknown endpoint key must be rejected"
  | Error errors ->
    check bool "names the key" true (contains "bogus_key" (render_errors errors))

let test_missing_required_rejected () =
  (* Only host: both user and remote_root are required, so both must be
     reported. *)
  let toml =
    {|
[exec.ssh.endpoints.dev]
host = "builder.local"
|}
  in
  match parse_cfg toml with
  | Ok _ -> fail "endpoint without user/remote_root must be rejected"
  | Error errors ->
    let rendered = render_errors errors in
    check bool "names user" true (contains "user" rendered);
    check bool "names remote_root" true (contains "remote_root" rendered)

let test_endpoint_name_validation () =
  match parse_cfg (endpoint_toml "bad name!" "") with
  | Ok _ -> fail "invalid endpoint name must be rejected"
  | Error errors ->
    check bool "names the id" true
      (contains "bad name!" (render_errors errors))

let test_stray_exec_key_rejected () =
  (* Fail-closed at the namespace level: [exec] owns exactly one key ([ssh]),
     [exec.ssh] owns exactly one key ([endpoints]). Anything else is a typo the
     load must name instead of silently dropping. *)
  let toml =
    {|
[exec.something_else]
foo = 1
|}
  in
  match parse_cfg toml with
  | Ok _ -> fail "unknown [exec] key must be rejected"
  | Error errors ->
    check bool "names the key" true
      (contains "something_else" (render_errors errors))

let test_scalar_endpoint_rejected () =
  (* A scalar at the endpoint position is a shape error, not a crash: the
     parser must fail closed with a named path. *)
  let toml = "[exec.ssh.endpoints]\ndev = \"oops\"\n" in
  match parse_cfg toml with
  | Ok _ -> fail "scalar endpoint must be rejected"
  | Error errors ->
    check bool "names table shape" true
      (contains "must be a TOML table" (render_errors errors))

let test_duplicate_endpoint_table_rejected () =
  (* otoml raises on the duplicate table header before the registry parser
     runs; the load must still fail closed. *)
  let toml = endpoint_toml "dev" "" ^ endpoint_toml "dev" "" in
  match parse_cfg toml with
  | Ok _ -> fail "duplicate endpoint table must be rejected"
  | Error _ -> ()

let test_port_bounds () =
  let reject extra expected =
    match parse_cfg (endpoint_toml "dev" extra) with
    | Ok _ -> fail (Printf.sprintf "port bound %S must be rejected" extra)
    | Error errors ->
      check bool "names the bound" true
        (contains expected (render_errors errors))
  in
  reject "port = 0" "positive integer";
  reject "port = 70000" "65535"

let test_capabilities_non_string_rejected () =
  let extra = "capabilities = [1]" in
  match parse_cfg (endpoint_toml "dev" extra) with
  | Ok _ -> fail "non-string capability must be rejected"
  | Error errors ->
    check bool "names the key" true
      (contains "capabilities" (render_errors errors))

let test_padded_host_rejected () =
  let toml =
    {|
[exec.ssh.endpoints.dev]
host = " builder.local "
user = "masc-exec"
remote_root = "/srv/masc/playground"
|}
  in
  match parse_cfg toml with
  | Ok _ -> fail "padded host must be rejected"
  | Error errors ->
    check bool "names whitespace" true
      (contains "whitespace" (render_errors errors))

let test_destination_option_injection_rejected () =
  let reject ~field ~value =
    let host = if field = "host" then value else "builder.local" in
    let user = if field = "user" then value else "masc-exec" in
    let toml =
      Printf.sprintf
        {|
[exec.ssh.endpoints.dev]
host = %S
user = %S
remote_root = "/srv/masc/playground"
|}
        host user
    in
    match parse_cfg toml with
    | Ok _ -> failf "unsafe SSH %s %S must be rejected" field value
    | Error errors ->
      let rendered = render_errors errors in
      check bool "named endpoint error" true
        (contains "remote_ssh_endpoint_invalid" rendered);
      check bool "names option injection" true
        (contains "option injection" rendered)
  in
  reject ~field:"user" ~value:"-oProxyCommand=/bin/echo pwned #";
  reject ~field:"host" ~value:"-F"

let test_relative_remote_root_rejected () =
  let toml =
    {|
[exec.ssh.endpoints.dev]
host = "builder.local"
user = "masc-exec"
remote_root = "srv/masc"
|}
  in
  match parse_cfg toml with
  | Ok _ -> fail "relative remote_root must be rejected"
  | Error errors ->
    let rendered = render_errors errors in
    check bool "names the key" true (contains "remote_root" rendered);
    check bool "names absolute" true (contains "absolute" rendered)

let test_absent_section_is_empty_registry () =
  match parse_cfg "" with
  | Error errors -> fail (render_errors errors)
  | Ok cfg ->
    check int "no endpoints" 0 (List.length cfg.Runtime_schema.exec_ssh_endpoints)

let () =
  run "exec ssh endpoints"
    [ ( "parse"
      , [ test_case "minimal endpoint + defaults" `Quick test_parse_minimal_endpoint
        ; test_case "explicit overrides" `Quick test_explicit_overrides
        ; test_case "absent section" `Quick test_absent_section_is_empty_registry
        ] )
    ; ( "roundtrip"
      , [ test_case "full-field roundtrip" `Quick test_roundtrip_full_fields
        ; test_case "spec defaults roundtrip" `Quick test_roundtrip_defaults
        ; test_case "no stray name field" `Quick test_roundtrip_no_stray_name_field
        ]
      )
    ; ( "fail-closed"
      , [ test_case "unknown key rejected" `Quick test_unknown_key_rejected
        ; test_case "missing required rejected" `Quick test_missing_required_rejected
        ; test_case "endpoint name validation" `Quick test_endpoint_name_validation
        ; test_case "stray exec key rejected" `Quick test_stray_exec_key_rejected
        ; test_case "scalar endpoint rejected" `Quick test_scalar_endpoint_rejected
        ; test_case "duplicate table rejected" `Quick
            test_duplicate_endpoint_table_rejected
        ; test_case "padded host rejected" `Quick test_padded_host_rejected
        ; test_case "destination option injection rejected" `Quick
            test_destination_option_injection_rejected
        ; test_case "relative remote_root rejected" `Quick
            test_relative_remote_root_rejected
        ; test_case "port bounds" `Quick test_port_bounds
        ] )
    ; ( "capabilities"
      , [ test_case "unknown warn-and-ignore" `Quick
            test_unknown_capability_warn_and_ignore
        ; test_case "non-string rejected" `Quick
            test_capabilities_non_string_rejected
        ] )
    ]
