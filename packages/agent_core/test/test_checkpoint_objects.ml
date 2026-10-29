(* RFC-0476 L1-3a: a checkpoint as a head and content-addressed objects. *)
open Agent_core
module O = Checkpoint_objects

let checkpoint messages : Checkpoint.t =
  { provider_binding = None
  ; version = Checkpoint.checkpoint_version
  ; session_id = "objects-session"
  ; agent_name = "objects-agent"
  ; model = "objects-model"
  ; system_prompt = Some "be brief"
  ; messages
  ; usage = Types.empty_usage
  ; turn_count = List.length messages
  ; created_at = 1000.0
  ; tools = []
  ; tool_choice = None
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; response_format = Types.Off
  ; reasoning_effort = None
  ; cache_system_prompt = false
  ; context = Context.create_sync ()
  ; pending_input = None
  ; mcp_sessions = []
  ; working_context = None
  }
;;

let user text = Types.user_msg text
let assistant text = Types.assistant_msg text
let turn n = [ user (Printf.sprintf "ask %d" n); assistant (Printf.sprintf "answer %d" n) ]

(* An object store in a table, as the Keeper store's directory would hold. *)
let store () = Hashtbl.create 16

let write store (plan : O.plan) =
  List.iter (fun (digest, bytes) -> Hashtbl.replace store (digest : O.digest :> string) bytes) plan.objects
;;

let read store digest = Ok (Hashtbl.find_opt store (digest : O.digest :> string))

let plan_ok ?previous ?absent memo boundary cp =
  match O.plan_save memo ?previous ?absent boundary cp with
  | Ok plan -> plan
  | Error error -> Alcotest.fail (Error.to_string error)
;;

let load_ok store (plan : O.plan) =
  let head =
    match O.head_of_string plan.head_bytes with
    | Ok head -> head
    | Error error -> Alcotest.fail (O.load_error_to_string error)
  in
  match O.load (O.create_memo ()) ~read_object:(read store) head with
  | Ok cp -> cp
  | Error error -> Alcotest.fail (O.load_error_to_string error)
;;

let same_messages label expected (actual : Checkpoint.t) =
  Alcotest.(check bool) label true
    (List.equal Types.Message_value.equal expected actual.messages)
;;

let object_count (plan : O.plan) = List.length plan.objects

(* The head and objects a save plans give back the checkpoint, and the head
   bytes decode to the head the plan holds. *)
let test_a_saved_checkpoint_loads_back () =
  let messages = turn 1 @ turn 2 in
  let store = store () in
  let open_plan = plan_ok (O.create_memo ()) O.Turn_continues (checkpoint messages) in
  write store open_plan;
  Alcotest.(check int) "every open message is an object" 4 (object_count open_plan);
  same_messages "open messages load back" messages (load_ok store open_plan);
  let closed_plan = plan_ok (O.create_memo ()) O.Turn_closes (checkpoint messages) in
  write store closed_plan;
  Alcotest.(check int) "a closed turn is one bundle" 1 (object_count closed_plan);
  (* The blob sweep and an operator read a bundle as JSON lines. *)
  let _, bundle = List.hd closed_plan.objects in
  let lines = String.split_on_char '\n' bundle |> List.filter (fun line -> line <> "") in
  Alcotest.(check int) "a bundle is its header and one line per message" 5 (List.length lines);
  List.iter (fun line -> ignore (Yojson.Safe.from_string line : Yojson.Safe.t)) lines;
  same_messages "the bundle loads back" messages (load_ok store closed_plan);
  Alcotest.(check int) "the head counts the messages" 4 (O.message_count closed_plan.head.history)
;;

(* A save after more messages keeps the turns it already wrote and writes
   only what is new. *)
let test_a_save_writes_only_what_is_new () =
  let memo = O.create_memo () in
  let store = store () in
  let first = plan_ok memo O.Turn_closes (checkpoint (turn 1)) in
  write store first;
  let second = plan_ok memo ~previous:first.head.history O.Turn_closes (checkpoint (turn 1 @ turn 2)) in
  write store second;
  Alcotest.(check int) "only the new turn's bundle is written" 1 (object_count second);
  Alcotest.(check int) "the first turn is kept" 2 (List.length second.head.history.turns);
  Alcotest.(check bool) "the kept turn is the same turn" true
    (List.hd second.head.history.turns = List.hd first.head.history.turns);
  let growing = plan_ok memo ~previous:second.head.history O.Turn_continues (checkpoint (turn 1 @ turn 2 @ [ user "ask 3" ])) in
  write store growing;
  Alcotest.(check int) "one open message" 1 (object_count growing);
  let grown =
    plan_ok memo ~previous:growing.head.history O.Turn_continues
      (checkpoint (turn 1 @ turn 2 @ turn 3))
  in
  write store grown;
  Alcotest.(check int) "an open message already written is not written again" 1 (object_count grown);
  same_messages "the history loads back" (turn 1 @ turn 2 @ turn 3) (load_ok store grown)
;;

(* A change before the last turn drops the turns from the change on; their
   messages are open again and written as objects. *)
let test_a_changed_turn_is_written_again () =
  let memo = O.create_memo () in
  let store = store () in
  let first = plan_ok memo O.Turn_closes (checkpoint (turn 1)) in
  write store first;
  let second = plan_ok memo ~previous:first.head.history O.Turn_closes (checkpoint (turn 1 @ turn 2)) in
  write store second;
  let edited = [ user "ask 1"; assistant "edited answer" ] @ turn 2 in
  let replanned = plan_ok memo ~previous:second.head.history O.Turn_continues (checkpoint edited) in
  write store replanned;
  Alcotest.(check int) "no turn is kept" 0 (List.length replanned.head.history.turns);
  Alcotest.(check int) "every message is open" 4 (List.length replanned.head.history.open_messages);
  same_messages "the edited history loads back" edited (load_ok store replanned)
;;

(* The chain a turn names is the chain over every message up to its end. *)
let test_a_turn_names_the_chain_of_its_prefix () =
  let memo = O.create_memo () in
  let first = plan_ok memo O.Turn_closes (checkpoint (turn 1)) in
  let second = plan_ok memo ~previous:first.head.history O.Turn_closes (checkpoint (turn 1 @ turn 2)) in
  let open_plan = plan_ok (O.create_memo ()) O.Turn_continues (checkpoint (turn 1 @ turn 2)) in
  let from_scratch =
    List.fold_left O.chain_step O.chain_start open_plan.head.history.open_messages
  in
  let last = List.nth second.head.history.turns 1 in
  Alcotest.(check string) "the last turn's chain covers every message"
    (from_scratch :> string) (last.chain :> string)
;;

(* Saving what a load gave writes nothing and gives the same head bytes. *)
let test_a_loaded_checkpoint_saves_unchanged () =
  let store = store () in
  let memo = O.create_memo () in
  let first = plan_ok memo O.Turn_closes (checkpoint (turn 1)) in
  write store first;
  let continued = plan_ok memo ~previous:first.head.history O.Turn_continues (checkpoint (turn 1 @ [ user "ask 2" ])) in
  write store continued;
  let head = Result.get_ok (O.head_of_string continued.head_bytes) in
  let load_memo = O.create_memo () in
  let loaded = Result.get_ok (O.load load_memo ~read_object:(read store) head) in
  let again = plan_ok load_memo ~previous:head.history O.Turn_continues loaded in
  Alcotest.(check int) "nothing to write" 0 (object_count again);
  Alcotest.(check string) "the same head bytes" continued.head_bytes again.head_bytes
;;

let load_error store head_bytes =
  match O.head_of_string head_bytes with
  | Error error -> Some error
  | Ok head ->
    (match O.load (O.create_memo ()) ~read_object:(read store) head with
     | Ok _ -> None
     | Error error -> Some error)
;;

let test_a_load_refuses_what_it_cannot_prove () =
  let plan = plan_ok (O.create_memo ()) O.Turn_closes (checkpoint (turn 1)) in
  let bundle, bytes = List.hd plan.objects in
  let key = (bundle :> string) in
  (match load_error (store ()) plan.head_bytes with
   | Some (O.Object_missing _) -> ()
   | Some _ | None -> Alcotest.fail "a missing bundle must be Object_missing");
  let corrupt = store () in
  Hashtbl.replace corrupt key (bytes ^ " ");
  (match load_error corrupt plan.head_bytes with
   | Some (O.Object_digest_mismatch _) -> ()
   | Some _ | None -> Alcotest.fail "changed bytes must be Object_digest_mismatch");
  (* The bundle is intact but the head names another message count for it. *)
  let intact = store () in
  Hashtbl.replace intact key bytes;
  let miscounted =
    Yojson.Safe.to_string
      (match Yojson.Safe.from_string plan.head_bytes with
       | `Assoc fields ->
         `Assoc
           (List.map
              (fun (name, value) ->
                 match name, value with
                 | "history", `Assoc [ ("turns", `List [ `Assoc turn ]); open_field ] ->
                   ( name
                   , `Assoc
                       [ ( "turns"
                         , `List
                             [ `Assoc
                                 (List.map
                                    (fun (field, field_value) ->
                                       if String.equal field "messages" then field, `Int 3 else field, field_value)
                                    turn) ] )
                       ; open_field ] )
                 | _ -> name, value)
              fields)
       | json -> json)
  in
  (match load_error intact miscounted with
   | Some (O.Turn_mismatch _) -> ()
   | Some _ | None -> Alcotest.fail "a turn that names another count must be Turn_mismatch");
  (* The head names another chain for an intact bundle. *)
  let rechained =
    Yojson.Safe.to_string
      (match Yojson.Safe.from_string plan.head_bytes with
       | `Assoc fields ->
         `Assoc
           (List.map
              (fun (name, value) ->
                 match name, value with
                 | "history", `Assoc [ ("turns", `List [ `Assoc turn ]); open_field ] ->
                   ( name
                   , `Assoc
                       [ ( "turns"
                         , `List
                             [ `Assoc
                                 (List.map
                                    (fun (field, field_value) ->
                                       if String.equal field "chain"
                                       then field, `String (O.chain_start :> string)
                                       else field, field_value)
                                    turn) ] )
                       ; open_field ] )
                 | _ -> name, value)
              fields)
       | json -> json)
  in
  (match load_error intact rechained with
   | Some (O.Turn_mismatch _) -> ()
   | Some _ | None -> Alcotest.fail "a turn that names another chain must be Turn_mismatch");
  (* A bundle stored under its own digest whose header names a digest its
     message bytes do not have. *)
  let newline = String.index bytes '\n' in
  let body = String.sub bytes (newline + 1) (String.length bytes - newline - 1) in
  let lying =
    Printf.sprintf {|{"messages":[{"sha256":"%s","bytes":%d}]}|} (String.make 64 'a') (String.length body - 1)
    ^ "\n" ^ body
  in
  let lying_digest = O.digest_of_bytes lying in
  let lying_store = store () in
  Hashtbl.replace lying_store (lying_digest :> string) lying;
  let lying_head =
    Yojson.Safe.to_string
      (match Yojson.Safe.from_string plan.head_bytes with
       | `Assoc fields ->
         `Assoc
           (List.map
              (fun (name, value) ->
                 match name, value with
                 | "history", `Assoc [ ("turns", `List [ `Assoc turn ]); open_field ] ->
                   ( name
                   , `Assoc
                       [ ( "turns"
                         , `List
                             [ `Assoc
                                 (List.map
                                    (fun (field, field_value) ->
                                       match field with
                                       | "bundle" -> field, `String (lying_digest :> string)
                                       | "messages" -> field, `Int 1
                                       | _ -> field, field_value)
                                    turn) ] )
                       ; open_field ] )
                 | _ -> name, value)
              fields)
       | json -> json)
  in
  (match load_error lying_store lying_head with
   | Some (O.Bundle_invalid _) -> ()
   | Some _ | None -> Alcotest.fail "a header that names another digest must be Bundle_invalid");
  (* The same messages and header, but a message does not end its line. *)
  let unseparated =
    match String.split_on_char '\n' bytes with
    | [ header; first; second; "" ] -> String.concat "" [ header; "\n"; first; " "; second; "\n" ]
    | _ -> Alcotest.fail "expected a header and two message lines"
  in
  let unseparated_digest = O.digest_of_bytes unseparated in
  let unseparated_store = store () in
  Hashtbl.replace unseparated_store (unseparated_digest :> string) unseparated;
  let unseparated_head =
    Yojson.Safe.to_string
      (match Yojson.Safe.from_string plan.head_bytes with
       | `Assoc fields ->
         `Assoc
           (List.map
              (fun (name, value) ->
                 match name, value with
                 | "history", `Assoc [ ("turns", `List [ `Assoc turn ]); open_field ] ->
                   ( name
                   , `Assoc
                       [ ( "turns"
                         , `List
                             [ `Assoc
                                 (List.map
                                    (fun (field, field_value) ->
                                       if String.equal field "bundle"
                                       then field, `String (unseparated_digest :> string)
                                       else field, field_value)
                                    turn) ] )
                       ; open_field ] )
                 | _ -> name, value)
              fields)
       | json -> json)
  in
  (match load_error unseparated_store unseparated_head with
   | Some (O.Bundle_invalid _) -> ()
   | Some _ | None -> Alcotest.fail "a message that does not end its line must be Bundle_invalid");
  let with_messages =
    Yojson.Safe.to_string
      (match Yojson.Safe.from_string plan.head_bytes with
       | `Assoc fields ->
         `Assoc
           (List.map
              (fun (name, value) ->
                 if String.equal name "format" then name, `String "another.format" else name, value)
              fields)
       | json -> json)
  in
  match load_error (store ()) with_messages with
  | Some (O.Head_invalid _) -> ()
  | Some _ | None -> Alcotest.fail "a head of another format must be Head_invalid"
;;

(* A value and every head written for it, whatever its turns, have one
   content digest; another header or another message gives another. *)
let test_one_content_digest_for_every_layout () =
  let value =
    { (checkpoint (turn 1 @ turn 2)) with temperature = Some 0.7; created_at = 1234.5678 }
  in
  let digest_of_value cp =
    match O.content_digest (O.create_memo ()) cp with
    | Ok digest -> (digest :> string)
    | Error error -> Alcotest.fail (Error.to_string error)
  in
  let digest_of_head (plan : O.plan) =
    match O.head_of_string plan.head_bytes with
    | Ok head -> (O.head_content_digest head :> string)
    | Error error -> Alcotest.fail (O.load_error_to_string error)
  in
  let expected = digest_of_value value in
  let memo = O.create_memo () in
  let first = plan_ok memo O.Turn_closes { value with messages = turn 1 } in
  let layouts =
    [ "all open", plan_ok (O.create_memo ()) O.Turn_continues value
    ; "one bundle", plan_ok (O.create_memo ()) O.Turn_closes value
    ; "a bundle then open", plan_ok memo ~previous:first.head.history O.Turn_continues value
    ]
  in
  List.iter
    (fun (label, (plan : O.plan)) ->
       Alcotest.(check string) (label ^ ": the plan names the value's digest") expected (plan.content :> string);
       Alcotest.(check string) (label ^ ": the head gives the same digest") expected (digest_of_head plan))
    layouts;
  Alcotest.(check bool) "another header gives another digest" false
    (String.equal expected (digest_of_value { value with turn_count = 9 }));
  Alcotest.(check bool) "another message gives another digest" false
    (String.equal expected (digest_of_value { value with messages = turn 1 @ turn 3 }))
;;

(* A document that is not a head names its version when that version is not
   this build's, and is invalid otherwise. *)
let test_a_document_that_is_not_a_head () =
  let flat version =
    Yojson.Safe.to_string (`Assoc [ "version", `Int version; "session_id", `String "s" ])
  in
  let earlier = Checkpoint.checkpoint_version - 1 in
  (match O.head_of_string (flat earlier) with
   | Error
       (O.Checkpoint_invalid
          (Error.Serialization (VersionMismatch { expected; got })))
     when expected = Checkpoint.checkpoint_version && got = earlier -> ()
   | Ok _ | Error _ -> Alcotest.fail "an earlier version must be reported as that version");
  match O.head_of_string (flat Checkpoint.checkpoint_version) with
  | Error (O.Head_invalid _) -> ()
  | Ok _ | Error _ -> Alcotest.fail "this build's version without a head must be Head_invalid"
;;

(* A checkpoint whose header fields are not the defaults and whose messages
   hold several kinds of content: the plan, its head and the value give one
   content digest, and the loaded value encodes to the same objects, so a
   save with a fresh memo after a load names the same digest. *)
let test_a_rich_checkpoint_keeps_its_digest_and_bytes () =
  let message role content : Types.message =
    { origin = Llm_provider.Types.Conversation; role; content; name = None
    ; tool_call_id = None; metadata = [] }
  in
  let messages =
    [ user "find the weather"
    ; message Assistant
        [ Types.Thinking { content = "use the tool"; signature = Some "sig-1" }
        ; Types.ToolUse { id = "call-1"; name = "get_weather"; input = `Assoc [ "city", `String "Seoul" ] }
        ]
    ; message Tool
        [ Types.ToolResult
            { tool_use_id = "call-1"; content = "rain"; outcome = Llm_provider.Types.Tool_succeeded
            ; json = None; content_blocks = None } ]
    ; message Assistant [ Types.Text "It rains in Seoul." ]
    ]
  in
  let context = Context.create_sync () in
  Context.set context "turn_note" (`String "kept");
  let rich =
    { (checkpoint messages) with
      tools =
        [ Types.tool_schema_of_params ~name:"get_weather" ~description:"Weather for a city"
            ~parameters:[ { Types.name = "city"; description = "City"; param_type = Types.String; required = true } ]
            () ]
    ; temperature = Some 0.3
    ; top_p = Some 0.9
    ; reasoning_effort = Some Llm_provider.Reasoning_effort.High
    ; cache_system_prompt = true
    ; context
    ; working_context = Some (`Assoc [ "goal", `String "weather" ])
    }
  in
  let store = store () in
  let plan = plan_ok (O.create_memo ()) O.Turn_closes rich in
  write store plan;
  let value_digest =
    match O.content_digest (O.create_memo ()) rich with
    | Ok digest -> (digest :> string)
    | Error error -> Alcotest.fail (Error.to_string error)
  in
  let head_digest =
    match O.head_of_string plan.head_bytes with
    | Ok head -> (O.head_content_digest head :> string)
    | Error error -> Alcotest.fail (O.load_error_to_string error)
  in
  Alcotest.(check string) "the plan names the value's digest" value_digest (plan.content :> string);
  Alcotest.(check string) "the head gives the same digest" value_digest head_digest;
  let loaded = load_ok store plan in
  let again = plan_ok (O.create_memo ()) O.Turn_closes loaded in
  Alcotest.(check string) "the loaded value names the same digest" value_digest (again.content :> string);
  Alcotest.(check (list (pair string string))) "and encodes to the same objects"
    (List.map (fun ((digest : O.digest), bytes) -> (digest :> string), bytes) plan.objects)
    (List.map (fun ((digest : O.digest), bytes) -> (digest :> string), bytes) again.objects);
  Alcotest.(check string) "and the same head" plan.head_bytes again.head_bytes
;;

(* A memo that saw the last plan or load takes the entries and chain values
   of the messages that begin as before; a fresh memo encodes and hashes
   everything. Over appends, edits, cuts, closed turns and a load, both give
   the same plan, byte for byte. *)
let test_a_memo_gives_the_plan_a_fresh_memo_gives () =
  let random = Random.State.make [| 476 |] in
  let changes = [| `Edit; `Cut; `Append; `Append; `Append; `Append |] in
  let store = store () in
  let memo = O.create_memo () in
  let fresh_plan ?previous boundary cp = plan_ok ?previous (O.create_memo ()) boundary cp in
  let same label (expected : O.plan) (actual : O.plan) =
    Alcotest.(check string) (label ^ ": head") expected.head_bytes actual.head_bytes;
    Alcotest.(check string) (label ^ ": content") (expected.content :> string) (actual.content :> string);
    Alcotest.(check (list (pair string string))) (label ^ ": objects")
      (List.map (fun ((digest : O.digest), bytes) -> (digest :> string), bytes) expected.objects)
      (List.map (fun ((digest : O.digest), bytes) -> (digest :> string), bytes) actual.objects)
  in
  let rec step index previous messages =
    if index < 60 then (
      let messages =
        match changes.(Random.State.int random (Array.length changes)), messages with
        | `Edit, _ :: _ ->
          (* An edit somewhere: that message and the ones after it differ. *)
          let at = Random.State.int random (List.length messages) in
          List.mapi (fun i m -> if i = at then user (Printf.sprintf "edited %d at %d" index i) else m) messages
        | `Cut, _ :: _ :: _ -> List.filteri (fun i _ -> i < List.length messages - 1) messages
        | (`Edit | `Cut | `Append), _ -> messages @ turn index
      in
      let boundary = if Random.State.bool random then O.Turn_closes else O.Turn_continues in
      let cp = checkpoint messages in
      let planned = plan_ok ?previous memo boundary cp in
      same (Printf.sprintf "step %d" index) (fresh_plan ?previous boundary cp) planned;
      (match O.content_digest memo cp with
       | Ok digest ->
         Alcotest.(check string) (Printf.sprintf "step %d: value digest" index)
           (planned.content :> string) (digest :> string)
       | Error error -> Alcotest.fail (Error.to_string error));
      write store planned;
      (* Every tenth step goes through a load, as a restart would. *)
      let messages =
        if index mod 10 = 9 then (
          match O.head_of_string planned.head_bytes with
          | Error error -> Alcotest.fail (O.load_error_to_string error)
          | Ok head ->
            (match O.load memo ~read_object:(read store) head with
             | Ok loaded -> loaded.messages
             | Error error -> Alcotest.fail (O.load_error_to_string error)))
        else planned.decoded.messages
      in
      step (index + 1) (Some planned.head.history) messages)
  in
  step 0 None []
;;

(* A later binary's head reads as its version even when its shape is not this
   build's: another top-level field, another format. *)
let test_a_later_head_reads_as_its_version () =
  let later = Checkpoint.checkpoint_version + 1 in
  let plan = plan_ok (O.create_memo ()) O.Turn_closes (checkpoint (turn 1)) in
  let later_head =
    match Yojson.Safe.from_string plan.head_bytes with
    | `Assoc fields ->
      let fields =
        List.map
          (fun (name, value) ->
             match name with
             | "format" -> name, `String "masc.checkpoint.head.later"
             | "checkpoint" ->
               (match value with
                | `Assoc checkpoint ->
                  ( name
                  , `Assoc
                      (List.map
                         (fun (field, value) ->
                            if String.equal field "version" then field, `Int later else field, value)
                         checkpoint) )
                | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
                  Alcotest.fail "head.checkpoint is an object")
             | _ -> name, value)
          fields
      in
      Yojson.Safe.to_string (`Assoc (fields @ [ "objects_root", `String "elsewhere" ]))
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Alcotest.fail "a head is an object"
  in
  match O.head_of_string later_head with
  | Error
      (O.Checkpoint_invalid (Error.Serialization (VersionMismatch { expected; got })))
    when expected = Checkpoint.checkpoint_version && got = later -> ()
  | Ok _ | Error _ -> Alcotest.fail "a later head must be reported as its version"
;;

(* Objects the previous head names but the store does not hold are written
   again from the messages in hand, so the next head names only what is
   there. *)
let test_an_absent_object_is_written_again () =
  let memo = O.create_memo () in
  let store = store () in
  let first = plan_ok memo O.Turn_closes (checkpoint (turn 1)) in
  write store first;
  let messages = turn 1 @ [ user "ask 2" ] in
  let second = plan_ok memo ~previous:first.head.history O.Turn_continues (checkpoint messages) in
  write store second;
  let bundle = (List.hd second.head.history.turns).bundle in
  let open_message = List.hd second.head.history.open_messages in
  Alcotest.(check (list string)) "the head names its bundle and its open message"
    [ (bundle :> string); (open_message :> string) ]
    (List.map (fun (digest : O.digest) -> (digest :> string)) (O.history_objects second.head.history));
  Hashtbl.remove store (bundle :> string);
  Hashtbl.remove store (open_message :> string);
  let unchanged =
    plan_ok memo ~previous:second.head.history O.Turn_continues (checkpoint messages)
  in
  Alcotest.(check int) "a save that trusts the head writes nothing" 0 (object_count unchanged);
  let third =
    plan_ok memo ~previous:second.head.history ~absent:[ bundle; open_message ] O.Turn_continues
      (checkpoint messages)
  in
  Alcotest.(check (list string)) "the absent bundle and message are written again"
    [ (bundle :> string); (open_message :> string) ]
    (List.map (fun ((digest : O.digest), _) -> (digest :> string)) third.objects);
  Alcotest.(check bool) "the turn is kept as it was" true
    (third.head.history.turns = second.head.history.turns);
  write store third;
  same_messages "the history loads back" messages (load_ok store third)
;;

let () =
  Alcotest.run "checkpoint_objects"
    [ ( "save and load"
      , [ Alcotest.test_case "a saved checkpoint loads back" `Quick test_a_saved_checkpoint_loads_back
        ; Alcotest.test_case "a save writes only what is new" `Quick test_a_save_writes_only_what_is_new
        ; Alcotest.test_case "a changed turn is written again" `Quick test_a_changed_turn_is_written_again
        ; Alcotest.test_case "a turn names the chain of its prefix" `Quick
            test_a_turn_names_the_chain_of_its_prefix
        ; Alcotest.test_case "a loaded checkpoint saves unchanged" `Quick
            test_a_loaded_checkpoint_saves_unchanged
        ; Alcotest.test_case "one content digest for every layout" `Quick
            test_one_content_digest_for_every_layout
        ; Alcotest.test_case "an absent object is written again" `Quick
            test_an_absent_object_is_written_again
        ; Alcotest.test_case "a rich checkpoint keeps its digest and bytes" `Quick
            test_a_rich_checkpoint_keeps_its_digest_and_bytes
        ; Alcotest.test_case "a memo gives the plan a fresh memo gives" `Quick
            test_a_memo_gives_the_plan_a_fresh_memo_gives
        ] )
    ; ( "refusals"
      , [ Alcotest.test_case "a load refuses what it cannot prove" `Quick
            test_a_load_refuses_what_it_cannot_prove
        ; Alcotest.test_case "a document that is not a head" `Quick
            test_a_document_that_is_not_a_head
        ; Alcotest.test_case "a later head reads as its version" `Quick
            test_a_later_head_reads_as_its_version
        ] )
    ]
;;
