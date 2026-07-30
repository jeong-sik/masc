(** Explicit Keeper memory writes: every write is a durable Memory OS fact. *)

module Runtime = Masc.Keeper_tool_memory_runtime
module Current = Masc.Keeper_memory_os_current

let make_args ~title ~content =
  `Assoc [ "title", `String title; "content", `String content ]
;;

let with_field args key value =
  match args with
  | `Assoc fields -> `Assoc (fields @ [ key, value ])
  | other -> other
;;

let with_days args days = with_field args "valid_for_days" (`Int days)
let error_label = Runtime.memory_write_error_kind_to_string

let assert_invalid ~expected = function
  | Runtime.Memory_write_invalid { error_kind; _ } ->
    Alcotest.(check string) "error kind" expected (error_label error_kind)
  | Runtime.Memory_write_ok _ ->
    Alcotest.failf "expected invalid memory write: %s" expected
;;

let assert_ok ?(valid_for_days = None) ~body = function
  | Runtime.Memory_write_ok valid ->
    Alcotest.(check (option int)) "valid_for_days" valid_for_days valid.valid_for_days;
    Alcotest.(check string) "body" body valid.body
  | Runtime.Memory_write_invalid { error_kind; _ } ->
    Alcotest.failf "unexpected validation error: %s" (error_label error_kind)
;;

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
  then (
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path)
  else Sys.remove path
;;

let with_temp_dir f =
  let dir = Filename.temp_file "keeper-memory-write-" ".tmp" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)
;;

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "trace_id", `String ("trace-" ^ name)
        ])
  with
  | Error error -> Alcotest.fail ("meta fixture failed: " ^ error)
  | Ok meta ->
    let usage = { meta.runtime.usage with total_turns = 7 } in
    { meta with runtime = { meta.runtime with usage } }
;;

let json_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some value -> value
     | None -> Alcotest.failf "missing JSON field: %s" key)
  | _ -> Alcotest.fail "expected JSON object"
;;

let string_field key json =
  match json_field key json with
  | `String value -> value
  | _ -> Alcotest.failf "expected string field: %s" key
;;

let test_validation_taxonomy () =
  Runtime.validate_memory_write_args (make_args ~title:"" ~content:"")
  |> assert_invalid ~expected:"content_empty";
  Runtime.validate_memory_write_args
    (make_args ~title:(String.make 121 'x') ~content:"body")
  |> assert_invalid ~expected:"title_too_long";
  Runtime.validate_memory_write_args
    (make_args ~title:"" ~content:(String.make 4097 'x'))
  |> assert_invalid ~expected:"content_too_long";
  (* RFC-0351 S2: a lifetime is a claim about scope, so both ends are real
     boundaries. *)
  Runtime.validate_memory_write_args
    (with_days (make_args ~title:"" ~content:"body") 0)
  |> assert_invalid ~expected:"invalid_valid_for_days";
  Runtime.validate_memory_write_args
    (with_days (make_args ~title:"" ~content:"body") 366)
  |> assert_invalid ~expected:"invalid_valid_for_days";
  (* A wrong JSON type is not a range violation. Answering it with the range
     would send the producer looking for a bug it does not have. *)
  (match
     Runtime.validate_memory_write_args
       (with_field (make_args ~title:"" ~content:"body") "valid_for_days"
          (`String "7"))
   with
   | Runtime.Memory_write_invalid { error_kind; extras } ->
     Alcotest.(check string)
       "error kind"
       "invalid_valid_for_days"
       (error_label error_kind);
     Alcotest.(check (option string))
       "reason names the type, not the range"
       (Some "not_an_integer")
       (match List.assoc_opt "reason" extras with
        | Some (`String r) -> Some r
        | _ -> None)
   | Runtime.Memory_write_ok _ -> Alcotest.fail "a string lifetime must be rejected")
;;

let test_valid_body_composition () =
  Runtime.validate_memory_write_args (make_args ~title:"" ~content:"body")
  |> assert_ok ~body:"body";
  Runtime.validate_memory_write_args
    (with_days (make_args ~title:"" ~content:"body") 30)
  |> assert_ok ~valid_for_days:(Some 30) ~body:"body";
  Runtime.validate_memory_write_args
    (make_args ~title:"hook" ~content:"body text")
  |> assert_ok ~body:"**hook** body text"
;;

let current_facts ~keepers_dir keeper_id =
  match Current.read_for_keepers_dir ~keepers_dir ~keeper_id with
  | Ok (Some snapshot) -> snapshot.facts
  | Ok None -> Alcotest.fail "current snapshot missing after successful write"
  | Error detail -> Alcotest.fail ("current snapshot unreadable: " ^ detail)
;;

(* The loop the model actually depends on: an explicit write must reach the
   same current snapshot that recall reads. *)
let test_write_comes_back_through_recall () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "durable-write" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path
  in
  let response =
    Runtime.keeper_memory_write_json
      ~config
      ~meta
      ~args:
        (make_args
           ~title:""
           ~content:"reasoning_content must be replayed unmodified")
    |> Yojson.Safe.from_string
  in
  Alcotest.(check bool)
    "write succeeds"
    true
    (match json_field "ok" response with
     | `Bool value -> value
     | _ -> false);
  Alcotest.(check string)
    "routed to the durable store"
    "current_memory_snapshot"
    (string_field "store" response);
  let facts = current_facts ~keepers_dir meta.name in
  Alcotest.(check int) "one durable claim" 1 (List.length facts);
  let fact = List.hd facts in
  Alcotest.(check string)
    "the claim reaches a later turn"
    "reasoning_content must be replayed unmodified"
    fact.Masc.Keeper_memory_os_types.claim;
  Alcotest.(check int)
    "provenance carries this turn"
    7
    fact.Masc.Keeper_memory_os_types.source.turn;
  (* The model asserted this itself; it did not carry it out of another
     tool's result, and the field says where an observation came from. *)
  Alcotest.(check bool)
    "no borrowed tool provenance"
    true
    (fact.Masc.Keeper_memory_os_types.source.tool_call_id = None);
  Alcotest.(check bool)
    "a claim with no declared lifetime stays permanent"
    true
    (fact.Masc.Keeper_memory_os_types.valid_until = None)
;;

(* RFC-0351 S2. The declared lifetime reaches the current snapshot. *)
let test_declared_lifetime_expires () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "expiring-write" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path
  in
  let response =
    Runtime.keeper_memory_write_json
      ~config
      ~meta
      ~args:
        (with_days
           (make_args ~title:"" ~content:"task-2288 is blocked on the git-root gate")
           7)
    |> Yojson.Safe.from_string
  in
  Alcotest.(check bool)
    "write succeeds"
    true
    (match json_field "ok" response with
     | `Bool value -> value
     | _ -> false);
  let fact = List.hd (current_facts ~keepers_dir meta.name) in
  let valid_until =
    match fact.Masc.Keeper_memory_os_types.valid_until with
    | Some ts -> ts
    | None -> Alcotest.fail "declared lifetime did not reach the store"
  in
  let first_seen = fact.Masc.Keeper_memory_os_types.first_seen in
  (* 7 days from the write, to the second. *)
  Alcotest.(check (float 1.0))
    "boundary is the declared span"
    (7.0 *. 86_400.)
    (valid_until -. first_seen);
  Alcotest.(check bool)
    "still current inside the window"
    true
    (Masc.Keeper_memory_os_types.fact_is_current
       ~now:(valid_until -. 86_400.)
       fact);
  Alcotest.(check bool)
    "recall drops it past the window"
    false
    (Masc.Keeper_memory_os_types.fact_is_current
       ~now:(valid_until +. 1.0)
       fact)
;;

let () =
  Alcotest.run
    "keeper_memory_write"
    [ ( "validation"
      , [ Alcotest.test_case "typed validation failures" `Quick test_validation_taxonomy
        ; Alcotest.test_case
            "valid input composes the stored body"
            `Quick
            test_valid_body_composition
        ] )
    ; ( "persistence"
      , [ Alcotest.test_case
            "write comes back through recall"
            `Quick
            test_write_comes_back_through_recall
        ; Alcotest.test_case
            "declared lifetime reaches the store and expires"
            `Quick
            test_declared_lifetime_expires
        ] )
    ]
;;
