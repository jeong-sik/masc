open Alcotest

module Normalize = Masc_mcp.Cascade_config

let normalize = Normalize.normalize_openai_compat_request_path

let () =
  run "normalize_request_path"
    [ ( "exact_prefix_dedup",
        [
          test_case "openai /v1 base + /v1/chat/completions → /chat/completions"
            `Quick
            (fun () ->
              check
                string
                "strips duplicated /v1"
                "/chat/completions"
                (normalize
                   ~base_url:"https://api.openai.com/v1"
                   ~request_path:"/v1/chat/completions"));

          test_case "deep path /a/b/v2 + /v2/chat/completions → /chat/completions"
            `Quick
            (fun () ->
              check
                string
                "strips duplicated deep path"
                "/chat/completions"
                (normalize
                   ~base_url:"https://host.example.com/a/b/v2"
                   ~request_path:"/v2/chat/completions"));
        ] );
      ( "version_collision",
        [
          test_case "z.ai /v4 base + /v1/chat/completions → /chat/completions"
            `Quick
            (fun () ->
              check
                string
                "strips /v1 prefix when base ends with /v4"
                "/chat/completions"
                (normalize
                   ~base_url:"https://api.z.ai/api/coding/paas/v4"
                   ~request_path:"/v1/chat/completions"));

          test_case "ollama_cloud /v1 base + /v1/chat/completions → /chat/completions"
            `Quick
            (fun () ->
              check
                string
                "same version handled by exact_prefix path"
                "/chat/completions"
                (normalize
                   ~base_url:"https://ollama.com/v1"
                   ~request_path:"/v1/chat/completions"));
        ] );
      ( "no_collision",
        [
          test_case "non-versioned base + /v1/chat/completions → unchanged"
            `Quick
            (fun () ->
              check
                string
                "no stripping when base has no version segment"
                "/v1/chat/completions"
                (normalize
                   ~base_url:"https://api.example.com/chat"
                   ~request_path:"/v1/chat/completions"));

          test_case "empty base → unchanged"
            `Quick
            (fun () ->
              check
                string
                "no stripping for empty base"
                "/v1/chat/completions"
                (normalize
                   ~base_url:"https://api.example.com"
                   ~request_path:"/v1/chat/completions"));
        ] );
    ]
