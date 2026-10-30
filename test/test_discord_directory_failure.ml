(* The directory refresh classifies REST failures to decide what is worth
   retrying. A deleted channel (10003) is the one permanent verdict — the
   refresh loop skips it until restart — so a regression that quietly folds
   it back into the retryable bucket matters. *)

open Alcotest
open Masc

module G = Server_discord_in_process_gateway

let api ~http_status ~code =
  Discord_rest_client.Discord_api { request_id = "test"; http_status; code }
;;

let http code = Discord_rest_client.Http_status { request_id = "test"; code; body_bytes = 0 } ;;

let verdict : G.directory_rest_failure testable =
  let pp fmt = function
    | G.Directory_authentication_failed -> Format.fprintf fmt "authentication"
    | G.Directory_permission_denied -> Format.fprintf fmt "permission"
    | G.Directory_channel_gone -> Format.fprintf fmt "gone"
    | G.Directory_operation_failed -> Format.fprintf fmt "operation"
  in
  testable pp ( = )
;;

let test_classification () =
  check verdict "deleted channel (10003) is the permanent verdict"
    G.Directory_channel_gone
    (G.classify_directory_rest_failure (api ~http_status:404 ~code:10003));
  check verdict "401 is authentication" G.Directory_authentication_failed
    (G.classify_directory_rest_failure (api ~http_status:401 ~code:0));
  check verdict "missing access (50001) is permission" G.Directory_permission_denied
    (G.classify_directory_rest_failure (api ~http_status:403 ~code:50001));
  check verdict "other API codes stay retryable" G.Directory_operation_failed
    (G.classify_directory_rest_failure (api ~http_status:500 ~code:0));
  check verdict "bare HTTP 403 is permission" G.Directory_permission_denied
    (G.classify_directory_rest_failure (http 403));
  check verdict "bare HTTP 500 stays retryable" G.Directory_operation_failed
    (G.classify_directory_rest_failure (http 500))
;;

let () =
  run "discord_directory_failure"
    [ ( "classification"
      , [ test_case "directory rest failure classification" `Quick test_classification ] ) ]
;;
