open Alcotest
module Msp = Runtime_muse_msp
module Discovery = Runtime_muse_model_discovery

let ok = function Ok value -> value | Error error -> fail (Msp.error_to_string error)
let fields = function `Assoc fields -> fields | _ -> fail "object expected"

let row =
  `Assoc [ "modelId", `String "vendor-model"; "displayLabel", `String "Vendor model"
         ; "providerId", `String "meta"; "profileId", `Null
         ; "contextLimit", `Int 321000; "outputLimit", `Null
         ; "isDefault", `Bool true; "isActive", `Bool false
         ; "cost", `Null; "description", `Null; "releaseDate", `Null
         ; "variants", `List [ `String "none"; `String "high" ] ]

let catalog ?(source = "providerCatalog") models =
  `Assoc [ "source", `String source; "providerId", `String "meta"
         ; "profileId", `Null; "models", `List models ]

let test_sources_and_projection () =
  List.iter (fun source ->
    let decoded = Msp.parse_model_list_result (catalog ~source [row]) |> ok in
    check string "catalog source retained" source
      (Msp.model_catalog_source_to_string decoded.source);
    let json = Discovery.to_json decoded in
    let open Yojson.Safe.Util in
    check string "projected source retained" source (json |> member "source" |> to_string);
    check bool "listing is not account evidence" false
      (json |> member "account_availability_verified" |> to_bool);
    check bool "listing is not model invocation" false
      (json |> member "invocation_verified" |> to_bool);
    let first = json |> member "models" |> to_list |> List.hd in
    check int "reported context unchanged" 321000 (first |> member "context" |> to_int);
    check bool "unreported output remains null" true (first |> member "output_limit" = `Null);
    check (list string) "ordered closed reasoning tiers" ["none"; "high"]
      (first |> member "reasoning_effort_variants" |> to_list |> List.map to_string))
    ["providerCatalog"; "fakeCatalog"; "unresolvedCatalog"; "bundledCatalog";
     "configCatalog"; "futureCatalog"]
;;

let test_nullable_limits_and_old_host () =
  let row = `Assoc (fields row |> List.remove_assoc "variants"
    |> List.map (fun (key,value) -> if key="contextLimit" then key,`Null else key,value)) in
  let decoded = Msp.parse_model_list_result (catalog [row]) |> ok in
  match decoded.models with
  | [model] ->
    check bool "missing context isn't guessed" true (model.context_limit=None);
    check bool "old host effort metadata unknown" true (model.variants=Msp.Unknown_efforts)
  | _ -> fail "one model expected"
;;

let test_malformed_model_metadata () =
  let rejected altered = check bool "malformed row refused" true
    (Result.is_error (Msp.parse_model_list_result (catalog [altered]))) in
  rejected (`Assoc (List.remove_assoc "contextLimit" (fields row)));
  List.iter (fun variants -> rejected (`Assoc
    (("variants", variants) :: List.remove_assoc "variants" (fields row))))
    [`Null; `String "UNKNOWN"; `List [`String "invented"]];
  let empty = Msp.parse_model_list_result (catalog []) |> ok in
  check int "empty catalog is valid metadata" 0 (List.length empty.models)
;;

let write path body =
  let out = open_out_gen [Open_creat; Open_excl; Open_wronly; Open_binary] 0o600 path in
  Fun.protect ~finally:(fun () -> close_out_noerr out) (fun () -> output_string out body)
;;

let test_selected_account_metadata_without_session () =
  let root = Filename.temp_dir ~perms:0o700 "muse-model-list-test-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let account_home = Filename.concat root "account" in
    Fs_compat.mkdir_p (Filename.concat account_home ".config/muse");
    write (Filename.concat account_home ".config/muse/auth.json")
      {|{"schema_version":1,"providers":{"meta":{"api_key":"SYNTHETIC-LOCAL-ONLY"}}}|};
    let capture = Filename.concat root "requests.jsonl" in
    let initialization =
      {|{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"fixture","version":"1.4.0"},"userAgent":"fixture","museHome":"fixture","sessionDurability":"ephemeral","schema":{"version":1,"fingerprint":"fixture"},"grantedCapabilities":[]}}|} in
    let listed = `Assoc ["jsonrpc",`String "2.0"; "id",`Int 2;
      "result",catalog ~source:"fakeCatalog" [row]] |> Yojson.Safe.to_string in
    let read = "IFS= read -r line || exit 90\nprintf '%s\\n' \"$line\" >> " ^ Filename.quote capture ^ "\n" in
    let emit value = "printf '%s\\n' " ^ Filename.quote value ^ "\n" in
    write (Filename.concat root "serve")
      ("#!/bin/sh\n[ \"$HOME\" = " ^ Filename.quote account_home ^ " ] || exit 91\n"
       ^ "[ \"$XDG_CONFIG_HOME\" != \"$HOME/.config\" ] || exit 92\n"
       ^ "[ \"$TMPDIR\" = \"$XDG_CONFIG_HOME/tmp\" ] || exit 93\n"
       ^ read ^ emit initialization ^ read ^ read ^ emit listed
       ^ "while IFS= read -r ignored; do :; done\n");
    let result = Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      let mgr = Posix_spawn_process_mgr.foreground_mgr ~clock
        ~grace_seconds:Process_eio.child_exit_grace_seconds in
      Discovery.run ~mgr ~clock ~cwd:Eio.Path.(Eio.Stdenv.fs env / root)
        ~account_home ~cli_path:"/bin/sh" ~timeout_s:10.) in
    (match result with
     | Error error -> fail (Runtime_muse_serve.error_to_string error)
     | Ok json -> check string "fake catalog remains fake" "fakeCatalog"
         Yojson.Safe.Util.(json |> member "source" |> to_string));
    let requests = Fs_compat.load_file capture |> String.split_on_char '\n'
      |> List.filter (fun line -> line<>"") |> List.map Yojson.Safe.from_string in
    check (list string) "only metadata protocol, no session or model call"
      ["initialize"; "initialized"; "model/list"]
      (List.map (fun json -> Yojson.Safe.Util.(json |> member "method" |> to_string)) requests);
    match List.rev requests with
    | query :: _ ->
      check bool "query has no command or session identity" true
        (Yojson.Safe.Util.member "params" query = `Assoc [])
    | [] -> fail "model query missing")
;;

let () = run "Muse model discovery"
  [ "metadata", [test_case "source and projection" `Quick test_sources_and_projection
                ; test_case "nullable and old host" `Quick test_nullable_limits_and_old_host
                ; test_case "malformed metadata" `Quick test_malformed_model_metadata]
  ; "transport", [test_case "selected account metadata without session" `Quick
                    test_selected_account_metadata_without_session] ]
