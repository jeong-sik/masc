(* The environment a Claude Code child gets on an API key read from a file
   (RFC a-persons-api-key-is-their-own-provider-account 3.4 and 5,
   "environment"). The server of the test has a value of its own under every
   name Claude Code takes a credential, a provider choice or an endpoint
   from; the child gets none of them, and the key of the file once. *)

module Account = Runtime_official_account
module Names = Set.Make (String)

let file_key = "sk-test-file-key"
let api_key = "ANTHROPIC_API_KEY"
let config_dir = "CLAUDE_CONFIG_DIR"

(* What the server has. A child on a declared account inherits none of these
   names. *)
let of_the_server =
  [ api_key
  ; "ANTHROPIC_AUTH_TOKEN"
  ; "ANTHROPIC_BASE_URL"
  ; "ANTHROPIC_CUSTOM_HEADERS"
  ; "ANTHROPIC_MODEL"
  ; "ANTHROPIC_DEFAULT_OPUS_MODEL"
  ; "ANTHROPIC_DEFAULT_SONNET_MODEL"
  ; "ANTHROPIC_DEFAULT_HAIKU_MODEL"
  ; "ANTHROPIC_SMALL_FAST_MODEL"
  ; "CLAUDE_CODE_OAUTH_TOKEN"
  ; "CLAUDE_CODE_USE_BEDROCK"
  ; "CLAUDE_CODE_USE_VERTEX"
  ; "CLAUDE_CODE_USE_FOUNDRY"
  ; "CLAUDE_CODE_USE_MANTLE"
  ; "ANTHROPIC_BEDROCK_BASE_URL"
  ; "ANTHROPIC_VERTEX_BASE_URL"
  ; "ANTHROPIC_VERTEX_PROJECT_ID"
  ; "CLOUD_ML_REGION"
  ; "CLAUDE_CODE_SKIP_BEDROCK_AUTH"
  ; "CLAUDE_CODE_SKIP_VERTEX_AUTH"
  ; "CLAUDE_CODE_SKIP_FOUNDRY_AUTH"
  ; "AWS_ACCESS_KEY_ID"
  ; "AWS_SECRET_ACCESS_KEY"
  ; "AWS_SESSION_TOKEN"
  ; "AWS_REGION"
  ; "AWS_DEFAULT_REGION"
  ; "AWS_PROFILE"
  ; "AWS_CONFIG_FILE"
  ; "AWS_SHARED_CREDENTIALS_FILE"
  ; "AWS_BEARER_TOKEN_BEDROCK"
  ; "GOOGLE_APPLICATION_CREDENTIALS"
  ; "GOOGLE_CLOUD_PROJECT"
  ; "ANTHROPIC_FOUNDRY_API_KEY"
  ; "ANTHROPIC_FOUNDRY_RESOURCE"
  ; "ANTHROPIC_FOUNDRY_BASE_URL"
  ; "AZURE_TENANT_ID"
  ; "AZURE_CLIENT_ID"
  ; "AZURE_CLIENT_SECRET"
  ]
;;

let with_env values run =
  let saved = List.map (fun (name, _) -> name, Sys.getenv_opt name) values in
  let set (name, value) =
    match value with
    | Some value -> Unix.putenv name value
    | None -> Unix.unsetenv name
  in
  Fun.protect
    ~finally:(fun () -> List.iter set saved)
    (fun () ->
      List.iter set values;
      run ())
;;

let with_directory run =
  let path = Unix.realpath (Filename.temp_dir ~perms:0o700 "claude-key-environment-" "") in
  Fun.protect ~finally:(fun () -> Unix.rmdir path) (fun () -> run path)
;;

(* The server: its own value under every name, and the home [home]. *)
let on_the_server ~home ~config_directory run =
  with_env
    ((("HOME", Some home) :: (config_dir, config_directory) :: ("ANTHROPIC_CONFIG_DIR", None)
      :: List.map (fun name -> name, Some ("of-the-server-" ^ name)) of_the_server))
    run
;;

let key =
  match Runtime_api_key_file.key_of_string file_key with
  | Some key -> key
  | None -> Alcotest.fail "fixture key refused"
;;

let environment = function
  | Ok account -> Array.to_list (Account.environment account)
  | Error detail -> Alcotest.failf "the account was not captured: %s" detail
;;

let name_of entry =
  match String.index_opt entry '=' with
  | Some index -> String.sub entry 0 index
  | None -> Alcotest.failf "an entry without a name"
;;

let values name entries =
  let prefix = name ^ "=" in
  List.filter_map
    (fun entry ->
      if String.starts_with ~prefix entry
      then Some (String.sub entry (String.length prefix) (String.length entry - String.length prefix))
      else None)
    entries
;;

(* The key of the file once, nothing else the server had, and no name twice. *)
let only_the_file_key label entries =
  Alcotest.(check (list string)) (label ^ ": the key of the file, once") [ file_key ] (values api_key entries);
  List.iter
    (fun name ->
      if not (String.equal name api_key)
      then Alcotest.(check (list string)) (label ^ ": no " ^ name ^ " of the server") [] (values name entries))
    of_the_server;
  let names = List.map name_of entries in
  Alcotest.(check int)
    (label ^ ": no name twice")
    (List.length names)
    (Names.cardinal (Names.of_list names))
;;

let test_declared () =
  with_directory (fun home ->
    with_directory (fun account_home ->
      on_the_server ~home ~config_directory:None (fun () ->
        let on_key = environment (Account.capture_on_key ~declaration:(Some account_home) ~key) in
        only_the_file_key "a declared home" on_key;
        Alcotest.(check (list string))
          "the home is the declared one"
          [ account_home ]
          (values config_dir on_key);
        (* Beside the key, the child is the child of a login on that home. *)
        let on_login =
          environment (Account.capture ~client:Account.Claude_code ~declaration:(Some account_home))
        in
        Alcotest.(check (list string)) "a login on a declared home has no API key" [] (values api_key on_login);
        Alcotest.(check (list string))
          "the key is all that a key adds"
          (List.sort String.compare ((api_key ^ "=" ^ file_key) :: on_login))
          (List.sort String.compare on_key))))
;;

let test_undeclared () =
  with_directory (fun home ->
    on_the_server ~home ~config_directory:None (fun () ->
      let on_key = environment (Account.capture_on_key ~declaration:None ~key) in
      only_the_file_key "the home of the user" on_key;
      Alcotest.(check (list string)) "the user home stays" [ home ] (values "HOME" on_key);
      Alcotest.(check (list string)) "no directory is chosen for it" [] (values config_dir on_key)))
;;

let test_inherited_directory () =
  with_directory (fun home ->
    with_directory (fun chosen ->
      on_the_server ~home ~config_directory:(Some chosen) (fun () ->
        let on_key = environment (Account.capture_on_key ~declaration:None ~key) in
        only_the_file_key "a directory the server chose" on_key;
        Alcotest.(check (list string))
          "the directory the server chose stays chosen"
          [ chosen ]
          (values config_dir on_key))))
;;

let () =
  Alcotest.run
    "runtime_claude_key_environment"
    [ ( "capture_on_key"
      , [ Alcotest.test_case "on a declared home" `Quick test_declared
        ; Alcotest.test_case "on the home of the user" `Quick test_undeclared
        ; Alcotest.test_case "on a directory the server chose" `Quick test_inherited_directory
        ] )
    ]
;;
