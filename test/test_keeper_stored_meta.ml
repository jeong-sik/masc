(** RFC #52975 L1: where a Keeper row gets the stored meta.

    The operator snapshot, the Board address and the Keeper list used to read
    the Keeper's meta file for every row. When the Keeper's Owner stands for
    that file they ask the Owner instead. What they are handed has to be what
    the file read gives: the snapshot leaves the TOML-owned fields out, so the
    value in the Owner's memory is not it.

    These cases compare the two sources through the Board address and the
    Keeper list, and at the read each of the three consumers makes. The
    operator snapshot row is compared in test_operator_control_snapshot.ml,
    which owns the fixture that row needs.

    The operator snapshot also walks every configured Keeper to name the ones
    meant to keep running (#53113). That walk is compared here too. *)

module Workspace = Masc.Workspace
module Meta = Masc.Keeper_meta_contract
module Store = Masc.Keeper_meta_store
module Stored_meta = Masc.Keeper_stored_meta
module Owner = Masc.Keeper_owner
module Reducer = Masc.Keeper_owner_reducer
module Registry = Masc.Keeper_owner_registry
module Projection = Masc.Keeper_owner_projection
module Board_address = Masc.Keeper_board_address
module List_row = Masc.Keeper_tool_surface_ops
module Usage = Masc.Keeper_usage_resolution

(* A Keeper list row resolves the default runtime id, which fails closed when
   no runtime is loaded (RFC-0206 §2.1). Minimal catalog, loaded once for the
   executable. *)
let runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}
;;

let runtime_initialized = ref false

let ensure_runtime () =
  if not !runtime_initialized
  then (
    let path = Filename.temp_file "keeper-stored-meta-runtime-" ".toml" in
    Fun.protect
      ~finally:(fun () ->
        try Sys.remove path with
        | Sys_error _ -> ())
      (fun () ->
        Out_channel.with_open_bin path (fun oc -> output_string oc runtime_toml);
        match Runtime.init_default ~config_path:path with
        | Ok () -> runtime_initialized := true
        | Error error -> Alcotest.failf "Runtime.init_default failed: %s" error))
;;

let rec mkdir_p dir =
  if not (Sys.file_exists dir)
  then (
    mkdir_p (Filename.dirname dir);
    if not (Sys.file_exists dir) then Sys.mkdir dir 0o755)
;;

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)
;;

let read_file path = In_channel.with_open_bin path In_channel.input_all

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  ensure_runtime ();
  let base_path = Filename.temp_dir "masc-keeper-stored-meta-" ".workspace" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () ->
      let config = Workspace.default_config base_path in
      ignore (Workspace.init config ~agent_name:None);
      f ~clock:(Eio.Stdenv.clock env) config)
;;

(* {1 Keepers} *)

let held_task =
  match Keeper_id.Task_id.of_string "task-stored-meta" with
  | Ok task_id -> task_id
  | Error detail -> failwith detail
;;

let held_task_name = Keeper_id.Task_id.to_string held_task

(* The instructions differ from the ones the TOML below declares, so the
   reconcile has a stored field to bring back and commits. *)
let fixture_meta name : Meta.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String name; "trace_id", `String ("trace-" ^ name) ])
  with
  | Ok meta -> { meta with instructions = "left by an earlier process" }
  | Error detail -> Alcotest.failf "meta fixture failed: %s" detail
;;

(* Stored fields away from the fixture's values, and floats that need
   seventeen digits to print. *)
let busy_meta name : Meta.keeper_meta =
  let meta = fixture_meta name in
  { meta with
    instructions = "첫 줄\nsecond \"line\""
  ; current_task_id = Some held_task
  ; agent_core_env = [ "FIRST", "1"; "SECOND", "two words" ]
  ; runtime =
      { meta.runtime with
        usage =
          { meta.runtime.usage with
            total_turns = 7
          ; total_input_tokens = 1_200
          ; total_output_tokens = 340
          ; total_tokens = 1_540
          ; last_turn_ts = 1_700_000_000.0 +. (0.1 +. 0.2)
          ; last_input_tokens = 200
          ; last_output_tokens = 40
          ; last_total_tokens = 240
          ; last_latency_ms = 913
          }
      ; proactive_rt =
          { meta.runtime.proactive_rt with
            count_total = 3
          ; last_ts = 0.1 +. 0.2
          ; visible_count_total = 2
          ; last_visible_ts = 1_700_000_100.25
          ; last_reason = "board mention"
          ; last_preview = "Looking at the queue"
          }
      ; last_turn_id = 9
      ; message_scope_ack_id = Some "row-17"
      }
  }
;;

(* The stored fields that have a structure of their own, filled: the usage
   cursor and the last usage resolution, a cost with a reading (written as an
   object, where a bare sum is written as a number), an operator pause with
   its reason, and the Keeper's id. The resolver and the cost module build
   their values, so each is one the server can hold. *)
let accounted_meta name : Meta.keeper_meta =
  let meta = busy_meta name in
  let sample : Usage.sample =
    { input_tokens = 1_200
    ; output_tokens = 340
    ; cache_creation_input_tokens = 16
    ; cache_read_input_tokens = 900
    ; cost_usd = Some 0.125
    }
  in
  let resolution, cursor =
    Usage.resolve
      ~cursor:None
      ~basis:
        (Usage.Conversation_counter
           { runtime_id = "runtime-a"
           ; conversation_id = "conversation-7"
           ; position = Usage.Fresh
           })
      ~observation:(Some sample)
      ~observed_at:(1_700_000_050.0 +. (0.1 +. 0.2))
  in
  let cursor =
    match cursor with
    | Some cursor -> cursor
    | None -> Alcotest.fail "the usage resolver kept no cursor for a fresh counter"
  in
  let total_cost_usd =
    match
      Keeper_cost_coverage.observe
        meta.runtime.usage.total_cost_usd
        (Keeper_cost_coverage.Priced 0.125)
    with
    | Ok cost -> cost
    | Error error ->
      Alcotest.failf "cost fixture failed: %s" (Keeper_cost_coverage.error_to_string error)
  in
  (match Keeper_cost_coverage.to_json total_cost_usd with
   | `Assoc _ -> ()
   | _ -> Alcotest.fail "the cost fixture is written as a bare number");
  let keeper_id =
    match Keeper_id.Uid.of_string "keeper-3f2b8c1e-5d47-4a9b-8e6f-0123456789ab" with
    | Ok keeper_id -> keeper_id
    | Error detail -> Alcotest.failf "keeper id fixture failed: %s" detail
  in
  { meta with
    paused = true
  ; latched_reason =
      Some
        (Keeper_latched_reason.Operator_paused
           { operator_actor = Keeper_latched_reason.Keeper_down })
  ; keeper_id = Some keeper_id
  ; runtime =
      { meta.runtime with
        usage = { meta.runtime.usage with total_cost_usd }
      ; usage_cursor = Some cursor
      ; last_usage_resolution = Some resolution
      }
  }
;;

let meta_path config name = Masc.Keeper_types_profile.keeper_meta_path config name

let leave_snapshot config meta =
  match Store.replace_snapshot config meta with
  | Ok () -> ()
  | Error detail -> Alcotest.failf "replace_snapshot failed: %s" detail
;;

(* The snapshot of [meta] as a process other than this one could have left
   it: the same members in another order and another layout. *)
let foreign_snapshot (meta : Meta.keeper_meta) =
  match Masc.Keeper_meta_json.meta_to_json meta with
  | `Assoc members -> Yojson.Safe.pretty_to_string (`Assoc (List.rev members)) ^ "\n"
  | _ -> Alcotest.fail "the meta encoder did not return an object"
;;

let leave_foreign_snapshot config (meta : Meta.keeper_meta) =
  leave_snapshot config meta;
  let text = foreign_snapshot meta in
  write_file (meta_path config meta.name) text;
  text
;;

(* The Keeper's TOML. [addressed] names a mention target and a Board
   interest, two fields the snapshot leaves out. [on_demand] is not the
   decoder's placeholder for the activation mode. *)
let declare config name ~addressed =
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path
  in
  mkdir_p keepers_dir;
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    (String.concat
       "\n"
       ([ "[keeper]"
        ; "sandbox_profile = \"docker\""
        ; "sandbox_image = \"base\""
        ; "activation_mode = \"on_demand\""
        ]
        @ (if addressed
           then [ "mention_targets = [\"ops\"]"; "board_interests = [\"runtime\"]" ]
           else [])
        @ [ "instructions = \"Watch the runtime.\""; "" ]))
;;

(* {1 Owners} *)

let with_owners config f =
  Eio.Switch.run
  @@ fun sw ->
  (match
     Registry.install_from_store
       ~sw
       ~operation_runner:None
       ~on_turn_slot_released:None
       config
   with
   | Ok _ -> ()
   | Error error ->
     Alcotest.failf
       "install_from_store failed: %s"
       (Registry.install_error_to_string error));
  f ()
;;

let owner_meta config name : Meta.keeper_meta =
  match Projection.lookup ~base_path:config.Workspace.base_path ~keeper_name:name with
  | Projection.Owner_projection { Reducer.meta = Some meta; _ } -> meta
  | Projection.Owner_projection { Reducer.meta = None; _ } ->
    Alcotest.failf "the Owner of %s holds no meta" name
  | Projection.Owner_absent -> Alcotest.failf "no Owner is installed for %s" name
;;

(* What the server does when it starts a Keeper and when it reconciles one:
   the TOML's values go into the Owner's meta. *)
let reconcile config name =
  match Masc.Keeper_runtime.ensure_keeper_meta config name with
  | Ok _ -> ()
  | Error detail -> Alcotest.failf "ensure_keeper_meta %s failed: %s" name detail
;;

(* [read ()] while no Owner stands for [name]. Every stored meta read then
   opens the file, as every one of them did before the Owner was asked. *)
let from_the_file config name read =
  let base_path = config.Workspace.base_path in
  match Registry.get ~base_path ~keeper_name:name with
  | Error error ->
    Alcotest.failf
      "no Owner to set aside for %s: %s"
      name
      (Registry.lookup_error_to_string error)
  | Ok owner ->
    Projection.remove ~base_path ~keeper_name:name owner;
    Fun.protect
      ~finally:(fun () -> Projection.install ~base_path ~keeper_name:name owner)
      read
;;

let with_installed config name owner f =
  let base_path = config.Workspace.base_path in
  Projection.install ~base_path ~keeper_name:name owner;
  Fun.protect
    ~finally:(fun () -> Projection.remove ~base_path ~keeper_name:name owner)
    f
;;

let start_owner ~sw config ~store ~keeper_name ~initial_meta =
  let base_path = config.Workspace.base_path in
  match
    Owner.start
      ~sw
      ~base_path
      ~store
      ~operation_store_path:(Filename.concat base_path (keeper_name ^ ".sqlite3"))
      ~session_root:(Filename.concat base_path "traces")
      ~now:Unix.gettimeofday
      ~operation_runner:None
      ~on_turn_slot_released:None
      ~keeper_name
      ~initial_meta
  with
  | Ok owner -> owner
  | Error error ->
    Alcotest.failf "the Owner did not start: %s" (Owner.error_to_string error)
;;

(* {1 The three Keepers of RFC #52975 §4} *)

(* Its TOML declares fields that are not the decoder's placeholders, and the
   Owner has written its meta. *)
let declared = "stored-meta-declared"

(* The Owner still holds a mention target that was taken out of the TOML
   while the server ran. *)
let key_removed = "stored-meta-key-removed"

(* The Owner started from a file another process left and has written
   nothing since. *)
let unwritten = "stored-meta-unwritten"

let keepers = [ declared; key_removed; unwritten ]

let with_three_keepers f =
  with_workspace
  @@ fun ~clock:_ config ->
  List.iter
    (fun name ->
      declare config name ~addressed:true;
      leave_snapshot config (fixture_meta name))
    [ declared; key_removed ];
  declare config unwritten ~addressed:true;
  let left_by_another_process = leave_foreign_snapshot config (busy_meta unwritten) in
  with_owners config
  @@ fun () ->
  List.iter (reconcile config) [ declared; key_removed ];
  declare config key_removed ~addressed:false;
  (* The fixture is only worth comparing while the two sources can differ. *)
  List.iter
    (fun name ->
      Alcotest.(check (list string))
        (name ^ ": the Owner holds the mention target, which no snapshot stores")
        [ "ops" ]
        (owner_meta config name).mention_targets)
    [ declared; key_removed ];
  Alcotest.(check string)
    (unwritten ^ ": the Owner has written nothing over the file it started from")
    left_by_another_process
    (read_file (meta_path config unwritten));
  f config
;;

(* {1 Consumers} *)

(* [Ok] carries a row, [Error] what the consumer answered in its place. *)
let board_address config name =
  let address = Board_address.read config name in
  let json = Yojson.Safe.to_string (Board_address.to_yojson address) in
  match address with
  | Board_address.Ready _ -> Ok json
  | Board_address.Unavailable _ -> Error json
;;

(* A row with no health is the error row the list publishes for a Keeper
   whose effective meta did not read. *)
let list_row shape config name =
  match
    List_row.keeper_list_row_json_of_shape ~shape ~runtime_class:"keeper" config name
  with
  | None -> Error "no row"
  | Some row ->
    (match Yojson.Safe.Util.member "health" row with
     | `String _ -> Ok (Yojson.Safe.to_string row)
     | _ -> Error (Yojson.Safe.to_string row))
;;

let consumers =
  [ "Board address", board_address
  ; "Keeper list detail row", list_row List_row.Detail_row
  ; "Keeper list roster row", list_row List_row.Roster_row
  ]
;;

let row = Alcotest.(result string string)

(* The file read each consumer hands to [Stored_meta.read]. *)
let file_readers config name =
  [ ("as the operator snapshot reads it", fun () -> Store.read_meta config name)
  ; ( "as the Board address reads it"
    , fun () ->
        Store.read_meta_file_path
          (Filename.concat
             (Workspace.keepers_runtime_dir config)
             (Keeper_runtime_root_entry.keeper_basename
                ~keeper_name:name
                Keeper_runtime_root_entry.Metadata)) )
  ; ( "as the Keeper list reads it"
    , fun () ->
        Store.read_meta_resolved config name
        |> Result.map (Option.map (fun (_resolved_name, meta) -> meta)) )
  ]
;;

let stored_fields meta = Yojson.Safe.to_string (Masc.Keeper_meta_json.meta_to_json meta)

(* The stored fields and two TOML-owned ones are compared by name first, so
   a difference there is printed. The last check covers every field. *)
let check_same_meta label (expected : Meta.keeper_meta) (actual : Meta.keeper_meta) =
  Alcotest.(check string)
    (label ^ ": stored fields")
    (stored_fields expected)
    (stored_fields actual);
  Alcotest.(check (list string))
    (label ^ ": mention_targets")
    expected.mention_targets
    actual.mention_targets;
  Alcotest.(check string)
    (label ^ ": activation_mode")
    (Masc.Keeper_activation_mode.to_string expected.activation_mode)
    (Masc.Keeper_activation_mode.to_string actual.activation_mode);
  Alcotest.(check bool) (label ^ ": every field") true (expected = actual)
;;

let describe_read = function
  | Ok (Some (_ : Meta.keeper_meta)) -> "a meta"
  | Ok None -> "no meta"
  | Error detail -> "an error: " ^ detail
;;

let check_same_read label from_file handed =
  match from_file, handed with
  | Ok (Some from_file), Ok (Some handed) -> check_same_meta label from_file handed
  | (Ok (Some _) | Ok None | Error _), (Ok (Some _) | Ok None | Error _) ->
    Alcotest.failf
      "%s: the file read gave %s and the stored meta read gave %s"
      label
      (describe_read from_file)
      (describe_read handed)
;;

let held_task_of = function
  | Ok (Some (meta : Meta.keeper_meta)) ->
    Option.map Keeper_id.Task_id.to_string meta.current_task_id
  | Ok None -> Alcotest.fail "no meta was handed out"
  | Error detail -> Alcotest.failf "the stored meta read failed: %s" detail
;;

(* {1 The Owner's answer is the file's} *)

let test_consumers_answer_what_the_file_gives () =
  with_three_keepers
  @@ fun config ->
  List.iter
    (fun name ->
      List.iter
        (fun (consumer_name, consumer) ->
          let label = Printf.sprintf "%s of %s" consumer_name name in
          let from_owner = consumer config name in
          (match from_owner with
           | Ok _ -> ()
           | Error other -> Alcotest.failf "%s: no row was answered: %s" label other);
          Alcotest.check
            row
            label
            (from_the_file config name (fun () -> consumer config name))
            from_owner)
        consumers)
    keepers;
  (* Here the two sources part: the Owner still holds ["ops"], and the
     overlay keeps what it is handed when the TOML names no target. *)
  Alcotest.check
    row
    "a Keeper whose TOML names no target any more is addressed by its own name"
    (Ok
       (Yojson.Safe.to_string
          (Board_address.to_yojson
             (Board_address.Ready
                (Masc.Keeper_lane_mentions.effective_target_ids
                   ~keeper_name:key_removed
                   ~mention_targets:[])))))
    (board_address config key_removed)
;;

let test_owner_hands_out_the_file_read () =
  with_three_keepers
  @@ fun config ->
  List.iter
    (fun name ->
      List.iter
        (fun (reader_name, read_file) ->
          let label = Printf.sprintf "%s, %s" name reader_name in
          let file_reads = ref 0 in
          let handed =
            Stored_meta.read config name ~read_file:(fun () ->
              incr file_reads;
              read_file ())
          in
          Alcotest.(check int) (label ^ ": the file is not read") 0 !file_reads;
          check_same_read label (read_file ()) handed)
        (file_readers config name))
    keepers
;;

(* What a reader is handed while the Owner stands for the file. *)
let handed config name =
  Stored_meta.read config name ~read_file:(fun () ->
    Alcotest.failf "the file of %s was read while its Owner stands for it" name)
;;

let handed_meta config name : Meta.keeper_meta =
  match handed config name with
  | Ok (Some meta) -> meta
  | Ok None -> Alcotest.failf "no meta was handed out for %s" name
  | Error detail -> Alcotest.failf "the read of %s failed: %s" name detail
;;

(* One commit of the Keeper's Owner, which publishes a new meta. *)
let take_the_task config name =
  match
    Registry.apply_meta
      ~base_path:config.Workspace.base_path
      ~keeper_name:name
      (Reducer.Set_current_task { task_id = Some held_task; updated_at = "task taken" })
  with
  | Ok _ -> ()
  | Error error ->
    Alcotest.failf "the commit failed: %s" (Registry.command_error_to_string error)
;;

let test_handed_meta_follows_the_owner_commits () =
  with_three_keepers
  @@ fun config ->
  let name = declared in
  Alcotest.(check (option string))
    "no task is held at first"
    None
    (held_task_of (handed config name));
  take_the_task config name;
  Alcotest.(check (option string))
    "the task of the commit is handed out"
    (Some held_task_name)
    (held_task_of (handed config name));
  check_same_read "after the commit" (Store.read_meta config name) (handed config name)
;;

(* {1 The read-back is kept}

   The snapshot is printed and parsed once for a meta the Owner published,
   not once for a read. Two reads of one published meta are told apart from
   two read-backs by the value they hand out: a read-back builds a new one. *)

let test_read_back_is_made_once_for_a_published_meta () =
  with_three_keepers
  @@ fun config ->
  let name = declared in
  let first = handed_meta config name in
  Alcotest.(check bool)
    "the next read hands out the value of the first"
    true
    (handed_meta config name == first);
  take_the_task config name;
  let after_the_commit = handed_meta config name in
  Alcotest.(check bool)
    "a commit of the Owner ends it"
    false
    (after_the_commit == first);
  Alcotest.(check bool)
    "the read-back of the committed meta is kept in its turn"
    true
    (handed_meta config name == after_the_commit)
;;

(* Reads [name] and keeps only a weak pointer to what was handed out. Never
   inlined: the caller's frame must not hold the value. *)
let[@inline never] weakly_handed config name =
  let kept = Weak.create 1 in
  Weak.set kept 0 (Some (handed_meta config name));
  kept
;;

(* A Keeper whose Owner is gone is not read through it again, so no read of
   that Keeper replaces what was kept for it. The next read-back kept for any
   Keeper lets it go. *)
let test_read_back_is_let_go_with_its_owner () =
  with_three_keepers
  @@ fun config ->
  let base_path = config.Workspace.base_path in
  let kept = weakly_handed config declared in
  Gc.full_major ();
  Alcotest.(check bool)
    "kept while the Owner stands for the file"
    true
    (Weak.check kept 0);
  let owner =
    match Registry.get ~base_path ~keeper_name:declared with
    | Ok owner -> owner
    | Error error ->
      Alcotest.failf
        "no Owner to take away for %s: %s"
        declared
        (Registry.lookup_error_to_string error)
  in
  Projection.remove ~base_path ~keeper_name:declared owner;
  Fun.protect
    ~finally:(fun () -> Projection.install ~base_path ~keeper_name:declared owner)
    (fun () ->
      take_the_task config key_removed;
      ignore (handed_meta config key_removed : Meta.keeper_meta);
      Gc.full_major ();
      Alcotest.(check bool)
        "let go once another Keeper's read-back is kept"
        false
        (Weak.check kept 0))
;;

(* The consumers of a Keeper whose Owner stands for its file do not open the
   file: they answer the same row when it holds no snapshot. *)
let test_row_of_an_owned_keeper_needs_no_meta_file () =
  with_three_keepers
  @@ fun config ->
  List.iter
    (fun name ->
      let with_the_file =
        List.map (fun (consumer_name, consumer) -> consumer_name, consumer config name) consumers
      in
      write_file (meta_path config name) "not a snapshot";
      List.iter
        (fun (consumer_name, consumer) ->
          Alcotest.check
            row
            (Printf.sprintf "%s of %s, its meta file unreadable" consumer_name name)
            (List.assoc consumer_name with_the_file)
            (consumer config name))
        consumers;
      match from_the_file config name (fun () -> board_address config name) with
      | Error _ -> ()
      | Ok address ->
        Alcotest.failf
          "%s: the file read still found a meta, so the case above shows nothing: %s"
          name
          address)
    keepers
;;

(* The operator snapshot walks every configured Keeper to name the ones meant
   to keep running, for every snapshot it builds
   ([Keeper_meta_store.persistent_agent_names_with_unread]). [persistent] is
   that walk's answer for the read it is given: the names, and the Keepers
   whose stored meta did not read. *)
let persistent config ~read_meta =
  let names, unread = Store.persistent_agent_names_with_unread config ~read_meta in
  names, List.map (fun (unread : Masc.Keeper_snapshot_unread.t) -> unread.name) unread
;;

(* The read the snapshot gives the walk. *)
let asking_the_owners config name =
  Stored_meta.read config name ~read_file:(fun () -> Store.read_meta config name)
;;

(* With the Owners standing for the meta files the walk answers from them:
   its answer is the same with every file unreadable. Given the file read
   alone, as it read before, the same walk then names no Keeper. *)
let test_the_walk_of_owned_keepers_needs_no_meta_file () =
  with_three_keepers
  @@ fun config ->
  let walk = Alcotest.(pair (list string) (list string)) in
  let with_the_files = persistent config ~read_meta:(asking_the_owners config) in
  Alcotest.check
    walk
    "the walk that asks the Owners answers what the files give"
    (persistent config ~read_meta:(Store.read_meta config))
    with_the_files;
  Alcotest.(check (list string))
    "every Keeper of the fixture is meant to keep running"
    (List.sort String.compare keepers)
    (List.sort String.compare (fst with_the_files));
  List.iter (fun name -> write_file (meta_path config name) "not a snapshot") keepers;
  Alcotest.check
    walk
    "with every meta file unreadable"
    with_the_files
    (persistent config ~read_meta:(asking_the_owners config));
  Alcotest.(check (list string))
    "the file read alone names no Keeper: the answer above did not come from the files"
    []
    (fst (persistent config ~read_meta:(Store.read_meta config)))
;;

(* {1 The file is read} *)

let check_the_file_answer_is_handed_out config name =
  List.iter
    (fun (label, file_answer) ->
      let file_reads = ref 0 in
      let handed =
        Stored_meta.read config name ~read_file:(fun () ->
          incr file_reads;
          file_answer)
      in
      Alcotest.(check int) (label ^ ": the file is read once") 1 !file_reads;
      Alcotest.(check bool)
        (label ^ ": the file's answer is handed out as it is")
        true
        (handed == file_answer))
    [ "a meta", Ok (Some (fixture_meta name))
    ; "no meta", Ok None
    ; "a failed read", Error "unreadable"
    ]
;;

let test_keeper_without_an_owner_is_read_from_its_file () =
  with_workspace
  @@ fun ~clock:_ config ->
  let name = "stored-meta-no-owner" in
  declare config name ~addressed:true;
  leave_snapshot config (fixture_meta name);
  check_the_file_answer_is_handed_out config name;
  (match board_address config name with
   | Ok _ -> ()
   | Error other -> Alcotest.failf "a Keeper with a meta file has no address: %s" other);
  Alcotest.check
    row
    "a Keeper with no meta file has no address"
    (Error
       (Yojson.Safe.to_string
          (Board_address.to_yojson (Board_address.Unavailable Board_address.Metadata_absent))))
    (board_address config "stored-meta-never-created")
;;

let accepting : Owner.store = { replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }

let test_owner_without_a_meta_leaves_the_read_to_the_file () =
  with_workspace
  @@ fun ~clock:_ config ->
  let name = "stored-meta-owner-without-meta" in
  Eio.Switch.run
  @@ fun sw ->
  let owner = start_owner ~sw config ~store:accepting ~keeper_name:name ~initial_meta:None in
  with_installed config name owner
  @@ fun () -> check_the_file_answer_is_handed_out config name
;;

(* A store whose write reaches the file and then ends as [ending] says. The
   file then holds the new meta and the Owner's memory the one before it. *)
let store_that_writes config ending : Owner.store =
  { replace =
      (fun meta ->
        leave_snapshot config meta;
        ending ())
  ; remove = (fun _ -> Alcotest.fail "unexpected remove")
  }
;;

let task_taken =
  Reducer.Set_current_task { task_id = Some held_task; updated_at = "task taken" }
;;

let check_the_owner_answers config name =
  let file_reads = ref 0 in
  let handed =
    Stored_meta.read config name ~read_file:(fun () ->
      incr file_reads;
      Store.read_meta config name)
  in
  Alcotest.(check int) "before the write the Owner answers" 0 !file_reads;
  Alcotest.(check (option string)) "and no task is held" None (held_task_of handed)
;;

let check_readers_get_the_file config name owner =
  Alcotest.(check bool)
    "the Owner says a meta write ended without a known outcome"
    true
    (Owner.meta_write_unsettled owner);
  Alcotest.(check (option string))
    "the Owner's memory keeps the meta from before the write"
    None
    (held_task_of (Ok (Owner.projection owner).Reducer.meta));
  let file_reads = ref 0 in
  let handed =
    Stored_meta.read config name ~read_file:(fun () ->
      incr file_reads;
      Store.read_meta config name)
  in
  Alcotest.(check int) "the file is read" 1 !file_reads;
  Alcotest.(check (option string))
    "the read gets the meta the write left in the file"
    (Some held_task_name)
    (held_task_of handed);
  match List_row.keeper_list_row_json ~runtime_class:"keeper" config name with
  | None -> Alcotest.fail "the Keeper has no list row"
  | Some row ->
    Alcotest.(check string)
      "the row shows the file's meta"
      "task taken"
      Yojson.Safe.Util.(row |> member "updated_at" |> to_string)
;;

let test_write_that_ended_in_error_sends_readers_to_the_file () =
  with_workspace
  @@ fun ~clock:_ config ->
  let name = "stored-meta-write-refused" in
  declare config name ~addressed:true;
  let initial = fixture_meta name in
  leave_snapshot config initial;
  Eio.Switch.run
  @@ fun sw ->
  let owner =
    start_owner
      ~sw
      config
      ~store:(store_that_writes config (fun () -> Error "durability unknown"))
      ~keeper_name:name
      ~initial_meta:(Some initial)
  in
  with_installed config name owner
  @@ fun () ->
  check_the_owner_answers config name;
  (match Owner.apply_meta owner task_taken with
   | Error (Owner.Store_unavailable _) -> ()
   | Ok _ | Error _ -> Alcotest.fail "the write that reported an error was accepted");
  check_readers_get_the_file config name owner
;;

let rec carries target = function
  | exn when exn == target -> true
  | Eio.Exn.Multiple exns -> List.exists (fun (exn, _) -> carries target exn) exns
  | Eio.Cancel.Cancelled exn -> carries target exn
  | _ -> false
;;

let test_write_that_raised_sends_readers_to_the_file () =
  with_workspace
  @@ fun ~clock config ->
  let name = "stored-meta-write-raised" in
  declare config name ~addressed:true;
  let initial = fixture_meta name in
  leave_snapshot config initial;
  let raised = Failure "write outcome unknown" in
  let started = ref None in
  let answer = ref None in
  (* The Owner's loop ends with the exception of its store, and that fails
     the switch the Owner runs under. The time limit turns an Owner that
     never ends into a failure of this case. *)
  (match
     Eio.Time.with_timeout_exn clock 60.0 (fun () ->
       Eio.Switch.run (fun sw ->
         let owner =
           start_owner
             ~sw
             config
             ~store:(store_that_writes config (fun () -> raise raised))
             ~keeper_name:name
             ~initial_meta:(Some initial)
         in
         started := Some owner;
         Projection.install ~base_path:config.Workspace.base_path ~keeper_name:name owner;
         check_the_owner_answers config name;
         answer := Some (Owner.apply_meta owner task_taken)))
   with
   | () -> Alcotest.fail "the store's exception did not leave the Owner"
   | exception exn when carries raised exn -> ());
  (match !answer with
   | Some (Ok _) -> Alcotest.fail "the write that raised was accepted"
   | Some (Error _) | None -> ());
  match !started with
  | None -> Alcotest.fail "the Owner did not start"
  | Some owner ->
    Fun.protect
      ~finally:(fun () ->
        Projection.remove ~base_path:config.Workspace.base_path ~keeper_name:name owner)
      (fun () -> check_readers_get_the_file config name owner)
;;

(* {1 An Owner meta that has no read-back} *)

let latest_log_seq () =
  match Log.Ring.recent ~limit:1 () with
  | entry :: _ -> entry.Log.Ring.seq
  | [] -> -1
;;

(* The warnings that say a Keeper's meta has no read-back. The ring is the
   log's in-process sink. *)
let no_read_back_warnings name ~since =
  Log.Ring.recent ~limit:1000 ~since_seq:since ~module_filter:"Keeper" ()
  |> List.filter (fun (entry : Log.Ring.entry) ->
    entry.level = Log.Warn
    && Option.equal String.equal entry.keeper_name (Some name)
    && Astring.String.is_infix ~affix:"does not read back" entry.message)
  |> List.length
;;

(* The encoder writes [agent_core_env] as the Owner holds it and the decoder
   refuses a key that comes twice, so the snapshot of this meta does not
   decode. The Owner cannot stand for a file read then. Every read goes to
   the file and hands out the file's answer, and the reason is logged once
   for the meta, not once for each read. *)
let test_meta_without_a_read_back_is_read_from_its_file () =
  with_workspace
  @@ fun ~clock:_ config ->
  let name = "stored-meta-no-read-back" in
  declare config name ~addressed:true;
  let held = { (fixture_meta name) with agent_core_env = [ "TWICE", "1"; "TWICE", "2" ] } in
  (match Store.snapshot_read_back held with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "the fixture meta reads back, so this case shows nothing");
  Eio.Switch.run
  @@ fun sw ->
  let owner =
    start_owner ~sw config ~store:accepting ~keeper_name:name ~initial_meta:(Some held)
  in
  with_installed config name owner
  @@ fun () ->
  (match
     Projection.meta_the_file_holds
       ~base_path:config.Workspace.base_path
       ~keeper_name:name
   with
   | Some standing ->
     Alcotest.(check (list (pair string string)))
       "the Owner stands for the file with the meta it was started with"
       held.agent_core_env
       standing.agent_core_env
   | None -> Alcotest.fail "the Owner does not stand for the file");
  let before = latest_log_seq () in
  check_the_file_answer_is_handed_out config name;
  Alcotest.(check int)
    "said once for the meta, however many reads it sent to the file"
    1
    (no_read_back_warnings name ~since:before)
;;

(* {1 The premise for an Owner that has written nothing} *)

(* Such an Owner holds what the decoder gave for a file of another process.
   Its read-back is that file's read only when one more trip through the
   snapshot leaves a decoded meta as it is. *)
let read_back label meta =
  match Store.snapshot_read_back meta with
  | Ok read -> read
  | Error detail -> Alcotest.failf "%s: the snapshot does not read back: %s" label detail
;;

let test_read_back_of_a_decoded_meta_is_that_meta () =
  with_workspace
  @@ fun ~clock:_ config ->
  List.iter
    (fun (label, meta) ->
      let decoded = read_back label meta in
      check_same_meta label decoded (read_back label decoded))
    [ "a new Keeper's meta", fixture_meta "stored-meta-new"
    ; "a meta with its stored fields filled", busy_meta "stored-meta-busy"
    ; ( "a meta with its usage accounting, a pause and an id"
      , accounted_meta "stored-meta-accounted" )
    ; ( "a meta that holds TOML values"
      , { (busy_meta "stored-meta-configured") with
          mention_targets = [ "ops" ]
        ; board_interests = [ "runtime" ]
        ; activation_mode = Masc.Keeper_activation_mode.Manual
        ; max_context_override = Some 4242
        } )
    ];
  let name = "stored-meta-foreign-file" in
  let label = "a meta decoded from a file of another process" in
  ignore (leave_foreign_snapshot config (accounted_meta name) : string);
  match Store.read_meta config name with
  | Ok (Some decoded) ->
    Alcotest.(check bool)
      (label ^ ": the file's usage cursor was decoded")
      true
      (Option.is_some decoded.runtime.usage_cursor);
    check_same_meta label decoded (read_back label decoded)
  | Ok None -> Alcotest.fail "the fixture file holds no meta"
  | Error detail -> Alcotest.failf "the fixture file did not read: %s" detail
;;

let () =
  Alcotest.run
    "keeper_stored_meta"
    [ ( "the Owner's answer is the file's"
      , [ Alcotest.test_case
            "consumers answer what the file gives"
            `Quick
            test_consumers_answer_what_the_file_gives
        ; Alcotest.test_case
            "the Owner hands out the file read"
            `Quick
            test_owner_hands_out_the_file_read
        ; Alcotest.test_case
            "the handed meta follows the Owner's commits"
            `Quick
            test_handed_meta_follows_the_owner_commits
        ; Alcotest.test_case
            "the row of an owned Keeper needs no meta file"
            `Quick
            test_row_of_an_owned_keeper_needs_no_meta_file
        ; Alcotest.test_case
            "the walk of owned Keepers needs no meta file"
            `Quick
            test_the_walk_of_owned_keepers_needs_no_meta_file
        ] )
    ; ( "the read-back is kept"
      , [ Alcotest.test_case
            "made once for a published meta"
            `Quick
            test_read_back_is_made_once_for_a_published_meta
        ; Alcotest.test_case
            "let go with its Owner"
            `Quick
            test_read_back_is_let_go_with_its_owner
        ] )
    ; ( "the file is read"
      , [ Alcotest.test_case
            "a Keeper without an Owner"
            `Quick
            test_keeper_without_an_owner_is_read_from_its_file
        ; Alcotest.test_case
            "an Owner without a meta"
            `Quick
            test_owner_without_a_meta_leaves_the_read_to_the_file
        ; Alcotest.test_case
            "a meta write that ended in an error"
            `Quick
            test_write_that_ended_in_error_sends_readers_to_the_file
        ; Alcotest.test_case
            "a meta write that raised"
            `Quick
            test_write_that_raised_sends_readers_to_the_file
        ; Alcotest.test_case
            "an Owner meta that has no read-back"
            `Quick
            test_meta_without_a_read_back_is_read_from_its_file
        ] )
    ; ( "read-back premise"
      , [ Alcotest.test_case
            "the read-back of a decoded meta is that meta"
            `Quick
            test_read_back_of_a_decoded_meta_is_that_meta
        ] )
    ]
;;
