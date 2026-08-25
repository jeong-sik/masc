(* Lsp_message_router.parse_response: the error branch carries ocamllsp's
   [data.exn] beside the bare message, and stays as it was without it. *)

let check_string = Alcotest.(check string)

let parse s = Lsp_message_router.parse_response (Yojson.Safe.from_string s)

let test_an_error_carries_the_exception_under_data () =
  match
    parse
      {|{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"uncaught exception","data":{"exn":"Ocaml_typing.Magic_numbers.Cmi.Error(_)","backtrace":"Raised at ..."}}}|}
  with
  | Some (2, Error msg) ->
    check_string "message and exception" 
      "LSP error for request 2: uncaught exception (Ocaml_typing.Magic_numbers.Cmi.Error(_))"
      msg
  | _ -> Alcotest.fail "expected an error for id 2"
;;

let test_an_error_without_data_keeps_the_message () =
  match
    parse {|{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"Request \"Jump to definition\" failed."}}|}
  with
  | Some (3, Error msg) ->
    check_string "message alone"
      "LSP error for request 3: Request \"Jump to definition\" failed." msg
  | _ -> Alcotest.fail "expected an error for id 3"
;;

let test_data_without_exn_adds_nothing () =
  match
    parse {|{"jsonrpc":"2.0","id":4,"error":{"code":1,"message":"boom","data":{"other":1}}}|}
  with
  | Some (4, Error msg) -> check_string "message alone" "LSP error for request 4: boom" msg
  | _ -> Alcotest.fail "expected an error for id 4"
;;

let () =
  Alcotest.run
    "lsp-message-router"
    [ ( "parse_response"
      , [ Alcotest.test_case "an error carries the exception under data" `Quick
            test_an_error_carries_the_exception_under_data
        ; Alcotest.test_case "an error without data keeps the message" `Quick
            test_an_error_without_data_keeps_the_message
        ; Alcotest.test_case "data without exn adds nothing" `Quick
            test_data_without_exn_adds_nothing
        ] )
    ]
;;
