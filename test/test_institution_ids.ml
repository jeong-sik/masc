open Alcotest

module I = Masc.Institution_eio

let () = Mirage_crypto_rng_unix.use_default ()

let set_env name value = Unix.putenv name value
let unset_env name = Unix.putenv name ""

let with_env name value f =
  let prev = Sys.getenv_opt name in
  (match value with
   | Some v -> set_env name v
   | None -> unset_env name);
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> set_env name v
      | None -> unset_env name)
    f
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_base f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc-institution-ids-%d-%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1_000_000.0)))
  in
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> try rm_rf dir with _ -> ()) (fun () -> f dir)
;;

let is_hex_char = function
  | '0' .. '9' | 'a' .. 'f' -> true
  | _ -> false
;;

let check_jsonl_id_shape id =
  match String.split_on_char '-' id with
  | [ "ep"; wall_secs; suffix ] ->
    check bool "wall seconds parse" true (Option.is_some (int_of_string_opt wall_secs));
    check int "hex suffix length" 8 (String.length suffix);
    check bool "hex suffix" true (String.for_all is_hex_char suffix)
  | _ -> fail ("unexpected jsonl episode id: " ^ id)
;;

let test_record_episode_jsonl_uses_random_id_shape () =
  with_temp_base (fun base_path ->
    with_env "MASC_BASE_PATH" (Some base_path) (fun () ->
      let episode =
        I.record_episode_jsonl
          ~event_type:"test"
          ~summary:"records an episode id"
          ~participants:[ "test-agent" ]
          ~outcome:`Success
          ~learnings:[ "ids use Random_id" ]
      in
      check_jsonl_id_shape episode.id;
      check bool "jsonl file exists" true (Sys.file_exists (I.episodes_jsonl_path ()));
      match I.load_recent_episodes_jsonl ~limit:1 with
      | [ persisted ] -> check string "persisted id" episode.id persisted.id
      | _ -> fail "expected one persisted episode"))
;;

let () =
  run
    "institution_ids"
    [ ( "jsonl"
      , [ test_case
            "record_episode_jsonl uses wall-seconds plus hex random id"
            `Quick
            test_record_episode_jsonl_uses_random_id_shape
        ] )
    ]
;;
