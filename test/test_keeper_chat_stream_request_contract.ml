(* Pins the POST /api/v1/keepers/chat/stream field allowlist to
   contracts/keeper-chat-stream-request-fields.json, which
   dashboard/src/api/keeper.test.ts reads to check the body it sends stays
   within the set. Without a shared file the two sides drift silently: #26866
   dropped direct_reply from the allowlist while the dashboard kept sending it,
   and every chat POST returned 400 until #26886. *)

open Alcotest

let contract_path = "contracts/keeper-chat-stream-request-fields.json"

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when Sys.file_exists root -> root
  | _ -> Sys.getcwd ()
;;

let contract_fields () =
  let path = Filename.concat (source_root ()) contract_path in
  let ic = open_in_bin path in
  let contents =
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic (in_channel_length ic))
  in
  match Yojson.Safe.from_string contents with
  | `List entries ->
    List.map
      (function
        | `String field -> field
        | other ->
          failf
            "%s: entry is not a string: %s"
            contract_path
            (Yojson.Safe.to_string other))
      entries
  | other ->
    failf
      "%s: not a JSON array: %s"
      contract_path
      (Yojson.Safe.to_string other)
  | exception Yojson.Json_error message ->
    failf "%s: invalid json: %s" contract_path message
;;

(* Order-sensitive: the parser echoes the allowlist verbatim in its rejection
   message, so a reordering changes what an operator reads in the 400 body. *)
let test_contract_file_matches_parser_allowlist () =
  check
    (list string)
    "contract file lists exactly the parser's accepted fields"
    Server_routes_http_keeper_stream.chat_stream_request_fields
    (contract_fields ())
;;

let () =
  run
    "keeper chat stream request contract"
    [ ( "allowlist"
      , [ test_case
            "contract file matches the parser allowlist"
            `Quick
            test_contract_file_matches_parser_allowlist
        ] )
    ]
;;
