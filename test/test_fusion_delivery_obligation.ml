open Alcotest

module Obligation = Masc.Fusion_delivery_obligation

let () = Mirage_crypto_rng_unix.use_default ()

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_base f =
  let base_path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "fusion-obligation-%d-%06x" (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir base_path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> f base_path)
;;

let expect_ok = function
  | Ok value -> value
  | Error error -> fail (Obligation.error_to_string error)
;;

let request_id value =
  match Obligation.Request_id.of_string value with
  | Ok request_id -> request_id
  | Error detail -> fail detail
;;

let channel =
  Keeper_continuation_channel.discord
    ~guild_id:(Some "guild-1")
    ~channel_id:"channel-1"
    ~parent_channel_id:None
    ~thread_id:(Some "thread-1")
    ~user_id:"user-1"
  |> function
  | Ok channel -> channel
  | Error detail -> fail detail
;;

let payload ?(prompt = "compare implementations") () : Obligation.accepted_payload =
  { keeper_name = "analyst"
  ; submitted_by = "analyst"
  ; prompt
  ; preset = "council"
  ; web_tools = false
  ; topology = Fusion_types.Judge_of_judges
  ; channel
  }
;;

let test_exact_prepare_load_inventory_remove () =
  with_temp_base (fun base_path ->
    Eio_main.run (fun _env ->
      let request_id = request_id "kmsg-fusion-1" in
      let first =
        Obligation.prepare ~base_path ~request_id ~payload:(payload ())
          ~accepted_at:1.0
        |> expect_ok
      in
      let identity =
        match first with
        | Obligation.Prepared identity -> identity
        | Obligation.Already_present _ -> fail "first prepare was not new"
      in
      (match
         Obligation.prepare ~base_path ~request_id ~payload:(payload ())
           ~accepted_at:1.0
         |> expect_ok
       with
       | Obligation.Already_present _ -> ()
       | Obligation.Prepared _ -> fail "exact replay created another obligation");
      let loaded = Obligation.load ~base_path ~request_id |> expect_ok in
      check string
        "request identity roundtrips"
        "kmsg-fusion-1"
        (Obligation.Request_id.to_string loaded.request_id);
      (match
         Obligation.prepare ~base_path ~request_id
           ~payload:(payload ~prompt:"changed request" ()) ~accepted_at:1.0
       with
       | Error (Obligation.Identity_conflict _) -> ()
       | Error error -> fail (Obligation.error_to_string error)
       | Ok _ -> fail "conflicting payload was accepted");
      let inventory = Obligation.inventory ~base_path |> expect_ok in
      check int "one recoverable obligation" 1 (List.length inventory.obligations);
      check int "no inventory failures" 0 (List.length inventory.record_failures);
      Obligation.remove_delivered ~base_path ~identity |> expect_ok;
      Obligation.remove_delivered ~base_path ~identity |> expect_ok;
      match Obligation.load ~base_path ~request_id with
      | Error (Obligation.Not_found _) -> ()
      | Error error -> fail (Obligation.error_to_string error)
      | Ok _ -> fail "delivered obligation was not removed"))
;;

let test_corrupt_peer_is_quarantined_locally () =
  with_temp_base (fun base_path ->
    Eio_main.run (fun _env ->
      let request_id = request_id "kmsg-fusion-peer" in
      ignore
        (Obligation.prepare ~base_path ~request_id ~payload:(payload ())
           ~accepted_at:2.0
         |> expect_ok);
      let directory =
        Obligation.For_testing.active_directory ~base_path |> expect_ok
      in
      Fs_compat.save_file (Filename.concat directory "malformed") "not-json";
      let inventory = Obligation.inventory ~base_path |> expect_ok in
      check int "valid peer survives corrupt record" 1
        (List.length inventory.obligations);
      check int "corrupt record is explicit" 1
        (List.length inventory.record_failures)))
;;

let () =
  run
    "fusion delivery obligation"
    [ ( "store"
      , [ test_case "exact prepare/load/inventory/remove" `Quick
            test_exact_prepare_load_inventory_remove
        ; test_case "corrupt peer is quarantined locally" `Quick
            test_corrupt_peer_is_quarantined_locally
        ] )
    ]
;;
