(** Unit tests for lib/runtime_store.ml.

    Targets 106 uncovered lines (55.08% coverage).
    Uses temp directories for filesystem operations.

    Functions tested:
    - save_text / load_text: roundtrip
    - ensure_dir: nested creation, idempotency
    - save_session / load_session: JSON roundtrip with normalization *)

open Agent_core

(* ── Temp dir helper ─────────────────────────────────────────── *)

let with_temp_dir f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "agent_core-test-%d-%06x" (Unix.getpid ()) (Random.int 0xFFFFFF))
  in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" dir)))
    (fun () -> f dir)
;;

(* ── save_text / load_text tests ─────────────────────────────── *)

let test_save_load_roundtrip () =
  with_temp_dir (fun dir ->
    let path = Filename.concat dir "test.txt" in
    let content = "hello world\nline 2" in
    (match Runtime_store.save_text path content with
     | Ok () -> ()
     | Error e -> Alcotest.fail (Error.to_string e));
    match Runtime_store.load_text path with
    | Ok loaded -> Alcotest.(check string) "roundtrip" content loaded
    | Error e -> Alcotest.fail (Error.to_string e))
;;

let test_save_load_empty () =
  with_temp_dir (fun dir ->
    let path = Filename.concat dir "empty.txt" in
    (match Runtime_store.save_text path "" with
     | Ok () -> ()
     | Error e -> Alcotest.fail (Error.to_string e));
    match Runtime_store.load_text path with
    | Ok loaded -> Alcotest.(check string) "empty" "" loaded
    | Error e -> Alcotest.fail (Error.to_string e))
;;

let test_save_load_unicode () =
  with_temp_dir (fun dir ->
    let path = Filename.concat dir "unicode.txt" in
    let content =
      "Korean: \xed\x95\x9c\xea\xb5\xad\xec\x96\xb4 Emoji: \xf0\x9f\x92\xbb"
    in
    (match Runtime_store.save_text path content with
     | Ok () -> ()
     | Error e -> Alcotest.fail (Error.to_string e));
    match Runtime_store.load_text path with
    | Ok loaded -> Alcotest.(check string) "unicode roundtrip" content loaded
    | Error e -> Alcotest.fail (Error.to_string e))
;;

let test_load_missing_file () =
  with_temp_dir (fun dir ->
    let path = Filename.concat dir "nonexistent.txt" in
    match Runtime_store.load_text path with
    | Ok _ -> Alcotest.fail "expected error"
    | Error _ -> ())
;;

(* ── ensure_dir tests ────────────────────────────────────────── *)

let test_ensure_dir_creates () =
  with_temp_dir (fun dir ->
    let sub = Filename.concat dir "new_sub" in
    (match Runtime_store.ensure_dir sub with
     | Ok () -> ()
     | Error e -> Alcotest.fail (Error.to_string e));
    Alcotest.(check bool) "dir exists" true (Sys.file_exists sub))
;;

let test_ensure_dir_idempotent () =
  with_temp_dir (fun dir ->
    let sub = Filename.concat dir "idem" in
    (match Runtime_store.ensure_dir sub with
     | Ok () -> ()
     | Error e -> Alcotest.fail (Error.to_string e));
    (* Call again -- should not fail *)
    match Runtime_store.ensure_dir sub with
    | Ok () -> ()
    | Error e -> Alcotest.fail (Error.to_string e))
;;

(* ── Runtime_store.create tests ──────────────────────────────── *)

let test_store_create () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Ok store ->
      ignore store;
      Alcotest.(check bool) "root exists" true (Sys.file_exists root);
      Alcotest.(check bool)
        "sessions dir exists"
        true
        (Sys.file_exists (Filename.concat root "sessions"))
    | Error e -> Alcotest.fail (Error.to_string e))
;;

let test_store_create_requires_explicit_root () =
  match Runtime_store.create () with
  | Ok _ -> Alcotest.fail "expected missing session_root error"
  | Error (Error.Config (InvalidConfig { field = "session_root"; detail })) ->
    Alcotest.(check string)
      "detail"
      "missing runtime session root; pass an explicit ~root/session_root"
      detail
  | Error e -> Alcotest.failf "unexpected error: %s" (Error.to_string e)
;;

let test_store_create_rejects_relative_root () =
  match Runtime_store.create ~root:"relative/.agent_core-runtime" () with
  | Ok _ -> Alcotest.fail "expected relative session_root rejection"
  | Error (Error.Config (InvalidConfig { field = "session_root"; detail })) ->
    Alcotest.(check string)
      "detail"
      "runtime session root must be an absolute path"
      detail
  | Error e -> Alcotest.failf "unexpected error: %s" (Error.to_string e)
;;

(* ── save_session / load_session tests ───────────────────────── *)

let mk_session ?(session_id = "test-sess") ?(updated_at = 1001.0) () : Runtime.session =
  { session_id
  ; goal = "test goal"
  ; title = None
  ; tag = None
  ; phase = Running
  ; created_at = 1000.0
  ; updated_at
  ; provider = Some "anthropic"
  ; model = Some "test-model"
  ; system_prompt = None
  ; workdir = None
  ; planned_participants = [ "agent-1" ]
  ; participants = []
  ; artifacts = []
  ; pending_input = None
  ; turn_count = 0
  ; last_seq = 0
  ; outcome = None
  }
;;

let test_save_load_session () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok store ->
      let session = mk_session () in
      (match Runtime_store.save_session store session with
       | Ok () -> ()
       | Error e -> Alcotest.fail (Error.to_string e));
      (match Runtime_store.load_session store "test-sess" with
       | Ok loaded ->
         Alcotest.(check string) "session_id" "test-sess" loaded.session_id;
         Alcotest.(check string) "goal" "test goal" loaded.goal
       | Error e -> Alcotest.fail (Error.to_string e)))
;;

let test_load_session_missing () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok store ->
      (match Runtime_store.load_session store "nonexistent" with
       | Ok _ -> Alcotest.fail "expected error"
       | Error _ -> ()))
;;

let test_load_session_corrupt () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok store ->
      (* Write corrupt JSON to session file *)
      let sess_dir = Filename.concat (Filename.concat root "sessions") "bad-sess" in
      Unix.mkdir sess_dir 0o755;
      let path = Filename.concat sess_dir "session.json" in
      let oc = open_out path in
      output_string oc "not valid json!!!";
      close_out oc;
      (match Runtime_store.load_session store "bad-sess" with
       | Ok _ -> Alcotest.fail "expected parse error"
       | Error _ -> ()))
;;

(* ── Runner ───────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Runtime Store Unit"
    [ ( "save_load_text"
      , [ Alcotest.test_case "roundtrip" `Quick test_save_load_roundtrip
        ; Alcotest.test_case "empty file" `Quick test_save_load_empty
        ; Alcotest.test_case "unicode" `Quick test_save_load_unicode
        ; Alcotest.test_case "missing file" `Quick test_load_missing_file
        ] )
    ; ( "ensure_dir"
      , [ Alcotest.test_case "creates" `Quick test_ensure_dir_creates
        ; Alcotest.test_case "idempotent" `Quick test_ensure_dir_idempotent
        ] )
    ; ( "store_create"
      , [ Alcotest.test_case "create" `Quick test_store_create
        ; Alcotest.test_case
            "requires explicit root"
            `Quick
            test_store_create_requires_explicit_root
        ; Alcotest.test_case
            "rejects relative root"
            `Quick
            test_store_create_rejects_relative_root
        ] )
    ; ( "session"
      , [ Alcotest.test_case "save and load" `Quick test_save_load_session
        ; Alcotest.test_case "missing" `Quick test_load_session_missing
        ; Alcotest.test_case "corrupt" `Quick test_load_session_corrupt
        ] )
    ]
;;
