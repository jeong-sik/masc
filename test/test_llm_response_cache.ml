open Alcotest

module Cache = Masc_mcp.Llm_response_cache

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else
      Unix.unlink path

let with_temp_cwd f =
  let original = Sys.getcwd () in
  let dir = Filename.temp_file "test_llm_response_cache_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Unix.chdir dir;
  Fun.protect
    ~finally:(fun () ->
      Unix.chdir original;
      rm_rf dir)
    f

let test_make_key_deterministic () =
  let a = Cache.make_key ~namespace:"llmresp" ~content:"same-content" in
  let b = Cache.make_key ~namespace:"llmresp" ~content:"same-content" in
  check string "same key" a b

let test_make_key_namespace_isolated () =
  let a = Cache.make_key ~namespace:"llmresp" ~content:"same-content" in
  let b = Cache.make_key ~namespace:"spawn_glm" ~content:"same-content" in
  check bool "different namespace => different key" true (not (String.equal a b))

let test_set_get_roundtrip () =
  with_temp_cwd (fun () ->
      Cache.clear_l1 ();
      let key = Cache.make_key ~namespace:"llmresp" ~content:"roundtrip" in
      let payload = `Assoc [ ("kind", `String "test"); ("value", `Int 1) ] in
      (match Cache.set_json ~key ~ttl_seconds:30 payload with
      | Ok () -> ()
      | Error e -> fail ("set_json failed: " ^ e));
      match Cache.get_json ~key with
      | Ok (Some json) ->
          check string "kind" "test"
            (Yojson.Safe.Util.(json |> member "kind" |> to_string));
          check int "value" 1 (Yojson.Safe.Util.(json |> member "value" |> to_int))
      | Ok None -> fail "expected cache hit"
      | Error e -> fail ("get_json failed: " ^ e))

let test_l2_fallback_after_l1_clear () =
  with_temp_cwd (fun () ->
      Cache.clear_l1 ();
      let key = Cache.make_key ~namespace:"llmresp" ~content:"l2-fallback" in
      let payload = `Assoc [ ("value", `String "from-l2") ] in
      (match Cache.set_json ~key ~ttl_seconds:30 payload with
      | Ok () -> ()
      | Error e -> fail ("set_json failed: " ^ e));
      Cache.clear_l1 ();
      match Cache.get_json ~key with
      | Ok (Some json) ->
          check string "value" "from-l2"
            (Yojson.Safe.Util.(json |> member "value" |> to_string))
      | Ok None -> fail "expected hit from l2"
      | Error e -> fail ("get_json failed: " ^ e))

let test_ttl_expiry () =
  with_temp_cwd (fun () ->
      Cache.clear_l1 ();
      let key = Cache.make_key ~namespace:"llmresp" ~content:"ttl-expiry" in
      let payload = `Assoc [ ("v", `Int 1) ] in
      (match Cache.set_json ~key ~ttl_seconds:1 payload with
      | Ok () -> ()
      | Error e -> fail ("set_json failed: " ^ e));
      Unix.sleep 2;
      match Cache.get_json ~key with
      | Ok None -> ()
      | Ok (Some _) -> fail "expected expired entry"
      | Error e -> fail ("get_json failed: " ^ e))

let test_l1_stats_nonzero_after_set () =
  with_temp_cwd (fun () ->
      Cache.clear_l1 ();
      let key = Cache.make_key ~namespace:"llmresp" ~content:"stats" in
      let payload = `Assoc [ ("v", `Int 1) ] in
      ignore (Cache.set_json ~key ~ttl_seconds:30 payload);
      let stats = Cache.get_l1_stats () in
      check bool "entries > 0" true (stats.entries > 0);
      check bool "max_entries >= entries" true (stats.max_entries >= stats.entries))

let () =
  run "llm_response_cache" [
    ("key", [
         test_case "deterministic" `Quick test_make_key_deterministic;
         test_case "namespace isolated" `Quick test_make_key_namespace_isolated;
       ]);
    ("io", [
         test_case "set/get roundtrip" `Quick test_set_get_roundtrip;
         test_case "l2 fallback after l1 clear" `Quick test_l2_fallback_after_l1_clear;
         test_case "ttl expiry" `Quick test_ttl_expiry;
       ]);
    ("stats", [
         test_case "l1 stats nonzero" `Quick test_l1_stats_nonzero_after_set;
       ]);
  ]
