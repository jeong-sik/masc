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

(* The objects a plan writes for its messages: not the header objects, which
   a first save writes and a save with the same header does not. *)
let object_count (plan : O.plan) =
  List.length
    (List.filter
       (fun ((digest : O.digest), _) ->
          not
            (String.equal (digest :> string) (plan.head.header_objects.system_prompt :> string)
             || String.equal (digest :> string) (plan.head.header_objects.tools :> string)))
       plan.objects)
;;

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
  let bundle = List.assoc (List.hd closed_plan.head.history.turns).bundle closed_plan.objects in
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
  let second = plan_ok memo ~previous:first.head O.Turn_closes (checkpoint (turn 1 @ turn 2)) in
  write store second;
  Alcotest.(check int) "only the new turn's bundle is written" 1 (object_count second);
  Alcotest.(check int) "the first turn is kept" 2 (List.length second.head.history.turns);
  Alcotest.(check bool) "the kept turn is the same turn" true
    (List.hd second.head.history.turns = List.hd first.head.history.turns);
  let growing = plan_ok memo ~previous:second.head O.Turn_continues (checkpoint (turn 1 @ turn 2 @ [ user "ask 3" ])) in
  write store growing;
  Alcotest.(check int) "one open message" 1 (object_count growing);
  let grown =
    plan_ok memo ~previous:growing.head O.Turn_continues
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
  let second = plan_ok memo ~previous:first.head O.Turn_closes (checkpoint (turn 1 @ turn 2)) in
  write store second;
  let edited = [ user "ask 1"; assistant "edited answer" ] @ turn 2 in
  let replanned = plan_ok memo ~previous:second.head O.Turn_continues (checkpoint edited) in
  write store replanned;
  Alcotest.(check int) "no turn is kept" 0 (List.length replanned.head.history.turns);
  Alcotest.(check int) "every message is open" 4 (List.length replanned.head.history.open_messages);
  same_messages "the edited history loads back" edited (load_ok store replanned)
;;

(* The chain a turn names is the chain over every message up to its end. *)
let test_a_turn_names_the_chain_of_its_prefix () =
  let memo = O.create_memo () in
  let first = plan_ok memo O.Turn_closes (checkpoint (turn 1)) in
  let second = plan_ok memo ~previous:first.head O.Turn_closes (checkpoint (turn 1 @ turn 2)) in
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
  let continued = plan_ok memo ~previous:first.head O.Turn_continues (checkpoint (turn 1 @ [ user "ask 2" ])) in
  write store continued;
  let head = Result.get_ok (O.head_of_string continued.head_bytes) in
  let load_memo = O.create_memo () in
  let loaded = Result.get_ok (O.load load_memo ~read_object:(read store) head) in
  let again = plan_ok load_memo ~previous:head O.Turn_continues loaded in
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

(* [head_bytes] with its top-level fields changed by [edit]. *)
let with_head_edited head_bytes edit =
  match Yojson.Safe.from_string head_bytes with
  | `Assoc fields -> Yojson.Safe.to_string (`Assoc (List.map edit fields))
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Alcotest.fail "a head must be an object"
;;

(* [head_bytes] with its one closed turn's fields changed by [edit]. A head of
   another shape fails the test rather than passing through unchanged. *)
let with_turn_edited head_bytes edit =
  let edit_history = function
    | `Assoc history ->
      `Assoc
        (List.map
           (fun (field, value) ->
              match field, value with
              | "turns", `List [ `Assoc turn ] -> field, `List [ `Assoc (List.map edit turn) ]
              | "turns", (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _) ->
                Alcotest.fail "the head must name exactly one closed turn"
              | _, (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _) ->
                field, value)
           history)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Alcotest.fail "head.history must be an object"
  in
  with_head_edited head_bytes (fun (name, value) ->
    if String.equal name "history" then name, edit_history value else name, value)
;;

let set_field name replacement (field, value) =
  if String.equal field name then field, replacement else field, value
;;

(* Counts in the head must add up in an [int], even when no objects are
   read. Exactly [max_int] remains representable. *)
let test_an_overflowing_history_count_is_refused () =
  let plan = plan_ok (O.create_memo ()) O.Turn_closes (checkpoint (turn 1)) in
  let digest = `String (String.make 64 'a') in
  let history ~segment ~turns ~open_count =
    let segment =
      match segment with
      | None -> `Null
      | Some count -> `Assoc [ "segment", digest; "messages", `Int count; "chain", digest ]
    in
    let turn count = `Assoc [ "bundle", digest; "messages", `Int count; "chain", digest ] in
    `Assoc
      [ "segment", segment
      ; "turns", `List (List.map turn turns)
      ; "open", `List (List.init open_count (fun _ -> digest))
      ]
  in
  let parse history =
    with_head_edited plan.head_bytes (set_field "history" history) |> O.head_of_string
  in
  let refused label history =
    match parse history with
    | Error (O.Head_invalid _) -> ()
    | Ok _ | Error _ -> Alcotest.fail (label ^ ": expected Head_invalid")
  in
  refused "turn and open" (history ~segment:None ~turns:[ max_int ] ~open_count:1);
  refused "segment and turn" (history ~segment:(Some max_int) ~turns:[ 1 ] ~open_count:0);
  refused "two turns" (history ~segment:None ~turns:[ max_int; 1 ] ~open_count:0);
  refused "segment and open" (history ~segment:(Some max_int) ~turns:[] ~open_count:1);
  let accepted label history =
    match parse history with
    | Ok head -> Alcotest.(check int) label max_int (O.message_count head.history)
    | Error error -> Alcotest.fail (label ^ ": " ^ O.load_error_to_string error)
  in
  accepted "turn and open at max_int" (history ~segment:None ~turns:[ max_int - 1 ] ~open_count:1);
  accepted "segment and turn at max_int" (history ~segment:(Some (max_int - 1)) ~turns:[ 1 ] ~open_count:0)
;;

(* Even a malformed bundle can have a valid content digest. Its declared
   message length must be checked without overflowing the byte offset. *)
let test_an_overflowing_bundle_length_is_refused () =
  let plan = plan_ok (O.create_memo ()) O.Turn_closes (checkpoint (turn 1)) in
  let bundle =
    Printf.sprintf {|{"messages":[{"sha256":"%s","bytes":%d}]}|}
      (String.make 64 'a') max_int ^ "\n"
  in
  let digest = O.digest_of_bytes bundle in
  let objects = store () in
  write objects plan;
  Hashtbl.replace objects (digest :> string) bundle;
  let head_bytes =
    with_turn_edited plan.head_bytes (fun field ->
      set_field "messages" (`Int 1) (set_field "bundle" (`String (digest :> string)) field))
  in
  (match load_error objects head_bytes with
   | Some (O.Bundle_invalid _) -> ()
   | Some _ | None -> Alcotest.fail "an overflowing bundle length must be Bundle_invalid");
  let head = Result.get_ok (O.head_of_string head_bytes) in
  match O.find_last ~read_object:(read objects) head (fun _ -> None) with
  | Error (O.Bundle_invalid _) -> ()
  | Ok _ | Error _ -> Alcotest.fail "a preview must refuse an overflowing bundle length"
;;

let test_a_load_refuses_what_it_cannot_prove () =
  let plan = plan_ok (O.create_memo ()) O.Turn_closes (checkpoint (turn 1)) in
  let bundle = (List.hd plan.head.history.turns).bundle in
  let key = (bundle :> string) in
  let bytes = List.assoc bundle plan.objects in
  let full () =
    let objects = store () in
    write objects plan;
    objects
  in
  let without_bundle = full () in
  Hashtbl.remove without_bundle key;
  (match load_error without_bundle plan.head_bytes with
   | Some (O.Object_missing missing) when String.equal (missing :> string) key -> ()
   | Some _ | None -> Alcotest.fail "a missing bundle must be Object_missing");
  let corrupt = full () in
  Hashtbl.replace corrupt key (bytes ^ " ");
  (match load_error corrupt plan.head_bytes with
   | Some (O.Object_digest_mismatch _) -> ()
   | Some _ | None -> Alcotest.fail "changed bytes must be Object_digest_mismatch");
  (* The bundle is intact but the head names another message count for it. *)
  (match load_error (full ()) (with_turn_edited plan.head_bytes (set_field "messages" (`Int 3))) with
   | Some (O.Turn_mismatch _) -> ()
   | Some _ | None -> Alcotest.fail "a turn that names another count must be Turn_mismatch");
  (* The head names another chain for an intact bundle. *)
  (match
     load_error (full ())
       (with_turn_edited plan.head_bytes (set_field "chain" (`String (O.chain_start :> string))))
   with
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
  let lying_store = full () in
  Hashtbl.replace lying_store (lying_digest :> string) lying;
  let lying_head =
    with_turn_edited plan.head_bytes (fun field ->
      set_field "messages" (`Int 1) (set_field "bundle" (`String (lying_digest :> string)) field))
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
  let unseparated_store = full () in
  Hashtbl.replace unseparated_store (unseparated_digest :> string) unseparated;
  (match
     load_error unseparated_store
       (with_turn_edited plan.head_bytes (set_field "bundle" (`String (unseparated_digest :> string))))
   with
   | Some (O.Bundle_invalid _) -> ()
   | Some _ | None -> Alcotest.fail "a message that does not end its line must be Bundle_invalid");
  (* A header object whose bytes are not JSON, stored under their digest. *)
  let broken_tools = "not json" in
  let broken_digest = O.digest_of_bytes broken_tools in
  let broken_store = full () in
  Hashtbl.replace broken_store (broken_digest :> string) broken_tools;
  (match
     load_error broken_store
       (with_head_edited plan.head_bytes (fun (name, value) ->
          if String.equal name "header_objects"
          then (
            match value with
            | `Assoc objects -> name, `Assoc (List.map (set_field "tools" (`String (broken_digest :> string))) objects)
            | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
              Alcotest.fail "head.header_objects must be an object")
          else name, value))
   with
   | Some (O.Header_object_invalid _) -> ()
   | Some _ | None -> Alcotest.fail "a header object that is not JSON must be Header_object_invalid");
  match
    load_error (full ())
      (with_head_edited plan.head_bytes (set_field "format" (`String "another.format")))
  with
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
    ; "a bundle then open", plan_ok memo ~previous:first.head O.Turn_continues value
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
    if index < 300 then (
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
      step (index + 1) (Some planned.head) messages)
  in
  step 0 None []
;;

(* [count] turns closed one save at a time, each save naming the head before
   it, with every plan's objects written to [store]. *)
let close_turns ~store ~memo count =
  let rec close index previous messages plans =
    if index > count
    then List.rev plans, messages
    else (
      let messages = messages @ turn index in
      let plan = plan_ok ?previous memo O.Turn_closes (checkpoint messages) in
      write store plan;
      close (index + 1) (Some plan.head) plan.decoded.messages (plan :: plans))
  in
  close 1 None [] []
;;

(* A list shows a checkpoint from its head and the objects it takes: the
   newest message is one object, an old one is found walking back through the
   head's turns and every segment, and the header gives the creation time and
   the system prompt. *)
let test_a_list_reads_back_only_as_far_as_it_finds () =
  let store = store () in
  let memo = O.create_memo () in
  let plans, closed = close_turns ~store ~memo 200 in
  let last = List.nth plans (List.length plans - 1) in
  let open_plan =
    plan_ok ~previous:last.head memo O.Turn_continues
      (checkpoint (closed @ [ user "open ask"; assistant "open answer" ]))
  in
  write store open_plan;
  let head =
    match O.head_of_string open_plan.head_bytes with
    | Ok head -> head
    | Error error -> Alcotest.fail (O.load_error_to_string error)
  in
  let reads = ref 0 in
  let counted digest =
    incr reads;
    read store digest
  in
  let said text (message : Types.message) =
    if String.equal (Types.text_of_message message) text then Some text else None
  in
  let find text =
    reads := 0;
    match O.find_last ~read_object:counted head (said text) with
    | Ok found -> found
    | Error error -> Alcotest.fail (O.load_error_to_string error)
  in
  Alcotest.(check (option string)) "the newest message" (Some "open answer") (find "open answer");
  Alcotest.(check int) "is one object" 1 !reads;
  Alcotest.(check (option string)) "the oldest message" (Some "ask 1") (find "ask 1");
  Alcotest.(check int) "reads every open message, bundle and segment once"
    (2 + 200 + (200 / O.turns_per_segment))
    !reads;
  Alcotest.(check (option string)) "a message nobody said" None (find "never said");
  Alcotest.(check (float 0.)) "the header gives the creation time" 1000.0 head.header.created_at;
  match O.system_prompt ~read_object:(read store) head with
  | Ok prompt -> Alcotest.(check (option string)) "and the system prompt" (Some "be brief") prompt
  | Error error -> Alcotest.fail (O.load_error_to_string error)
;;

(* However many turns close, a head names fewer than a segment's worth of
   them; the rest are segments, each written once, and the history loads
   back whole. *)
let test_a_head_names_fewer_turns_than_a_segment () =
  let store = store () in
  let plans, messages = close_turns ~store ~memo:(O.create_memo ()) 200 in
  List.iter
    (fun (plan : O.plan) ->
       Alcotest.(check bool) "the head names fewer turns than a segment holds" true
         (List.length plan.head.history.turns < O.turns_per_segment))
    plans;
  let last = List.nth plans (List.length plans - 1) in
  (match last.head.history.segment with
   | Some segment ->
     Alcotest.(check int) "the segments hold the turns before the head's"
       (List.length (turn 1) * (200 / O.turns_per_segment * O.turns_per_segment))
       segment.segment_messages
   | None -> Alcotest.fail "200 closed turns make segments");
  let largest = List.fold_left (fun size (plan : O.plan) -> max size (String.length plan.head_bytes)) 0 plans in
  let at_capacity = String.length (List.nth plans (O.turns_per_segment - 2)).head_bytes in
  Alcotest.(check bool)
    (Printf.sprintf "no head is larger than one with %d turns and a segment (%d, %d)"
       (O.turns_per_segment - 1) largest at_capacity)
    true
    (largest <= at_capacity + 512);
  same_messages "the history loads back through its segments" messages (load_ok store last);
  (* The head names another message count for its last segment. *)
  let miscounted =
    with_head_edited last.head_bytes (fun (name, value) ->
      if String.equal name "history"
      then (
        match value with
        | `Assoc history ->
          ( name
          , `Assoc
              (List.map
                 (fun (field, field_value) ->
                    match field, field_value with
                    | "segment", `Assoc segment ->
                      ( field
                      , `Assoc
                          (List.map
                             (fun (key, key_value) ->
                                match key, key_value with
                                | "messages", `Int count -> key, `Int (count + 2)
                                | _, (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _) ->
                                  key, key_value)
                             segment) )
                    | _, (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _) ->
                      field, field_value)
                 history) )
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
          Alcotest.fail "head.history must be an object")
      else name, value)
  in
  match load_error store miscounted with
  | Some (O.Segment_invalid _) -> ()
  | Some _ | None -> Alcotest.fail "a segment the head miscounts must be Segment_invalid"
;;

(* A save writes a header object only when it differs from the previous
   head's. *)
let test_a_header_object_is_written_when_it_changes () =
  let memo = O.create_memo () in
  let first = plan_ok memo O.Turn_closes (checkpoint (turn 1)) in
  let header_digests (plan : O.plan) =
    [ (plan.head.header_objects.system_prompt :> string); (plan.head.header_objects.tools :> string) ]
  in
  let written (plan : O.plan) = List.map (fun ((digest : O.digest), _) -> (digest :> string)) plan.objects in
  Alcotest.(check bool) "a first save writes both" true
    (List.for_all (fun digest -> List.mem digest (written first)) (header_digests first));
  let same = plan_ok memo ~previous:first.head O.Turn_closes (checkpoint (turn 1 @ turn 2)) in
  Alcotest.(check bool) "an unchanged header writes neither" false
    (List.exists (fun digest -> List.mem digest (written same)) (header_digests same));
  let reprompted =
    plan_ok memo ~previous:same.head O.Turn_closes
      { (checkpoint (turn 1 @ turn 2)) with system_prompt = Some "be thorough" }
  in
  Alcotest.(check bool) "a new system prompt is written" true
    (List.mem (reprompted.head.header_objects.system_prompt :> string) (written reprompted));
  Alcotest.(check bool) "the same tools are not" false
    (List.mem (reprompted.head.header_objects.tools :> string) (written reprompted))
;;

(* A change inside a segment drops that segment and everything after it:
   their messages are written again. *)
let test_an_edit_inside_a_segment_writes_it_again () =
  let store = store () in
  let memo = O.create_memo () in
  let plans, messages = close_turns ~store ~memo (O.turns_per_segment + 6) in
  let last = List.nth plans (List.length plans - 1) in
  let edited = List.mapi (fun index message -> if index = 5 then assistant "edited" else message) messages in
  let replanned = plan_ok memo ~previous:last.head O.Turn_closes (checkpoint edited) in
  Alcotest.(check bool) "no segment is kept" true (Option.is_none replanned.head.history.segment);
  Alcotest.(check int) "every message is one closed turn" 1 (List.length replanned.head.history.turns);
  write store replanned;
  same_messages "the edited history loads back" edited (load_ok store replanned)
;;

(* A segment the store lost is not kept: the save writes its messages again,
   and the head it plans loads without it. *)
let test_an_absent_segment_is_not_kept () =
  let store = store () in
  let memo = O.create_memo () in
  let plans, messages = close_turns ~store ~memo (O.turns_per_segment + 2) in
  let last = List.nth plans (List.length plans - 1) in
  let segment =
    match last.head.history.segment with
    | Some segment -> segment.segment
    | None -> Alcotest.fail "a segment's worth of turns makes a segment"
  in
  Hashtbl.remove store (segment :> string);
  let grown = messages @ turn 99 in
  let replanned = plan_ok memo ~previous:last.head ~absent:[ segment ] O.Turn_closes (checkpoint grown) in
  Alcotest.(check bool) "the lost segment is not named" false
    (List.mem (segment :> string)
       (List.map (fun (digest : O.digest) -> (digest :> string)) (O.head_objects replanned.head)));
  write store replanned;
  same_messages "the history loads back" grown (load_ok store replanned)
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
  let second = plan_ok memo ~previous:first.head O.Turn_continues (checkpoint messages) in
  write store second;
  let bundle = (List.hd second.head.history.turns).bundle in
  let open_message = List.hd second.head.history.open_messages in
  Alcotest.(check (list string)) "the head names its header objects, its bundle and its open message"
    [ (second.head.header_objects.system_prompt :> string)
    ; (second.head.header_objects.tools :> string)
    ; (bundle :> string)
    ; (open_message :> string)
    ]
    (List.map (fun (digest : O.digest) -> (digest :> string)) (O.head_objects second.head));
  Hashtbl.remove store (bundle :> string);
  Hashtbl.remove store (open_message :> string);
  let unchanged =
    plan_ok memo ~previous:second.head O.Turn_continues (checkpoint messages)
  in
  Alcotest.(check int) "a save that trusts the head writes nothing" 0 (object_count unchanged);
  let third =
    plan_ok memo ~previous:second.head ~absent:[ bundle; open_message ] O.Turn_continues
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
        ; Alcotest.test_case "a list reads back only as far as it finds" `Quick
            test_a_list_reads_back_only_as_far_as_it_finds
        ; Alcotest.test_case "a head names fewer turns than a segment" `Quick
            test_a_head_names_fewer_turns_than_a_segment
        ; Alcotest.test_case "a header object is written when it changes" `Quick
            test_a_header_object_is_written_when_it_changes
        ; Alcotest.test_case "an edit inside a segment writes it again" `Quick
            test_an_edit_inside_a_segment_writes_it_again
        ; Alcotest.test_case "an absent segment is not kept" `Quick test_an_absent_segment_is_not_kept
        ] )
    ; ( "refusals"
      , [ Alcotest.test_case "a load refuses what it cannot prove" `Quick
            test_a_load_refuses_what_it_cannot_prove
        ; Alcotest.test_case "an overflowing history count is refused" `Quick
            test_an_overflowing_history_count_is_refused
        ; Alcotest.test_case "an overflowing bundle length is refused" `Quick
            test_an_overflowing_bundle_length_is_refused
        ; Alcotest.test_case "a document that is not a head" `Quick
            test_a_document_that_is_not_a_head
        ; Alcotest.test_case "a later head reads as its version" `Quick
            test_a_later_head_reads_as_its_version
        ] )
    ]
;;
