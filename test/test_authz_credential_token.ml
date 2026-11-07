(* Checks for the text of a PAT and of a Service credential: what a drawn token
   writes, that it reads back, the digest of its secret, and every text that is
   not a token of masc. No files, clock, or network. *)

open Authz_types
module T = Authz_credential_token

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let pat_of text = get (Pat_id.of_string text)
let credential_of text = get (Service_credential_id.of_string text)
let sha text = Agent_core_sha256.to_hex (Agent_core_sha256.digest_string text)
let secret = String.make 64 'a'
let other_secret = String.make 64 'b'

(* The secret is the last 64 characters of the text. *)
let secret_of text = String.sub text (String.length text - 64) 64

let pat_token text =
  match T.read text with
  | T.Pat_token token -> token
  | T.Service_credential_token _
  | T.Pat_malformed
  | T.Service_credential_malformed
  | T.No_prefix -> Alcotest.failf "%S is not read as a PAT" text
;;

let service_token text =
  match T.read text with
  | T.Service_credential_token token -> token
  | T.Pat_token _ | T.Pat_malformed | T.Service_credential_malformed | T.No_prefix ->
    Alcotest.failf "%S is not read as a Service credential" text
;;

type shape =
  | Is_pat
  | Is_service
  | Bad_pat
  | Bad_service
  | Not_prefixed

let shape_of text =
  match T.read text with
  | T.Pat_token _ -> Is_pat
  | T.Service_credential_token _ -> Is_service
  | T.Pat_malformed -> Bad_pat
  | T.Service_credential_malformed -> Bad_service
  | T.No_prefix -> Not_prefixed
;;

let shape_to_string = function
  | Is_pat -> "a PAT"
  | Is_service -> "a Service credential"
  | Bad_pat -> "a malformed PAT"
  | Bad_service -> "a malformed Service credential"
  | Not_prefixed -> "no prefix"
;;

let shape = Alcotest.testable (fun ppf s -> Format.pp_print_string ppf (shape_to_string s)) ( = )

(* ---- a drawn token ---- *)

let a_drawn_pat_reads_back () =
  let id = pat_of "pat-1" in
  let token = T.Pat.draw id in
  let text = T.Pat.to_string token in
  Alcotest.(check bool) "prefix" true (String.starts_with ~prefix:"mpat_pat-1." text);
  Alcotest.(check int) "length" (String.length "mpat_pat-1." + 64) (String.length text);
  Alcotest.(check bool)
    "lowercase hex secret"
    true
    (String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       (secret_of text));
  let back = pat_token text in
  Alcotest.(check string) "id" "pat-1" (Pat_id.to_string (T.Pat.id back));
  Alcotest.(check bool)
    "digest"
    true
    (T.Pat.Digest.equal (T.Pat.secret_digest token) (T.Pat.secret_digest back));
  Alcotest.(check string) "text" text (T.Pat.to_string back)
;;

let a_drawn_service_credential_reads_back () =
  let id = credential_of "keeper-runner-1" in
  let token = T.Service_credential.draw id in
  let text = T.Service_credential.to_string token in
  Alcotest.(check bool) "prefix" true (String.starts_with ~prefix:"msvc_keeper-runner-1." text);
  let back = service_token text in
  Alcotest.(check string)
    "id"
    "keeper-runner-1"
    (Service_credential_id.to_string (T.Service_credential.id back));
  Alcotest.(check bool)
    "digest"
    true
    (T.Service_credential.Digest.equal
       (T.Service_credential.secret_digest token)
       (T.Service_credential.secret_digest back))
;;

let two_draws_have_two_secrets () =
  let id = pat_of "pat-1" in
  let first = T.Pat.to_string (T.Pat.draw id) in
  let second = T.Pat.to_string (T.Pat.draw id) in
  Alcotest.(check bool) "secrets differ" false (String.equal (secret_of first) (secret_of second))
;;

(* The secret is the last 64 characters, so a [.] in the id reads back. *)
let an_id_with_a_dot_reads_back () =
  let token = pat_token ("mpat_team.ci.1." ^ secret) in
  Alcotest.(check string) "id" "team.ci.1" (Pat_id.to_string (T.Pat.id token));
  let token = service_token ("msvc_a.b." ^ secret) in
  Alcotest.(check string) "service id" "a.b" (Service_credential_id.to_string (T.Service_credential.id token))
;;

(* ---- the digest ---- *)

let the_digest_carries_its_label () =
  let token = pat_token ("mpat_pat-1." ^ secret) in
  let digest = T.Pat.Digest.to_hex (T.Pat.secret_digest token) in
  Alcotest.(check string) "PAT label" "masc-authz-pat-secret-v1\n" T.Pat.digest_label;
  Alcotest.(check string) "labelled" (sha ("masc-authz-pat-secret-v1\n" ^ secret)) digest;
  Alcotest.(check bool) "not the bare hash" false (String.equal (sha secret) digest);
  let service = service_token ("msvc_pat-1." ^ secret) in
  let service_digest =
    T.Service_credential.Digest.to_hex (T.Service_credential.secret_digest service)
  in
  Alcotest.(check string)
    "Service label"
    "masc-authz-service-credential-secret-v1\n"
    T.Service_credential.digest_label;
  Alcotest.(check string)
    "service labelled"
    (sha ("masc-authz-service-credential-secret-v1\n" ^ secret))
    service_digest;
  (* The same secret under the two labels gives two digests. *)
  Alcotest.(check bool) "kinds differ" false (String.equal digest service_digest);
  (* The id is not hashed: the record holds the id beside the digest. *)
  let other_id = pat_token ("mpat_pat-2." ^ secret) in
  Alcotest.(check string)
    "same secret, other id"
    digest
    (T.Pat.Digest.to_hex (T.Pat.secret_digest other_id));
  let other = pat_token ("mpat_pat-1." ^ other_secret) in
  Alcotest.(check bool)
    "other secret"
    false
    (T.Pat.Digest.equal (T.Pat.secret_digest token) (T.Pat.secret_digest other))
;;

let the_hex_of_a_digest () =
  let digest = T.Pat.secret_digest (pat_token ("mpat_pat-1." ^ secret)) in
  let hex = T.Pat.Digest.to_hex digest in
  (match T.Pat.Digest.of_hex hex with
   | Some back -> Alcotest.(check bool) "reads back" true (T.Pat.Digest.equal digest back)
   | None -> Alcotest.fail "the hex of a digest is refused");
  List.iter
    (fun (name, text) ->
       Alcotest.(check bool) name true (Option.is_none (T.Pat.Digest.of_hex text));
       Alcotest.(check bool)
         ("service " ^ name)
         true
         (Option.is_none (T.Service_credential.Digest.of_hex text)))
    [ "upper case", String.uppercase_ascii hex
    ; "one short", String.sub hex 0 63
    ; "one long", hex ^ "0"
    ; "not hex", String.make 64 'g'
    ; "empty", ""
    ]
;;

(* ---- texts that are not a token ---- *)

let malformed_texts () =
  List.iter
    (fun (name, text, expected) -> Alcotest.check shape name expected (shape_of text))
    [ "the prefix alone", "mpat_", Bad_pat
    ; "no id", "mpat_." ^ secret, Bad_pat
    ; "no dot", "mpat_pat-1" ^ secret, Bad_pat
    ; "secret one short", "mpat_pat-1." ^ String.sub secret 0 63, Bad_pat
    ; "secret in upper case", "mpat_pat-1." ^ String.uppercase_ascii secret, Bad_pat
    ; "secret not hex", "mpat_pat-1." ^ String.make 64 'g', Bad_pat
    ; "a byte outside the id alphabet", "mpat_pat/1." ^ secret, Bad_pat
    ; "a path segment", "mpat_..." ^ secret, Bad_pat
    ; "an id too long", "mpat_" ^ String.make 256 'p' ^ "." ^ secret, Bad_pat
    ; "a space after the secret", "mpat_pat-1." ^ secret ^ " ", Bad_pat
    ; "the service prefix alone", "msvc_", Bad_service
    ; "service no dot", "msvc_svc-1" ^ secret, Bad_service
    ; "service secret not hex", "msvc_svc-1." ^ String.make 64 'z', Bad_service
    ]
;;

let texts_without_a_prefix () =
  List.iter
    (fun (name, text) -> Alcotest.check shape name Not_prefixed (shape_of text))
    [ "a legacy bearer", String.make 64 'f'
    ; "an OAuth access token", "mat_" ^ secret
    ; "an OAuth refresh token", "mrt_family-1." ^ secret
    ; "empty", ""
    ; "the prefix in upper case", "MPAT_pat-1." ^ secret
    ; "a space before the prefix", " mpat_pat-1." ^ secret
    ; "half a prefix", "mpa_pat-1." ^ secret
    ]
;;

(* An id at the longest length Authz_id takes reads back. *)
let the_longest_id () =
  let id = String.make Authz_id.max_length 'p' in
  let token = pat_token ("mpat_" ^ id ^ "." ^ secret) in
  Alcotest.(check string) "id" id (Pat_id.to_string (T.Pat.id token))
;;

let () =
  Alcotest.run
    "authz_credential_token"
    [ ( "drawn"
      , [ Alcotest.test_case "a drawn PAT reads back" `Quick a_drawn_pat_reads_back
        ; Alcotest.test_case
            "a drawn Service credential reads back"
            `Quick
            a_drawn_service_credential_reads_back
        ; Alcotest.test_case "two draws have two secrets" `Quick two_draws_have_two_secrets
        ; Alcotest.test_case "an id with a dot reads back" `Quick an_id_with_a_dot_reads_back
        ; Alcotest.test_case "the longest id" `Quick the_longest_id
        ] )
    ; ( "digest"
      , [ Alcotest.test_case "the digest carries its label" `Quick the_digest_carries_its_label
        ; Alcotest.test_case "the hex of a digest" `Quick the_hex_of_a_digest
        ] )
    ; ( "not a token"
      , [ Alcotest.test_case "malformed texts" `Quick malformed_texts
        ; Alcotest.test_case "texts without a prefix" `Quick texts_without_a_prefix
        ] )
    ]
;;
