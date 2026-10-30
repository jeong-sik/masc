(** Exact [MASC_AGENT_TRANSPORT] admission and process snapshot contract. *)

open Alcotest

module T = Masc_grpc_transport

let with_env value_opt f =
  let name = "MASC_AGENT_TRANSPORT" in
  let previous = Sys.getenv_opt name in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some value -> Unix.putenv name value
      | None -> Unix.unsetenv name)
    (fun () ->
      (match value_opt with
       | Some value -> Unix.putenv name value
       | None -> Unix.unsetenv name);
      f ())
;;

let spelling () = T.from_env () |> T.to_string

let snapshot_entry () =
  Env_config_snapshot.all_categories ()
  |> List.assoc "transport"
  |> Yojson.Safe.Util.to_list
  |> List.find (fun json ->
    String.equal
      (json |> Yojson.Safe.Util.member "env" |> Yojson.Safe.Util.to_string)
      "MASC_AGENT_TRANSPORT")
;;

let accepted_spellings () =
  List.iter
    (fun raw ->
       with_env (Some raw) (fun () -> check string raw raw (spelling ())))
    [ "http"; "grpc"; "ws"; "local" ]
;;

let invalid_values_are_rejected () =
  List.iter
    (fun raw ->
       with_env (Some raw) (fun () ->
         check_raises
           ("reject " ^ raw)
           (Env_config_core.Config_error
              (Printf.sprintf
                 "malformed env MASC_AGENT_TRANSPORT=%S (expected http|grpc|ws|local)"
                 raw))
           (fun () -> ignore (T.from_env ()))))
    [ ""; "gprc"; "websocket"; " GRPC "; "Grpc" ]
;;

let absent_value_selects_local () =
  with_env None (fun () ->
    check string "absent" "local" (spelling ());
    let snapshot = snapshot_entry () in
    check string "default snapshot value" "local"
      (snapshot |> Yojson.Safe.Util.member "value" |> Yojson.Safe.Util.to_string);
    check string "default snapshot source" "default"
      (snapshot |> Yojson.Safe.Util.member "source" |> Yojson.Safe.Util.to_string))
;;

let configured_value_is_stable () =
  with_env (Some "grpc") (fun () ->
    check string "configured" "grpc" (T.configure_from_env () |> T.to_string));
  with_env (Some "local") (fun () ->
    check string "retained" "grpc" (T.from_env () |> T.to_string);
    check string "configure is one-shot" "grpc"
      (T.configure_from_env () |> T.to_string);
    let snapshot = snapshot_entry () in
    check string "snapshot value" "grpc"
      (snapshot |> Yojson.Safe.Util.member "value" |> Yojson.Safe.Util.to_string);
    check string "snapshot source" "env"
      (snapshot |> Yojson.Safe.Util.member "source" |> Yojson.Safe.Util.to_string);
    let provenance = snapshot |> Yojson.Safe.Util.member "provenance" in
    check bool "applied env remains present" true
      (provenance |> Yojson.Safe.Util.member "raw_env_present" |> Yojson.Safe.Util.to_bool);
    check bool "post-boot env is not reread as blank" false
      (provenance |> Yojson.Safe.Util.member "raw_env_blank" |> Yojson.Safe.Util.to_bool))
;;

let () =
  run
    "agent_transport_vocabulary"
    [ ( "vocabulary"
      , [ test_case "accepted values" `Quick accepted_spellings
        ; test_case "invalid present values fail" `Quick invalid_values_are_rejected
        ; test_case "absent selects local" `Quick absent_value_selects_local
        ; test_case "configured value is retained" `Quick configured_value_is_stable
        ] )
    ]
;;
