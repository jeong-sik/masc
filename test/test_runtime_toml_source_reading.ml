(* [Runtime_toml.parse_string] and [Runtime_toml.parse_file] answer the same
   source text under the same home with the reading already made, and read
   again when either one differs. *)

open Alcotest

let source ~endpoint =
  Printf.sprintf
    {|
[providers.p]
protocol = "openai-compatible-http"
endpoint = "%s"

[providers.p.credentials]
type = "file"
path = "~/provider-key"

[models.m]

[runtime]
default = "p.m"
|}
    endpoint
;;

let first_source = source ~endpoint:"https://one.example.invalid/v1"
let second_source = source ~endpoint:"https://two.example.invalid/v1"

let errors_line errors =
  String.concat
    "; "
    (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errors)
;;

let loaded = function
  | Ok (config : Runtime_schema.config) -> config
  | Error errors -> failf "expected the config to load: %s" (errors_line errors)
;;

let refused = function
  | Ok (_ : Runtime_schema.config) -> fail "expected the config to be refused, it loaded"
  | Error errors -> errors
;;

let provider_endpoint (config : Runtime_schema.config) =
  match (List.find (fun (p : Runtime_schema.provider) -> p.id = "p") config.providers).transport with
  | Runtime_schema.Http endpoint -> endpoint
  | Runtime_schema.Cli _ -> fail "the provider is not an HTTP one"
;;

let credential_path (config : Runtime_schema.config) =
  match (List.find (fun (p : Runtime_schema.provider) -> p.id = "p") config.providers).credentials with
  | Some (Runtime_schema.File path) -> path
  | Some (Runtime_schema.Env _ | Runtime_schema.Inline _) | None ->
    fail "the provider has no file credential"
;;

let with_home home run =
  let before = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" home;
  Fun.protect run ~finally:(fun () -> Unix.putenv "HOME" (Option.value before ~default:""))
;;

let with_temp_file run =
  let path = Filename.temp_file "runtime-toml-source-reading" ".toml" in
  Fun.protect (fun () -> run path) ~finally:(fun () -> Sys.remove path)
;;

let save path content = Out_channel.with_open_bin path (fun oc -> output_string oc content)

let test_same_text_keeps_its_reading () =
  with_home "/home/one"
  @@ fun () ->
  let first = loaded (Runtime_toml.parse_string first_source) in
  check bool "the same text answers with the config already built" true
    (loaded (Runtime_toml.parse_string first_source) == first);
  let second = loaded (Runtime_toml.parse_string second_source) in
  check string "another text is read" "https://two.example.invalid/v1" (provider_endpoint second);
  check string "and the earlier text is read again after it" "https://one.example.invalid/v1"
    (provider_endpoint (loaded (Runtime_toml.parse_string first_source)))
;;

let test_another_home_is_read_again () =
  let under home =
    with_home home (fun () -> credential_path (loaded (Runtime_toml.parse_string first_source)))
  in
  check string "the path expands under the home" "/home/one/provider-key" (under "/home/one");
  check string "the same text under another home expands under that one"
    "/home/two/provider-key" (under "/home/two")
;;

let test_file_and_string_share_the_reading () =
  with_home "/home/one"
  @@ fun () ->
  with_temp_file
  @@ fun path ->
  save path first_source;
  let from_file = loaded (Runtime_toml.parse_file path) in
  check bool "the file read again answers with the config already built" true
    (loaded (Runtime_toml.parse_file path) == from_file);
  check bool "the same text as a string answers with it too" true
    (loaded (Runtime_toml.parse_string first_source) == from_file);
  save path second_source;
  check string "an edit is read by the next call" "https://two.example.invalid/v1"
    (provider_endpoint (loaded (Runtime_toml.parse_file path)))
;;

(* A syntax failure is kept like any reading, and each entry point words it
   its own way whichever one met the text first. *)
let test_syntax_failure_keeps_each_wording () =
  with_temp_file
  @@ fun path ->
  let broken = "[providers.p\n" in
  save path broken;
  let file_errors () = refused (Runtime_toml.parse_file path) in
  let string_errors () = refused (Runtime_toml.parse_string broken) in
  let check_file label =
    match file_errors () with
    | [ error ] ->
      check string (label ^ ": the file's failure names the file") path error.path;
      check bool (label ^ ": and carries no position prefix") false
        (String.starts_with ~prefix:"Syntax error on line" error.message)
    | errors -> failf "%s: expected one error, got: %s" label (errors_line errors)
  in
  let check_string label =
    match string_errors () with
    | [ error ] ->
      check string (label ^ ": the string's failure has no file") "<parse>" error.path;
      check bool (label ^ ": and says where it is") true
        (String.starts_with ~prefix:"Syntax error on line" error.message)
    | errors -> failf "%s: expected one error, got: %s" label (errors_line errors)
  in
  check_file "file first";
  check_string "string after the file";
  check_file "file after the string"
;;

let test_unreadable_file_is_an_error () =
  with_temp_file
  @@ fun path ->
  Sys.remove path;
  let result = Runtime_toml.parse_file path in
  save path "";
  match refused result with
  | [ error ] -> check string "the failure names the file" path error.path
  | errors -> failf "expected one error, got: %s" (errors_line errors)
;;

let () =
  run
    "runtime_toml_source_reading"
    [ ( "the reading of the last source text"
      , [ test_case "the same text keeps its reading" `Quick test_same_text_keeps_its_reading
        ; test_case "another home is read again" `Quick test_another_home_is_read_again
        ; test_case "a file and a string share the reading" `Quick
            test_file_and_string_share_the_reading
        ; test_case "a syntax failure keeps each wording" `Quick
            test_syntax_failure_keeps_each_wording
        ; test_case "an unreadable file is an error" `Quick test_unreadable_file_is_an_error
        ] )
    ]
;;
