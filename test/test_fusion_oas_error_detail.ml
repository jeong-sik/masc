open Masc

let test_rewrites_unknown_provider () =
  let detail =
    Fusion_oas.provider_error_detail ~runtime_id:"ollama_cloud.kimi-k2-6"
      "Provider 'unknown' timeout phase=http_operation: HTTP operation exceeded wall-clock timeout"
  in
  Alcotest.(check string)
    "unknown provider replaced with runtime id"
    "Provider 'ollama_cloud.kimi-k2-6' timeout phase=http_operation: HTTP operation exceeded wall-clock timeout"
    detail
;;

let test_prefixes_unattributed_provider_error () =
  let detail =
    Fusion_oas.provider_error_detail ~runtime_id:"ollama_cloud.minimax-m3"
      "HTTP 503 from provider"
  in
  Alcotest.(check string)
    "runtime context prefixed"
    "ollama_cloud.minimax-m3: HTTP 503 from provider"
    detail
;;

let test_keeps_already_attributed_error () =
  let detail =
    Fusion_oas.provider_error_detail ~runtime_id:"ollama_cloud.minimax-m3"
      "Provider 'ollama_cloud.minimax-m3' timeout phase=http_operation"
  in
  Alcotest.(check string)
    "already attributed"
    "Provider 'ollama_cloud.minimax-m3' timeout phase=http_operation"
    detail
;;

let () =
  Alcotest.run
    "Fusion_oas_error_detail"
    [ ( "provider attribution"
      , [ Alcotest.test_case
            "rewrites unknown provider"
            `Quick
            test_rewrites_unknown_provider
        ; Alcotest.test_case
            "prefixes unattributed provider error"
            `Quick
            test_prefixes_unattributed_provider_error
        ; Alcotest.test_case
            "keeps already attributed error"
            `Quick
            test_keeps_already_attributed_error
        ] )
    ]
;;
