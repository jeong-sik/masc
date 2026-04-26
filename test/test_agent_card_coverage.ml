(** Agent Card Coverage Tests - A2A Protocol v0.3.0 Compatible Agent Metadata *)

open Alcotest
module Agent_card = Masc_mcp.Agent_card
module Config = Masc_mcp.Config

(* ============================================================
   Provider Tests
   ============================================================ *)

let test_provider_json_roundtrip () =
  let p : Agent_card.provider =
    { organization = "Test Org"; url = Some "https://example.com" }
  in
  let json = Agent_card.provider_to_yojson p in
  match Agent_card.provider_of_yojson json with
  | Ok p' ->
    check string "organization" p.organization p'.organization;
    check (option string) "url" p.url p'.url
  | Error e -> fail ("Provider roundtrip failed: " ^ e)
;;

let test_provider_without_url () =
  let p : Agent_card.provider = { organization = "Minimal Org"; url = None } in
  let json = Agent_card.provider_to_yojson p in
  match Agent_card.provider_of_yojson json with
  | Ok p' ->
    check string "organization" "Minimal Org" p'.organization;
    check (option string) "url" None p'.url
  | Error e -> fail ("Provider roundtrip failed: " ^ e)
;;

let test_provider_show () =
  let p : Agent_card.provider =
    { organization = "Show Test"; url = Some "https://show.test" }
  in
  let s = Agent_card.show_provider p in
  check bool "contains organization" true (String.length s > 0);
  check bool "contains Show Test" true (Str.string_match (Str.regexp ".*Show Test.*") s 0)
;;

let test_provider_eq () =
  let p1 : Agent_card.provider = { organization = "A"; url = Some "x" } in
  let p2 : Agent_card.provider = { organization = "A"; url = Some "x" } in
  let p3 : Agent_card.provider = { organization = "B"; url = Some "x" } in
  check bool "equal same" true (Agent_card.equal_provider p1 p2);
  check bool "not equal diff org" false (Agent_card.equal_provider p1 p3)
;;

(* ============================================================
   Skill Tests
   ============================================================ *)

let test_skill_json_roundtrip () =
  let s : Agent_card.skill =
    { id = "test-skill"
    ; name = "Test Skill"
    ; description = Some "A test skill"
    ; tags = []
    ; input_modes = [ "text/plain"; "application/json" ]
    ; output_modes = [ "text/plain"; "application/octet-stream" ]
    ; tool_count = 0
    }
  in
  let json = Agent_card.skill_to_yojson s in
  match Agent_card.skill_of_yojson json with
  | Ok s' ->
    check string "id" s.id s'.id;
    check string "name" s.name s'.name;
    check (option string) "description" s.description s'.description;
    check (list string) "input_modes" s.input_modes s'.input_modes;
    check (list string) "output_modes" s.output_modes s'.output_modes
  | Error e -> fail ("Skill roundtrip failed: " ^ e)
;;

let test_skill_without_description () =
  let s : Agent_card.skill =
    { id = "minimal"
    ; name = "Minimal"
    ; description = None
    ; tags = []
    ; input_modes = []
    ; output_modes = []
    ; tool_count = 0
    }
  in
  let json = Agent_card.skill_to_yojson s in
  match Agent_card.skill_of_yojson json with
  | Ok s' ->
    check string "id" "minimal" s'.id;
    check (option string) "description" None s'.description
  | Error e -> fail ("Skill roundtrip failed: " ^ e)
;;

let test_skill_show () =
  let s : Agent_card.skill =
    { id = "show-test"
    ; name = "Show Test Skill"
    ; description = Some "Test"
    ; tags = []
    ; input_modes = [ "text/plain" ]
    ; output_modes = [ "text/plain" ]
    ; tool_count = 0
    }
  in
  let str = Agent_card.show_skill s in
  check bool "non-empty" true (String.length str > 0)
;;

let test_skill_eq () =
  let s1 : Agent_card.skill =
    { id = "a"
    ; name = "A"
    ; description = None
    ; tags = []
    ; input_modes = []
    ; output_modes = []
    ; tool_count = 0
    }
  in
  let s2 : Agent_card.skill =
    { id = "a"
    ; name = "A"
    ; description = None
    ; tags = []
    ; input_modes = []
    ; output_modes = []
    ; tool_count = 0
    }
  in
  let s3 : Agent_card.skill =
    { id = "b"
    ; name = "B"
    ; description = None
    ; tags = []
    ; input_modes = []
    ; output_modes = []
    ; tool_count = 0
    }
  in
  check bool "equal same" true (Agent_card.equal_skill s1 s2);
  check bool "not equal diff" false (Agent_card.equal_skill s1 s3)
;;

(* ============================================================
   Binding Tests (supportedInterfaces in v0.3)
   ============================================================ *)

let test_binding_json_roundtrip () =
  let b : Agent_card.binding =
    { protocol = "JSONRPC"; url = "http://localhost:8935/mcp" }
  in
  let json = Agent_card.binding_to_yojson b in
  match Agent_card.binding_of_yojson json with
  | Ok b' ->
    check string "protocol" b.protocol b'.protocol;
    check string "url" b.url b'.url
  | Error e -> fail ("Binding roundtrip failed: " ^ e)
;;

let test_binding_grpc () =
  let b : Agent_card.binding = { protocol = "GRPC"; url = "grpc://127.0.0.1:8936" } in
  let json = Agent_card.binding_to_yojson b in
  match Agent_card.binding_of_yojson json with
  | Ok b' ->
    check string "protocol" "GRPC" b'.protocol;
    check bool "url starts with grpc" true (String.sub b'.url 0 4 = "grpc")
  | Error e -> fail ("Binding roundtrip failed: " ^ e)
;;

let test_binding_show () =
  let b : Agent_card.binding = { protocol = "SSE"; url = "http://test/sse" } in
  let s = Agent_card.show_binding b in
  check bool "non-empty" true (String.length s > 0)
;;

let test_binding_eq () =
  let b1 : Agent_card.binding = { protocol = "x"; url = "y" } in
  let b2 : Agent_card.binding = { protocol = "x"; url = "y" } in
  let b3 : Agent_card.binding = { protocol = "z"; url = "y" } in
  check bool "equal same" true (Agent_card.equal_binding b1 b2);
  check bool "not equal diff" false (Agent_card.equal_binding b1 b3)
;;

(* ============================================================
   Security Scheme Tests
   ============================================================ *)

let test_security_scheme_bearer () =
  let s : Agent_card.security_scheme =
    { scheme_type = "bearer"
    ; bearer_format = Some "JWT"
    ; api_key_name = None
    ; api_key_in = None
    }
  in
  let json = Agent_card.security_scheme_to_yojson s in
  match Agent_card.security_scheme_of_yojson json with
  | Ok s' ->
    check string "scheme_type" "bearer" s'.scheme_type;
    check (option string) "bearer_format" (Some "JWT") s'.bearer_format
  | Error e -> fail ("Security scheme roundtrip failed: " ^ e)
;;

let test_security_scheme_apikey () =
  let s : Agent_card.security_scheme =
    { scheme_type = "apiKey"
    ; bearer_format = None
    ; api_key_name = Some "X-API-Key"
    ; api_key_in = Some "header"
    }
  in
  let json = Agent_card.security_scheme_to_yojson s in
  match Agent_card.security_scheme_of_yojson json with
  | Ok s' ->
    check string "scheme_type" "apiKey" s'.scheme_type;
    check (option string) "api_key_name" (Some "X-API-Key") s'.api_key_name;
    check (option string) "api_key_in" (Some "header") s'.api_key_in
  | Error e -> fail ("Security scheme roundtrip failed: " ^ e)
;;

let test_security_scheme_none () =
  let s : Agent_card.security_scheme =
    { scheme_type = "none"; bearer_format = None; api_key_name = None; api_key_in = None }
  in
  let json = Agent_card.security_scheme_to_yojson s in
  match Agent_card.security_scheme_of_yojson json with
  | Ok s' -> check string "scheme_type" "none" s'.scheme_type
  | Error e -> fail ("Security scheme roundtrip failed: " ^ e)
;;

let test_security_scheme_show () =
  let s : Agent_card.security_scheme =
    { scheme_type = "bearer"
    ; bearer_format = Some "MASC"
    ; api_key_name = None
    ; api_key_in = None
    }
  in
  let str = Agent_card.show_security_scheme s in
  check bool "non-empty" true (String.length str > 0)
;;

let test_security_scheme_eq () =
  let s1 : Agent_card.security_scheme =
    { scheme_type = "none"; bearer_format = None; api_key_name = None; api_key_in = None }
  in
  let s2 : Agent_card.security_scheme =
    { scheme_type = "none"; bearer_format = None; api_key_name = None; api_key_in = None }
  in
  check bool "equal same" true (Agent_card.equal_security_scheme s1 s2)
;;

(* ============================================================
   Capabilities Tests (v0.3 structured)
   ============================================================ *)

let test_capabilities_to_json () =
  let c : Agent_card.agent_capabilities =
    { streaming = true; push_notifications = true; extended_agent_card = false }
  in
  let json = Agent_card.capabilities_to_json c in
  let open Yojson.Safe.Util in
  check bool "streaming" true (json |> member "streaming" |> to_bool);
  check bool "pushNotifications" true (json |> member "pushNotifications" |> to_bool);
  check bool "extendedAgentCard" false (json |> member "extendedAgentCard" |> to_bool)
;;

let test_capabilities_of_json_structured () =
  let json =
    `Assoc
      [ "streaming", `Bool true
      ; "pushNotifications", `Bool false
      ; "extendedAgentCard", `Bool true
      ]
  in
  let c = Agent_card.capabilities_of_json json in
  check bool "streaming" true c.streaming;
  check bool "push_notifications" false c.push_notifications;
  check bool "extended_agent_card" true c.extended_agent_card
;;

let test_capabilities_of_json_legacy_list () =
  (* Backward compat: old string list format *)
  let json = `List [ `String "streaming"; `String "push-notifications" ] in
  let c = Agent_card.capabilities_of_json json in
  check bool "streaming from list" true c.streaming;
  check bool "push_notifications from list" true c.push_notifications;
  check bool "extended_agent_card default" false c.extended_agent_card
;;

(* ============================================================
   Signature Tests (v0.3 JWS)
   ============================================================ *)

let test_signature_to_json () =
  let s : Agent_card.agent_card_signature =
    { protected_header = "eyJhbGciOiJFUzI1NiJ9"
    ; signature = "abc123"
    ; header = [ "kid", "key-1" ]
    }
  in
  let json = Agent_card.signature_to_json s in
  let open Yojson.Safe.Util in
  check string "protected" "eyJhbGciOiJFUzI1NiJ9" (json |> member "protected" |> to_string);
  check string "signature" "abc123" (json |> member "signature" |> to_string);
  check bool "has header" true (json |> member "header" |> to_assoc |> List.length > 0)
;;

let test_signature_roundtrip () =
  let s : Agent_card.agent_card_signature =
    { protected_header = "eyJhbGciOiJFUzI1NiJ9"; signature = "sig-data"; header = [] }
  in
  let json = Agent_card.signature_to_json s in
  match Agent_card.signature_of_json json with
  | Some s' ->
    check string "protected" s.protected_header s'.protected_header;
    check string "signature" s.signature s'.signature
  | None -> fail "Signature roundtrip failed"
;;

let test_signature_of_json_invalid () =
  let json = `String "not an object" in
  check (option reject) "invalid returns None" None (Agent_card.signature_of_json json)
;;

(* ============================================================
   Agent Card Tests (v0.3)
   ============================================================ *)

let test_generate_default () =
  let card = Agent_card.generate_default ~schemas:Config.raw_all_tool_schemas () in
  check string "name" "MASC-MCP" card.name;
  check string "version" Masc_mcp.Version.version card.version;
  check bool "has description" true (Option.is_some card.description);
  check bool "has provider" true (Option.is_some card.provider);
  check bool "streaming capability" true card.capabilities.streaming;
  check bool "push_notifications capability" true card.capabilities.push_notifications;
  check bool "has skills" true (List.length card.skills > 0);
  check bool "has interfaces" true (List.length card.supported_interfaces > 0);
  check (list string) "protocol_versions" [ "0.3" ] card.protocol_versions
;;

let test_generate_default_advertises_runtime_transports () =
  let card = Agent_card.generate_default () in
  let protocols =
    List.map
      (fun (binding : Agent_card.binding) -> binding.protocol)
      card.supported_interfaces
  in
  check bool "has GRPC" true (List.mem "GRPC" protocols);
  check bool "has WEBSOCKET" true (List.mem "WEBSOCKET" protocols);
  check bool "has WEBRTC" true (List.mem "WEBRTC" protocols)
;;

let test_generate_with_custom_port () =
  let card = Agent_card.generate_default ~port:9000 () in
  let has_9000 =
    List.exists
      (fun (b : Agent_card.binding) -> Str.string_match (Str.regexp ".*9000.*") b.url 0)
      card.supported_interfaces
  in
  check bool "interface has custom port" true has_9000
;;

let test_generate_with_custom_host () =
  let card = Agent_card.generate_default ~host:"0.0.0.0" () in
  let has_custom_host =
    List.exists
      (fun (b : Agent_card.binding) ->
         Str.string_match (Str.regexp ".*0\\.0\\.0\\.0.*") b.url 0)
      card.supported_interfaces
  in
  check bool "interface has custom host" true has_custom_host
;;

let test_agent_card_to_json () =
  let card = Agent_card.generate_default () in
  let json = Agent_card.to_json card in
  match json with
  | `Assoc fields ->
    check bool "has name" true (List.mem_assoc "name" fields);
    check bool "has version" true (List.mem_assoc "version" fields);
    check bool "has capabilities" true (List.mem_assoc "capabilities" fields);
    check bool "has skills" true (List.mem_assoc "skills" fields);
    check
      bool
      "has supportedInterfaces"
      true
      (List.mem_assoc "supportedInterfaces" fields);
    check bool "has protocolVersions" true (List.mem_assoc "protocolVersions" fields);
    check bool "has createdAt" true (List.mem_assoc "createdAt" fields);
    check bool "has updatedAt" true (List.mem_assoc "updatedAt" fields)
  | _ -> fail "Expected JSON object"
;;

let test_agent_card_json_roundtrip () =
  let card = Agent_card.generate_default () in
  let json = Agent_card.to_json card in
  match Agent_card.from_json json with
  | Ok card' ->
    check string "name" card.name card'.name;
    check string "version" card.version card'.version;
    check bool "streaming" card.capabilities.streaming card'.capabilities.streaming;
    check int "skills count" (List.length card.skills) (List.length card'.skills);
    check
      int
      "interfaces count"
      (List.length card.supported_interfaces)
      (List.length card'.supported_interfaces);
    check (list string) "protocol_versions" card.protocol_versions card'.protocol_versions
  | Error e -> fail ("Agent card roundtrip failed: " ^ e)
;;

let test_from_json_invalid () =
  let json = `String "not an object" in
  match Agent_card.from_json json with
  | Ok _ -> fail "Should fail on invalid JSON"
  | Error _ -> ()
;;

let test_from_json_missing_fields () =
  let json = `Assoc [ "name", `String "Test" ] in
  match Agent_card.from_json json with
  | Ok _ -> fail "Should fail on missing required fields"
  | Error _ -> ()
;;

let test_from_json_legacy_bindings () =
  (* Backward compat: accept "bindings" key from older cards *)
  let json =
    `Assoc
      [ "name", `String "Legacy"
      ; "version", `String "1.0.0"
      ; "capabilities", `List [ `String "streaming" ]
      ; "skills", `List []
      ; ( "bindings"
        , `List [ `Assoc [ "protocol", `String "sse"; "url", `String "http://test/sse" ] ]
        )
      ; "securitySchemes", `Assoc []
      ; "defaultInputModes", `List []
      ; "defaultOutputModes", `List []
      ; "createdAt", `String "2026-01-01T00:00:00Z"
      ; "updatedAt", `String "2026-01-01T00:00:00Z"
      ]
  in
  match Agent_card.from_json json with
  | Ok card' ->
    check int "interfaces from legacy bindings" 1 (List.length card'.supported_interfaces);
    check bool "streaming from legacy list" true card'.capabilities.streaming
  | Error e -> fail ("Legacy bindings parse failed: " ^ e)
;;

let test_from_json_legacy_signature () =
  (* Backward compat: accept "signature" string from older cards *)
  let json =
    `Assoc
      [ "name", `String "Legacy"
      ; "version", `String "1.0.0"
      ; ( "capabilities"
        , `Assoc
            [ "streaming", `Bool false
            ; "pushNotifications", `Bool false
            ; "extendedAgentCard", `Bool false
            ] )
      ; "skills", `List []
      ; "supportedInterfaces", `List []
      ; "securitySchemes", `Assoc []
      ; "defaultInputModes", `List []
      ; "defaultOutputModes", `List []
      ; "signature", `String "old-sig"
      ; "createdAt", `String "2026-01-01T00:00:00Z"
      ; "updatedAt", `String "2026-01-01T00:00:00Z"
      ]
  in
  match Agent_card.from_json json with
  | Ok card' ->
    check int "signatures from legacy" 1 (List.length card'.signatures);
    check string "signature value" "old-sig" (List.hd card'.signatures).signature
  | Error e -> fail ("Legacy signature parse failed: " ^ e)
;;

let test_with_bindings () =
  let card = Agent_card.generate_default () in
  let new_bindings : Agent_card.binding list =
    [ { protocol = "custom"; url = "custom://test" } ]
  in
  let card' = Agent_card.with_bindings card new_bindings in
  check int "interfaces count" 1 (List.length card'.supported_interfaces);
  check string "interface protocol" "custom" (List.hd card'.supported_interfaces).protocol
;;

let test_with_extension () =
  let card = Agent_card.generate_default () in
  let card' = Agent_card.with_extension card "custom_ext" (`String "value") in
  let has_custom = List.exists (fun (k, _) -> k = "custom_ext") card'.extensions in
  check bool "has custom extension" true has_custom
;;

let test_with_extension_overwrite () =
  let card = Agent_card.generate_default () in
  let card' = Agent_card.with_extension card "masc" (`String "overwritten") in
  let masc_ext = List.find_opt (fun (k, _) -> k = "masc") card'.extensions in
  match masc_ext with
  | Some (_, `String "overwritten") -> ()
  | Some (_, _) -> fail "masc extension should be overwritten"
  | None -> fail "masc extension should exist"
;;

let test_agent_card_show () =
  let card = Agent_card.generate_default () in
  let s = Agent_card.show_agent_card card in
  check bool "non-empty" true (String.length s > 0)
;;

let test_agent_card_eq () =
  let card1 = Agent_card.generate_default () in
  let card2 = Agent_card.generate_default () in
  check bool "equal name" true (card1.name = card2.name);
  check bool "equal version" true (card1.version = card2.version)
;;

(* ============================================================
   MASC Skills Tests
   ============================================================ *)

let dynamic_skills () = Agent_card.skills_from_tools Config.raw_all_tool_schemas

let test_masc_skills_not_empty () =
  check bool "has skills" true (List.length (dynamic_skills ()) > 0)
;;

let test_masc_skills_have_ids () =
  let all_have_ids =
    List.for_all
      (fun (s : Agent_card.skill) -> String.length s.id > 0)
      (dynamic_skills ())
  in
  check bool "all have ids" true all_have_ids
;;

let test_masc_skills_unique_ids () =
  let ids = List.map (fun (s : Agent_card.skill) -> s.id) (dynamic_skills ()) in
  let unique_ids = List.sort_uniq String.compare ids in
  check int "unique ids" (List.length ids) (List.length unique_ids)
;;

let test_masc_skills_have_names () =
  let all_have_names =
    List.for_all
      (fun (s : Agent_card.skill) -> String.length s.name > 0)
      (dynamic_skills ())
  in
  check bool "all have names" true all_have_names
;;

let test_masc_skills_expected_count () =
  let count = List.length (dynamic_skills ()) in
  check int "single masc skill" 1 count
;;

let test_masc_skill_id_is_masc () =
  match dynamic_skills () with
  | [ skill ] -> check string "skill id" "masc" skill.id
  | _ -> fail "expected one masc skill"
;;

let test_masc_skills_mime_types () =
  let all_mime =
    List.for_all
      (fun (s : Agent_card.skill) ->
         List.for_all (fun m -> String.contains m '/') s.input_modes
         && List.for_all (fun m -> String.contains m '/') s.output_modes)
      (dynamic_skills ())
  in
  check bool "all modes are MIME types" true all_mime
;;

let test_masc_skills_have_tags () =
  let all_have_tags =
    List.for_all
      (fun (s : Agent_card.skill) -> List.length s.tags > 0)
      (dynamic_skills ())
  in
  check bool "all have tags" true all_have_tags
;;

let test_masc_skills_have_tool_count () =
  let all_positive =
    List.for_all (fun (s : Agent_card.skill) -> s.tool_count > 0) (dynamic_skills ())
  in
  check bool "all have positive tool_count" true all_positive
;;

(* ============================================================
   Now ISO8601 Tests
   ============================================================ *)

let test_now_iso8601_format () =
  let ts = Agent_card.now_iso8601 () in
  let regex =
    Str.regexp
      "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z"
  in
  check bool "valid ISO8601 format" true (Str.string_match regex ts 0)
;;

let test_now_iso8601_length () =
  let ts = Agent_card.now_iso8601 () in
  check int "timestamp length" 20 (String.length ts)
;;

(* ============================================================
   Edge Cases
   ============================================================ *)

let test_default_capabilities () =
  let card = Agent_card.generate_default () in
  let no_caps =
    { card with
      capabilities =
        { streaming = false; push_notifications = false; extended_agent_card = false }
    }
  in
  let json = Agent_card.to_json no_caps in
  match Agent_card.from_json json with
  | Ok card' ->
    check bool "streaming off" false card'.capabilities.streaming;
    check bool "push off" false card'.capabilities.push_notifications
  | Error e -> fail ("Capabilities roundtrip failed: " ^ e)
;;

let test_empty_skills () =
  let card = Agent_card.generate_default () in
  let minimal_card = { card with skills = [] } in
  let json = Agent_card.to_json minimal_card in
  match Agent_card.from_json json with
  | Ok card' -> check int "empty skills" 0 (List.length card'.skills)
  | Error e -> fail ("Empty skills roundtrip failed: " ^ e)
;;

let test_empty_interfaces () =
  let card = Agent_card.generate_default () in
  let minimal_card = { card with supported_interfaces = [] } in
  let json = Agent_card.to_json minimal_card in
  match Agent_card.from_json json with
  | Ok card' -> check int "empty interfaces" 0 (List.length card'.supported_interfaces)
  | Error e -> fail ("Empty interfaces roundtrip failed: " ^ e)
;;

let test_empty_extensions () =
  let card = Agent_card.generate_default () in
  let minimal_card = { card with extensions = [] } in
  let json = Agent_card.to_json minimal_card in
  match Agent_card.from_json json with
  | Ok card' -> check int "empty extensions" 0 (List.length card'.extensions)
  | Error e -> fail ("Empty extensions roundtrip failed: " ^ e)
;;

let test_signatures_empty () =
  let card = Agent_card.generate_default () in
  check int "no signatures by default" 0 (List.length card.signatures)
;;

let test_signatures_set () =
  let card = Agent_card.generate_default () in
  let sig1 : Agent_card.agent_card_signature =
    { protected_header = "eyJhbGciOiJFUzI1NiJ9"; signature = "sig123"; header = [] }
  in
  let signed_card = { card with signatures = [ sig1 ] } in
  let json = Agent_card.to_json signed_card in
  match Agent_card.from_json json with
  | Ok card' ->
    check int "signature count" 1 (List.length card'.signatures);
    check string "signature preserved" "sig123" (List.hd card'.signatures).signature
  | Error e -> fail ("Signed card roundtrip failed: " ^ e)
;;

let test_optional_fields () =
  let card = Agent_card.generate_default () in
  check
    (option string)
    "documentation_url set"
    (Some "https://github.com/jeong-sik/masc-mcp")
    card.documentation_url;
  check (option string) "icon_url not set" None card.icon_url
;;

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run
    "Agent Card Coverage"
    [ ( "provider"
      , [ test_case "json roundtrip" `Quick test_provider_json_roundtrip
        ; test_case "without url" `Quick test_provider_without_url
        ; test_case "show" `Quick test_provider_show
        ; test_case "eq" `Quick test_provider_eq
        ] )
    ; ( "skill"
      , [ test_case "json roundtrip" `Quick test_skill_json_roundtrip
        ; test_case "without description" `Quick test_skill_without_description
        ; test_case "show" `Quick test_skill_show
        ; test_case "eq" `Quick test_skill_eq
        ] )
    ; ( "binding"
      , [ test_case "json roundtrip" `Quick test_binding_json_roundtrip
        ; test_case "grpc binding" `Quick test_binding_grpc
        ; test_case "show" `Quick test_binding_show
        ; test_case "eq" `Quick test_binding_eq
        ] )
    ; ( "security_scheme"
      , [ test_case "bearer" `Quick test_security_scheme_bearer
        ; test_case "apikey" `Quick test_security_scheme_apikey
        ; test_case "none" `Quick test_security_scheme_none
        ; test_case "show" `Quick test_security_scheme_show
        ; test_case "eq" `Quick test_security_scheme_eq
        ] )
    ; ( "capabilities_v03"
      , [ test_case "to_json" `Quick test_capabilities_to_json
        ; test_case "of_json structured" `Quick test_capabilities_of_json_structured
        ; test_case "of_json legacy list" `Quick test_capabilities_of_json_legacy_list
        ] )
    ; ( "signatures_v03"
      , [ test_case "to_json" `Quick test_signature_to_json
        ; test_case "roundtrip" `Quick test_signature_roundtrip
        ; test_case "invalid returns None" `Quick test_signature_of_json_invalid
        ] )
    ; ( "agent_card"
      , [ test_case "generate default" `Quick test_generate_default
        ; test_case
            "generate default advertises runtime transports"
            `Quick
            test_generate_default_advertises_runtime_transports
        ; test_case "custom port" `Quick test_generate_with_custom_port
        ; test_case "custom host" `Quick test_generate_with_custom_host
        ; test_case "to_json v0.3" `Quick test_agent_card_to_json
        ; test_case "json roundtrip" `Quick test_agent_card_json_roundtrip
        ; test_case "from_json invalid" `Quick test_from_json_invalid
        ; test_case "from_json missing fields" `Quick test_from_json_missing_fields
        ; test_case "from_json legacy bindings" `Quick test_from_json_legacy_bindings
        ; test_case "from_json legacy signature" `Quick test_from_json_legacy_signature
        ; test_case "with_bindings" `Quick test_with_bindings
        ; test_case "with_extension" `Quick test_with_extension
        ; test_case "with_extension overwrite" `Quick test_with_extension_overwrite
        ; test_case "show" `Quick test_agent_card_show
        ; test_case "eq" `Quick test_agent_card_eq
        ] )
    ; ( "masc_skills"
      , [ test_case "not empty" `Quick test_masc_skills_not_empty
        ; test_case "have ids" `Quick test_masc_skills_have_ids
        ; test_case "unique ids" `Quick test_masc_skills_unique_ids
        ; test_case "have names" `Quick test_masc_skills_have_names
        ; test_case "expected count" `Quick test_masc_skills_expected_count
        ; test_case "skill id is masc" `Quick test_masc_skill_id_is_masc
        ; test_case "MIME types" `Quick test_masc_skills_mime_types
        ; test_case "have tags" `Quick test_masc_skills_have_tags
        ; test_case "have tool_count" `Quick test_masc_skills_have_tool_count
        ] )
    ; ( "now_iso8601"
      , [ test_case "format" `Quick test_now_iso8601_format
        ; test_case "length" `Quick test_now_iso8601_length
        ] )
    ; ( "edge_cases"
      , [ test_case "default capabilities" `Quick test_default_capabilities
        ; test_case "empty skills" `Quick test_empty_skills
        ; test_case "empty interfaces" `Quick test_empty_interfaces
        ; test_case "empty extensions" `Quick test_empty_extensions
        ; test_case "signatures empty" `Quick test_signatures_empty
        ; test_case "signatures set" `Quick test_signatures_set
        ; test_case "optional fields" `Quick test_optional_fields
        ] )
    ]
;;
