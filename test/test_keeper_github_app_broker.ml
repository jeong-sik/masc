(** RFC keeper-github-apps: installation-token broker unit contract. *)
open Alcotest
module Broker = Masc.Keeper_github_app_broker

let () = Mirage_crypto_rng_unix.use_default ()

let temp_dir () =
  let path = Filename.temp_file "github_app_broker_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let write path content =
  Fs_compat.mkdir_p (Filename.dirname path);
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let read path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let content = really_input_string ic n in
  close_in ic;
  content
;;

let test_rsa_key () =
  Mirage_crypto_pk.Rsa.generate ~bits:2048 ()
;;

let pem_of_key key =
  X509.Private_key.encode_pem (`RSA key)
;;

(* ── JWT ─────────────────────────────────────────────────────────────── *)

let b64url_decode segment =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet segment with
  | Ok value -> value
  | Error (`Msg msg) -> fail ("b64url: " ^ msg)
;;

let test_jwt_shape_and_signature () =
  let key = test_rsa_key () in
  let now = 1_700_000_000. in
  match
    Broker.For_testing.jwt_rs256
      ~now
      ~app_id:"12345"
      ~private_key_pem:(pem_of_key key)
  with
  | Error err -> fail err
  | Ok jwt ->
    (match String.split_on_char '.' jwt with
     | [ header; payload; signature ] ->
       let header_json = Yojson.Safe.from_string (b64url_decode header) in
       check string
         "alg is RS256"
         "RS256"
         (Yojson.Safe.Util.(header_json |> member "alg" |> to_string));
       let payload_json = Yojson.Safe.from_string (b64url_decode payload) in
       let field name =
         Yojson.Safe.Util.(payload_json |> member name)
       in
       check string "iss carries the app id" "12345"
         (Yojson.Safe.Util.to_string (field "iss"));
       check int "iat is backdated a minute"
         (int_of_float now - 60)
         (Yojson.Safe.Util.to_int (field "iat"));
       check int "exp is nine minutes out"
         (int_of_float now + 540)
         (Yojson.Safe.Util.to_int (field "exp"));
       let verified =
         Mirage_crypto_pk.Rsa.PKCS1.verify
           ~hashp:(fun hash -> hash = `SHA256)
           ~key:(Mirage_crypto_pk.Rsa.pub_of_priv key)
           ~signature:(b64url_decode signature)
           (`Message (header ^ "." ^ payload))
       in
       check bool "signature verifies against the public key" true verified
     | _ -> fail "jwt is not three dot-joined segments")
;;

let test_jwt_rejects_non_rsa_pem () =
  match
    Broker.For_testing.jwt_rs256
      ~now:0.
      ~app_id:"1"
      ~private_key_pem:"not a pem at all"
  with
  | Ok _ -> fail "garbage PEM produced a JWT"
  | Error _ -> ()
;;

(* ── Mint response ───────────────────────────────────────────────────── *)

let test_parse_mint_response () =
  (match
     Broker.For_testing.parse_mint_response
       {|{"token":"ghs_abc","expires_at":"2026-08-29T13:00:00Z"}|}
   with
   | Ok (token, expires_at) ->
     check string "token" "ghs_abc" token;
     check bool "expiry parsed to a positive epoch" true (expires_at > 0.)
   | Error err -> fail err);
  (match Broker.For_testing.parse_mint_response {|{"token":"ghs_abc"}|} with
   | Ok _ -> fail "missing expires_at was accepted"
   | Error _ -> ());
  (match Broker.For_testing.parse_mint_response "not json" with
   | Ok _ -> fail "non-JSON was accepted"
   | Error _ -> ())
;;

(* ── ensure_fresh flow ───────────────────────────────────────────────── *)

let with_workspace f =
  let dir = temp_dir () in
  Unix.putenv "MASC_BASE_PATH" dir;
  let config = Masc.Workspace.default_config dir in
  ignore (Masc.Workspace.init config ~agent_name:(Some "test"));
  f config
;;

let credentials_dir config keeper_name =
  List.fold_left
    Filename.concat
    (Masc.Workspace.keepers_runtime_dir config)
    [ keeper_name; "github-app" ]
;;

let install_credentials config keeper_name =
  let dir = credentials_dir config keeper_name in
  write (Filename.concat dir "app-id") "12345\n";
  write (Filename.concat dir "installation-id") "67890\n";
  write (Filename.concat dir "private-key.pem") (pem_of_key (test_rsa_key ()))
;;

let stub_http ~calls ?(status = 201) ?body () : Broker.http_post =
  fun ~url ~headers:_ ~body:_ ->
    incr calls;
    check bool
      "mint URL targets the installation"
      true
      (url = "https://api.github.com/app/installations/67890/access_tokens");
    Ok
      ( status
      , Option.value
          body
          ~default:{|{"token":"ghs_test","expires_at":"2999-01-01T00:00:00Z"}|}
      )
;;

let test_no_app_identity_is_untouched () =
  with_workspace
  @@ fun config ->
  let calls = ref 0 in
  match
    Broker.ensure_fresh
      ~now:0.
      ~http_post:(stub_http ~calls ())
      ~config
      ~keeper_name:"plain-keeper"
  with
  | Ok Broker.No_app_identity -> check int "no HTTP call" 0 !calls
  | Ok _ -> fail "keeper without credentials reported a token state"
  | Error err -> fail err
;;

let test_mint_writes_projection_then_stays_fresh () =
  with_workspace
  @@ fun config ->
  let keeper_name = "app-keeper" in
  install_credentials config keeper_name;
  let calls = ref 0 in
  let http = stub_http ~calls () in
  (match Broker.ensure_fresh ~now:1000. ~http_post:http ~config ~keeper_name with
   | Ok (Broker.Refreshed _) -> ()
   | Ok _ -> fail "first call must mint"
   | Error err -> fail err);
  check int "exactly one mint" 1 !calls;
  let hosts =
    read
      (Filename.concat
         (Masc.Keeper_github_identity.config_dir ~config ~keeper_name)
         "hosts.yml")
  in
  check bool "hosts carries the minted token" true
    (String_util.contains_substring hosts "oauth_token: ghs_test");
  check bool "hosts names the keeper bot login" true
    (String_util.contains_substring hosts "user: app-keeper[bot]");
  (* Second call inside the token lifetime touches nothing. *)
  (match Broker.ensure_fresh ~now:2000. ~http_post:http ~config ~keeper_name with
   | Ok (Broker.Fresh _) -> ()
   | Ok _ -> fail "fresh token was re-minted or dropped"
   | Error err -> fail err);
  check int "no second mint while fresh" 1 !calls
;;

let test_stale_token_is_reminted_and_mint_failure_is_closed () =
  with_workspace
  @@ fun config ->
  let keeper_name = "app-keeper-stale" in
  install_credentials config keeper_name;
  let calls = ref 0 in
  (* Expiry in the past forces a mint; a 401 mint is a hard error. *)
  write
    (Filename.concat (credentials_dir config keeper_name)
       "installation-token-expires-at")
    "500\n";
  (match
     Broker.ensure_fresh
       ~now:1000.
       ~http_post:(stub_http ~calls ~status:401 ~body:{|{"message":"bad"}|} ())
       ~config
       ~keeper_name
   with
   | Error _ -> ()
   | Ok _ -> fail "failed mint on a stale token was not an error");
  check int "mint was attempted" 1 !calls;
  (match
     Broker.ensure_fresh
       ~now:1000.
       ~http_post:(stub_http ~calls ())
       ~config
       ~keeper_name
   with
   | Ok (Broker.Refreshed { expires_at }) ->
     check bool "expiry moved into the future" true (expires_at > 1000.)
   | Ok _ -> fail "stale token was not re-minted"
   | Error err -> fail err)
;;

let () =
  run
    "keeper_github_app_broker"
    [ ( "jwt"
      , [ test_case "shape and RS256 signature" `Quick test_jwt_shape_and_signature
        ; test_case "garbage PEM is refused" `Quick test_jwt_rejects_non_rsa_pem
        ] )
    ; ( "mint"
      , [ test_case "response parsing" `Quick test_parse_mint_response ] )
    ; ( "ensure_fresh"
      , [ test_case "no app identity is untouched" `Quick test_no_app_identity_is_untouched
        ; test_case
            "mint writes the projection then stays fresh"
            `Quick
            test_mint_writes_projection_then_stays_fresh
        ; test_case
            "stale token re-mints and a failed mint closes"
            `Quick
            test_stale_token_is_reminted_and_mint_failure_is_closed
        ] )
    ]
;;
