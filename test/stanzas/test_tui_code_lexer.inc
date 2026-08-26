(test
 (name test_tui_code_lexer)
 (modules test_tui_code_lexer)
 ; The toml case reads a declaration the repository ships rather than a sample
 ; written to pass. Declared so dune puts it where the test runs; without this
 ; the file is simply absent there and the test reports it as missing.
 (deps %{workspace_root}/config/tools/masc_keeper_up.toml)
 (libraries alcotest masc_tui_code_lexer))
