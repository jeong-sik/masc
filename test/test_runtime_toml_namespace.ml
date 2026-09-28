(* #39539: a provider's bindings are a top-level table named after its id, so
   a provider may not be called by the name of a table another reader owns.
   Before, only eleven names were refused and [voice], [tui], [turn] or
   [fusion] loaded as a provider whose bindings sat in that reader's table. *)

module Ns = Runtime_toml_namespace

let provider_named name =
  Printf.sprintf
    {|[providers.%s]
display-name = "Named after a table"
protocol = "openai-compatible-http"
endpoint = "https://example.invalid/v1"
|}
    name

let refused_at path errors =
  List.exists (fun (e : Runtime_toml.parse_error) -> e.path = path) errors

let test_no_provider_takes_a_table_another_reader_owns () =
  let names =
    List.map Ns.key Ns.all @ Keeper_runtime_config.owned_namespaces
  in
  Alcotest.(check bool) "the keeper settings' tables are among them" true
    (List.mem "turn" names && List.mem "keeper_settings" names);
  List.iter
    (fun name ->
      match Runtime_toml.parse_string (provider_named name) with
      | Ok _ -> Alcotest.failf "a provider called %s was accepted" name
      | Error errors ->
        Alcotest.(check bool)
          (Printf.sprintf "%s is refused as a provider id" name)
          true
          (refused_at ("providers." ^ name) errors))
    names

(* The same declaration under a name nobody reads loads, so the refusals
   above are about the name. *)
let test_a_name_no_reader_owns_is_a_provider () =
  match Runtime_toml.parse_string (provider_named "codex_second") with
  | Ok _ -> ()
  | Error errors ->
    Alcotest.failf "a plain provider id was refused: %s"
      (String.concat "; "
         (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errors))

(* A model id sits under [models] and inside [<provider>.<model>], and an SSH
   endpoint under [exec.ssh.endpoints]; neither is a top-level table, so a
   table's name is theirs to use. [vision] is a keeper-settings namespace and
   a model id existing fixtures and scripts already declare. *)
let test_model_and_endpoint_ids_may_share_a_table_name () =
  let content =
    {|[models.vision]
api-name = "vision-model"
max-context = 1024

[models.turn]
api-name = "turn-model"
max-context = 1024

[exec.ssh.endpoints.sandbox]
host = "builder.local"
user = "masc-exec"
remote_root = "/srv/masc/playground"
|}
  in
  match Runtime_toml.parse_string content with
  | Ok _ -> ()
  | Error errors ->
    Alcotest.failf "model or endpoint ids named after a table were refused: %s"
      (String.concat "; "
         (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errors))

let test_each_table_has_one_spelling () =
  let keys = List.map Ns.key Ns.all in
  Alcotest.(check int) "no two tables share a spelling" (List.length keys)
    (List.length (List.sort_uniq String.compare keys));
  List.iter
    (fun table ->
      Alcotest.(check bool) (Ns.key table ^ " reads back") true
        (Ns.of_key (Ns.key table) = Some table))
    Ns.all;
  Alcotest.(check bool) "another name is no table" true (Ns.of_key "codex_second" = None);
  Alcotest.(check string) "a path under a table" "runtime.lanes" (Ns.(path Runtime) "lanes")

let () =
  Alcotest.run "runtime_toml_namespace"
    [ ( "namespaces"
      , [ Alcotest.test_case "no provider takes a table another reader owns" `Quick
            test_no_provider_takes_a_table_another_reader_owns
        ; Alcotest.test_case "a name no reader owns is a provider" `Quick
            test_a_name_no_reader_owns_is_a_provider
        ; Alcotest.test_case "model and endpoint ids may share a table name" `Quick
            test_model_and_endpoint_ids_may_share_a_table_name
        ; Alcotest.test_case "each table has one spelling" `Quick
            test_each_table_has_one_spelling
        ] )
    ]
