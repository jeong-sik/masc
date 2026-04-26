(** Test Cache_eio Module - Pure Synchronous Tests *)

open Masc_mcp

let () = Random.init 42
let default_cache_max_entries = 1000
let default_cache_max_entry_size = 102400

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_masc_dir f =
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc-cache-eio-%d-%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000000.)))
  in
  Unix.mkdir base 0o755;
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  (* Reset cached entry count to prevent cross-test contamination *)
  Cache_eio.reset_cached_entry_count ();
  let config = Coord.default_config base in
  let _ = Coord.init config ~agent_name:None in
  try
    let result = f config in
    let _ = Coord.reset config in
    rm_rf base;
    result
  with
  | e ->
    let _ = Coord.reset config in
    rm_rf base;
    raise e
;;

let test_set_and_get () =
  with_temp_masc_dir (fun config ->
    (* Set a value - pure sync *)
    let result = Cache_eio.set config ~key:"test-key" ~value:"test-value" () in
    assert (Result.is_ok result);
    (* Get the value - pure sync *)
    match Cache_eio.get config ~key:"test-key" with
    | Ok (Some entry) ->
      assert (entry.Cache_eio.key = "test-key");
      assert (entry.Cache_eio.value = "test-value")
    | _ -> failwith "Expected to get cached value");
  print_endline "✓ test_set_and_get passed"
;;

let test_set_with_ttl () =
  with_temp_masc_dir (fun config ->
    (* Set with TTL *)
    let result =
      Cache_eio.set config ~key:"ttl-key" ~value:"ttl-value" ~ttl_seconds:3600 ()
    in
    assert (Result.is_ok result);
    match Cache_eio.get config ~key:"ttl-key" with
    | Ok (Some entry) ->
      assert (entry.Cache_eio.key = "ttl-key");
      assert (Option.is_some entry.Cache_eio.expires_at)
    | _ -> failwith "Expected to get cached value with TTL");
  print_endline "✓ test_set_with_ttl passed"
;;

let test_set_with_tags () =
  with_temp_masc_dir (fun config ->
    (* Set with tags *)
    let result =
      Cache_eio.set
        config
        ~key:"tagged-key"
        ~value:"tagged-value"
        ~tags:[ "tag1"; "tag2" ]
        ()
    in
    assert (Result.is_ok result);
    match Cache_eio.get config ~key:"tagged-key" with
    | Ok (Some entry) ->
      assert (List.mem "tag1" entry.Cache_eio.tags);
      assert (List.mem "tag2" entry.Cache_eio.tags)
    | _ -> failwith "Expected to get cached value with tags");
  print_endline "✓ test_set_with_tags passed"
;;

let test_large_value_round_trips_without_truncation () =
  with_temp_masc_dir (fun config ->
    let large_value = String.make 2048 'x' in
    let result = Cache_eio.set config ~key:"large-value" ~value:large_value () in
    assert (Result.is_ok result);
    match Cache_eio.get config ~key:"large-value" with
    | Ok (Some entry) ->
      assert (String.length entry.Cache_eio.value = 2048);
      assert (entry.Cache_eio.value = large_value)
    | _ -> failwith "Expected large cache value to round-trip intact");
  print_endline "✓ test_large_value_round_trips_without_truncation passed"
;;

let test_get_nonexistent () =
  with_temp_masc_dir (fun config ->
    match Cache_eio.get config ~key:"nonexistent" with
    | Ok None -> () (* Expected *)
    | _ -> failwith "Expected None for nonexistent key");
  print_endline "✓ test_get_nonexistent passed"
;;

let test_delete () =
  with_temp_masc_dir (fun config ->
    (* Set then delete *)
    let _ = Cache_eio.set config ~key:"delete-me" ~value:"value" () in
    let deleted = Cache_eio.delete config ~key:"delete-me" in
    assert (Result.is_ok deleted);
    assert (deleted = Ok true);
    (* Verify it's gone *)
    match Cache_eio.get config ~key:"delete-me" with
    | Ok None -> ()
    | _ -> failwith "Expected key to be deleted");
  print_endline "✓ test_delete passed"
;;

let test_list () =
  with_temp_masc_dir (fun config ->
    (* Add some entries *)
    let _ = Cache_eio.set config ~key:"list-1" ~value:"v1" ~tags:[ "a" ] () in
    let _ = Cache_eio.set config ~key:"list-2" ~value:"v2" ~tags:[ "a"; "b" ] () in
    let _ = Cache_eio.set config ~key:"list-3" ~value:"v3" ~tags:[ "b" ] () in
    (* List all *)
    let all = Cache_eio.list config () in
    assert (List.length all = 3);
    (* List by tag *)
    let tag_a = Cache_eio.list config ~tag:"a" () in
    assert (List.length tag_a = 2);
    let tag_b = Cache_eio.list config ~tag:"b" () in
    assert (List.length tag_b = 2));
  print_endline "✓ test_list passed"
;;

let test_clear () =
  with_temp_masc_dir (fun config ->
    (* Add some entries *)
    let _ = Cache_eio.set config ~key:"clear-1" ~value:"v1" () in
    let _ = Cache_eio.set config ~key:"clear-2" ~value:"v2" () in
    (* Clear all *)
    let result = Cache_eio.clear config in
    assert (Result.is_ok result);
    (match result with
     | Ok count -> assert (count = 2)
     | Error _ -> failwith "Clear failed");
    (* Verify empty *)
    let all = Cache_eio.list config () in
    assert (List.length all = 0));
  print_endline "✓ test_clear passed"
;;

let test_stats () =
  with_temp_masc_dir (fun config ->
    (* Add some entries *)
    let _ = Cache_eio.set config ~key:"stats-1" ~value:"short" () in
    let _ = Cache_eio.set config ~key:"stats-2" ~value:(String.make 1000 'x') () in
    let result = Cache_eio.stats config in
    match result with
    | Ok (total, expired, size) ->
      assert (total = 2);
      assert (expired = 0);
      assert (size > 0.0);
      print_endline
        (Printf.sprintf "  Stats: %s" (Cache_eio.format_stats (total, expired, size)))
    | Error _ -> failwith "Stats failed");
  print_endline "✓ test_stats passed"
;;

let test_expired_cleanup () =
  with_temp_masc_dir (fun config ->
    (* Set with very short TTL (already expired) *)
    let _ = Cache_eio.set config ~key:"expired" ~value:"old" ~ttl_seconds:(-1) () in
    (* Get should return None and delete *)
    match Cache_eio.get config ~key:"expired" with
    | Ok None -> () (* Auto-cleanup worked *)
    | _ -> failwith "Expected expired entry to be cleaned up");
  print_endline "  test_expired_cleanup passed"
;;

let test_evict_expired_batch () =
  with_temp_masc_dir (fun config ->
    (* Create several expired entries *)
    let _ = Cache_eio.set config ~key:"exp-1" ~value:"v1" ~ttl_seconds:(-1) () in
    let _ = Cache_eio.set config ~key:"exp-2" ~value:"v2" ~ttl_seconds:(-1) () in
    let _ = Cache_eio.set config ~key:"exp-3" ~value:"v3" ~ttl_seconds:(-1) () in
    (* Create a valid entry *)
    let _ = Cache_eio.set config ~key:"valid-1" ~value:"keep" ~ttl_seconds:3600 () in
    (* Evict expired entries *)
    let evicted = Cache_eio.evict_expired config in
    assert (evicted = 3);
    (* Valid entry should still exist *)
    (match Cache_eio.get config ~key:"valid-1" with
     | Ok (Some entry) -> assert (entry.Cache_eio.value = "keep")
     | _ -> failwith "Expected valid entry to survive eviction");
    (* Expired entries should be gone *)
    let count = Cache_eio.count_entries config in
    assert (count = 1));
  print_endline "  test_evict_expired_batch passed"
;;

let test_maybe_evict_expired_triggers_when_ratio_high () =
  with_temp_masc_dir (fun config ->
    (* Reset last_batch_eviction to allow immediate trigger *)
    Atomic.set Cache_eio.last_batch_eviction 0.0;
    (* Create 8 expired + 2 valid = 80% expired ratio > 50% threshold *)
    for i = 1 to 8 do
      let _ =
        Cache_eio.set
          config
          ~key:(Printf.sprintf "exp-%d" i)
          ~value:"expired"
          ~ttl_seconds:(-1)
          ()
      in
      ()
    done;
    let _ = Cache_eio.set config ~key:"valid-a" ~value:"keep-a" ~ttl_seconds:3600 () in
    let _ = Cache_eio.set config ~key:"valid-b" ~value:"keep-b" ~ttl_seconds:3600 () in
    (* Verify we start with 10 entries *)
    assert (Cache_eio.count_entries config = 10);
    (* Access via get triggers maybe_evict_expired *)
    let _ = Cache_eio.get config ~key:"valid-a" in
    (* After batch eviction, only valid entries should remain *)
    let remaining = Cache_eio.count_entries config in
    assert (remaining = 2));
  print_endline "  test_maybe_evict_expired_triggers_when_ratio_high passed"
;;

let test_maybe_evict_expired_throttled () =
  with_temp_masc_dir (fun config ->
    (* Set last_batch_eviction to now (prevents re-run within interval) *)
    Atomic.set Cache_eio.last_batch_eviction (Unix.gettimeofday ());
    (* Create expired entries *)
    let _ = Cache_eio.set config ~key:"exp-1" ~value:"v1" ~ttl_seconds:(-1) () in
    let _ = Cache_eio.set config ~key:"exp-2" ~value:"v2" ~ttl_seconds:(-1) () in
    (* maybe_evict should be throttled (returns 0) *)
    let evicted = Cache_eio.maybe_evict_expired config in
    assert (evicted = 0);
    (* Expired entries should still exist on disk (not evicted by batch) *)
    (* Note: individual get will still remove the specific expired entry *)
    assert (Cache_eio.count_entries config = 2));
  print_endline "  test_maybe_evict_expired_throttled passed"
;;

let with_cache_limits ~max_entries ~max_entry_size f =
  let prev_max_entries = Sys.getenv_opt "MASC_CACHE_MAX_ENTRIES" in
  let prev_max_entry_size = Sys.getenv_opt "MASC_CACHE_MAX_ENTRY_SIZE" in
  Unix.putenv "MASC_CACHE_MAX_ENTRIES" (string_of_int max_entries);
  Unix.putenv "MASC_CACHE_MAX_ENTRY_SIZE" (string_of_int max_entry_size);
  Fun.protect
    ~finally:(fun () ->
      (match prev_max_entries with
       | Some v -> Unix.putenv "MASC_CACHE_MAX_ENTRIES" v
       | None ->
         Unix.putenv "MASC_CACHE_MAX_ENTRIES" (string_of_int default_cache_max_entries));
      match prev_max_entry_size with
      | Some v -> Unix.putenv "MASC_CACHE_MAX_ENTRY_SIZE" v
      | None ->
        Unix.putenv
          "MASC_CACHE_MAX_ENTRY_SIZE"
          (string_of_int default_cache_max_entry_size))
    f
;;

let test_distinct_keys_do_not_collide_after_sanitize () =
  with_temp_masc_dir (fun config ->
    let key_a = "feature/a" in
    let key_b = "feature:a" in
    let _ = Cache_eio.set config ~key:key_a ~value:"value-a" () in
    let _ = Cache_eio.set config ~key:key_b ~value:"value-b" () in
    match Cache_eio.get config ~key:key_a, Cache_eio.get config ~key:key_b with
    | Ok (Some entry_a), Ok (Some entry_b) ->
      assert (entry_a.Cache_eio.value = "value-a");
      assert (entry_b.Cache_eio.value = "value-b");
      assert (Cache_eio.count_entries config = 2)
    | _ -> failwith "Expected both colliding-sanitize keys to survive independently");
  print_endline "  test_distinct_keys_do_not_collide_after_sanitize passed"
;;

let test_overwrite_existing_key_when_cache_is_full () =
  with_cache_limits ~max_entries:1 ~max_entry_size:default_cache_max_entry_size (fun () ->
    with_temp_masc_dir (fun config ->
      let _ = Cache_eio.set config ~key:"same-key" ~value:"first" () in
      match Cache_eio.set config ~key:"same-key" ~value:"second" () with
      | Ok entry ->
        assert (entry.Cache_eio.value = "second");
        assert (Cache_eio.count_entries config = 1);
        (match Cache_eio.get config ~key:"same-key" with
         | Ok (Some fetched) -> assert (fetched.Cache_eio.value = "second")
         | _ -> failwith "Expected overwrite to remain readable")
      | Error msg -> failwith ("Expected overwrite to succeed when cache is full: " ^ msg)));
  print_endline "  test_overwrite_existing_key_when_cache_is_full passed"
;;

let test_get_migrates_legacy_entry_and_list_dedupes () =
  with_temp_masc_dir (fun config ->
    let key = "legacy/key" in
    let legacy_path =
      Filename.concat (Cache_eio.cache_dir config) (Cache_eio.sanitize_key key ^ ".json")
    in
    Fs_compat.mkdir_p (Filename.dirname legacy_path);
    let entry : Cache_eio.cache_entry =
      { key
      ; value = "legacy-value"
      ; created_at = Unix.gettimeofday ()
      ; expires_at = None
      ; tags = [ "legacy" ]
      }
    in
    Fs_compat.save_file
      legacy_path
      (Yojson.Safe.pretty_to_string (Cache_eio.entry_to_json entry));
    Cache_eio.reset_cached_entry_count ();
    assert (Cache_eio.count_entries config = 1);
    (match Cache_eio.get config ~key with
     | Ok (Some fetched) -> assert (fetched.Cache_eio.value = "legacy-value")
     | _ -> failwith "Expected legacy entry to be readable");
    let primary_path =
      Filename.concat (Cache_eio.cache_dir config) (Cache_eio.cache_filename key ^ ".json")
    in
    assert (Sys.file_exists primary_path);
    assert (not (Sys.file_exists legacy_path));
    let listed = Cache_eio.list config () in
    assert (List.length listed = 1);
    assert (Cache_eio.count_entries config = 1));
  print_endline "  test_get_migrates_legacy_entry_and_list_dedupes passed"
;;

let () =
  Alcotest.run
    "Cache_eio"
    [ ( "basic"
      , [ Alcotest.test_case "set and get" `Quick test_set_and_get
        ; Alcotest.test_case "set with ttl" `Quick test_set_with_ttl
        ; Alcotest.test_case "set with tags" `Quick test_set_with_tags
        ; Alcotest.test_case
            "large value round-trips"
            `Quick
            test_large_value_round_trips_without_truncation
        ; Alcotest.test_case "get nonexistent" `Quick test_get_nonexistent
        ; Alcotest.test_case "delete" `Quick test_delete
        ; Alcotest.test_case "list" `Quick test_list
        ; Alcotest.test_case "clear" `Quick test_clear
        ; Alcotest.test_case "stats" `Quick test_stats
        ] )
    ; ( "expiration"
      , [ Alcotest.test_case "expired cleanup" `Quick test_expired_cleanup
        ; Alcotest.test_case "evict expired batch" `Quick test_evict_expired_batch
        ; Alcotest.test_case
            "maybe_evict triggers when ratio high"
            `Quick
            test_maybe_evict_expired_triggers_when_ratio_high
        ; Alcotest.test_case
            "maybe_evict throttled"
            `Quick
            test_maybe_evict_expired_throttled
        ] )
    ; ( "keys_and_eviction"
      , [ Alcotest.test_case
            "distinct keys don't collide after sanitize"
            `Quick
            test_distinct_keys_do_not_collide_after_sanitize
        ; Alcotest.test_case
            "overwrite existing key when full"
            `Quick
            test_overwrite_existing_key_when_cache_is_full
        ; Alcotest.test_case
            "get migrates legacy entry and list dedupes"
            `Quick
            test_get_migrates_legacy_entry_and_list_dedupes
        ] )
    ]
;;
