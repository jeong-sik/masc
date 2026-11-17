module B = Window_under_base
module N = Window_under_test
module C = Codec_under_test
module T = Agent_core.Types

type implementation = Baseline | Candidate
type lane = Claude | Codex

let encode m = C.encode C.Canonical_source m
let measure m = String.length (encode m)
let message ?(origin=T.Conversation) role text =
  T.make_message ~origin ~role [T.Text text]

let history turns payload_bytes =
  message T.System "owned current context" ::
  List.concat_map (fun turn ->
    let id = Printf.sprintf "call-%d" turn in
    [ message T.User (Printf.sprintf "request-%d" turn)
    ; T.make_message ~role:T.Assistant
        [T.ToolUse {id;name="owned_fixture";input=`Assoc ["turn",`Int turn]}]
    ; T.make_message ~role:T.Tool
        [T.ToolResult {tool_use_id=id;content=String.make payload_bytes 'x';
           outcome=T.Tool_succeeded;json=None;content_blocks=None}]
    ]) (List.init turns Fun.id)

let sum f = List.fold_left (fun acc m -> acc + f m) 0
let optional = function None -> `Null | Some n -> `Int n

let calculate implementation lane ~measure ~bounded messages =
  match implementation with
  | Baseline ->
    let full = sum measure messages in
    let target = if bounded then 1_000_000 else full / 2 in
    let next = B.next_shrink_capacity_bytes ~allow_empty_history:true
        ~measure_message_bytes:measure ~target_capacity_bytes:target messages in
    let floor = match lane with Claude -> B.minimum_capacity_bytes ~measure_message_bytes:measure messages | Codex -> None in
    full, next, floor
  | Candidate ->
    let measured = N.measure_history ~measure_message_bytes:measure messages in
    let full = N.measured_bytes measured in
    let target = if bounded then 1_000_000 else full / 2 in
    let next = N.next_shrink_capacity_bytes ~allow_empty_history:true ~target_capacity_bytes:target measured in
    let floor = match lane with Claude -> N.minimum_capacity_bytes measured | Codex -> None in
    full, next, floor

let projection_json messages dropped count =
  `Assoc ["bytes", `List (List.map (fun m -> `String (encode m)) messages);
          "drop", `Int dropped; "atoms", `Int count]

let base_projection ~allow ~measure ~capacity messages =
  match B.project_with_drop ~allow_empty_history:allow ~measure_message_bytes:measure
      ~capacity_bytes:capacity ~reserved_bytes:17 messages with
  | Ok p -> projection_json p.messages p.dropped_atoms p.atom_count
  | Error e -> `String (B.budget_error_to_string e)

let new_projection ~allow ~measure ~capacity messages =
  match N.project_with_drop ~allow_empty_history:allow ~measure_message_bytes:measure
      ~capacity_bytes:capacity ~reserved_bytes:17 messages with
  | Ok p -> projection_json p.messages p.dropped_atoms p.atom_count
  | Error e -> `String (N.budget_error_to_string e)

let differential () =
  let user = message T.User "user" and assistant = message T.Assistant "assistant" in
  let tool = message T.Tool "orphan" in
  let signed v = T.make_message ~role:T.Assistant
      [T.ToolUse {id="same";name="same";input=`Assoc ["n",`Float v]}] in
  let origins = [T.Conversation;T.System_context;T.Historical_system_context;
                 T.Recovery_instruction;T.Tool_result_followup;T.Agent_instruction] in
  let roles = [T.System;T.User;T.Assistant;T.Tool] in
  let classified = List.concat_map (fun origin -> List.map (fun role -> message ~origin role "classified") roles) origins in
  let working = {user with origin=T.Agent_instruction;metadata=N.working_state_metadata} in
  let unread = {assistant with origin=T.Agent_instruction;metadata=N.unread_context_metadata} in
  if not (N.is_working_state working && N.is_unread_context unread) then
    failwith "fixture must exercise pinned marker rows";
  let copy_preamble = {N.preamble_message with name=Some "materialized-copy"} in
  let fixtures = [ []; [message T.System "pinned"]; [N.preamble_message];
      [N.preamble_message;message T.System "pinned"]; [tool;tool];
      [user;assistant;tool]; [tool;user;assistant;tool];
      [N.preamble_message;user;copy_preamble;assistant;tool];
      [working;user;unread;assistant;tool]; [signed 0.0;signed (-0.0)];
      [user;assistant;user;assistant;user]; classified; List.rev classified ]
      @ List.init 41 (fun count -> List.init count (fun i -> List.nth classified (i mod List.length classified))) in
  let measures = ["canonical",measure;"zero",(fun _ -> 0);"unit",(fun _ -> 1);
      "max-int",(fun _ -> max_int);"half-max",(fun _ -> max_int/2);
      "near-max",(fun _ -> max_int-1)] in
  let checks = ref 0 and bounds = ref 0 and projections = ref 0 and carried = ref 0 in
  let check label a b = incr checks; if a<>b then failwith ("differential mismatch: " ^ label) in
  List.iteri (fun index messages ->
    let bl,bc = B.annotate messages and nl,nc = N.annotate messages in
    check "atom count" bc nc;
    check "labels" (List.map (fun (_,x) -> match x with B.Pinned -> -1 | B.Atom n -> n) bl)
      (List.map (fun (_,x) -> match x with N.Pinned -> -1 | N.Atom n -> n) nl);
    List.iter (fun (measure_name,measure) ->
      let snapshot = N.measure_history ~measure_message_bytes:measure messages in
      let total = sum measure messages in
      check "original total" total (N.measured_bytes snapshot);
      check "floor" (B.minimum_capacity_bytes ~measure_message_bytes:measure messages) (N.minimum_capacity_bytes snapshot);
      List.iter (fun target -> List.iter (fun allow ->
        incr bounds;
        check (Printf.sprintf "next fixture%d/%s/%d" index measure_name target)
          (B.next_shrink_capacity_bytes ~allow_empty_history:allow ~measure_message_bytes:measure ~target_capacity_bytes:target messages)
          (N.next_shrink_capacity_bytes ~allow_empty_history:allow ~target_capacity_bytes:target snapshot);
        incr projections;
        check "projection bytes or error" (base_projection ~allow ~measure ~capacity:target messages)
          (new_projection ~allow ~measure ~capacity:target messages)
      ) [false;true]) [min_int;-1;0;1;17;total/2;total;max_int];
      List.iter (fun first_atom -> List.iter (fun allow_empty_history -> List.iter (fun history_already_announced ->
        let bp,bb = B.project_from_atom ~allow_empty_history ~history_already_announced ~measure_message_bytes:measure ~first_atom messages in
        let np,nb = N.project_from_atom ~allow_empty_history ~history_already_announced ~measure_message_bytes:measure ~first_atom messages in
        incr carried;
        check "carried bytes" bb nb;
        check "carried messages" (projection_json bp.messages bp.dropped_atoms bp.atom_count)
          (projection_json np.messages np.dropped_atoms np.atom_count)
      ) [false;true]) [false;true]) [-2;0;1;5;max_int]
    ) measures
  ) fixtures;
  `Assoc ["fixtures",`Int (List.length fixtures);"measure_policies",`Int (List.length measures);
      "next_comparisons",`Int !bounds;"projection_comparisons",`Int !projections;
      "carried_comparisons",`Int !carried;"assertions",`Int !checks;"result",`String "PASS"]

let benchmark implementation =
  let rows = [0,0,5000;4,128,1000;100,4096,50;100,32768,32] in
  let trials = List.concat_map (fun lane -> List.concat_map (fun bounded ->
    List.map (fun (turns,payload,iterations) ->
      let messages = history turns payload in
      let calls = ref 0 and encoded = ref 0 in
      let counted m = incr calls; let bytes=measure m in encoded:= !encoded+bytes;bytes in
      let oracle = calculate implementation lane ~measure:counted ~bounded messages in
      for _ = 1 to 3 do ignore (Sys.opaque_identity (calculate implementation lane ~measure ~bounded messages)) done;
      Gc.full_major ();
      let before = Gc.counters () in
      let allocated_before = Gc.allocated_bytes () in
      let cpu_before = Sys.time () and wall_before = Unix.gettimeofday () in
      let sink = ref oracle in
      for _ = 1 to iterations do sink := Sys.opaque_identity (calculate implementation lane ~measure ~bounded messages) done;
      let wall = Unix.gettimeofday () -. wall_before and cpu = Sys.time () -. cpu_before in
      let allocated = Gc.allocated_bytes () -. allocated_before in
      let after = Gc.counters () in
      let mi0,pr0,ma0=before and mi1,pr1,ma1=after in
      if !sink<>oracle then failwith "unstable benchmark result";
      let full,next,floor=oracle in
      `Assoc ["lane",`String (match lane with Claude->"claude"|Codex->"codex");
        "bounded",`Bool bounded;"turns",`Int turns;"payload_bytes",`Int payload;
        "messages",`Int (List.length messages);"iterations",`Int iterations;
        "cpu_seconds",`Float cpu;"wall_seconds",`Float wall;
        "allocated_bytes",`Float allocated;"minor_words",`Float (mi1-.mi0);
        "promoted_words",`Float (pr1-.pr0);"major_words",`Float (ma1-.ma0);
        "encoder_calls",`Int !calls;"encoded_bytes",`Int !encoded;
        "full_bytes",`Int full;"next",optional next;"floor",optional floor]
    ) rows) [false;true]) [Claude;Codex] in
  `Assoc ["implementation",`String (match implementation with Baseline->"baseline"|Candidate->"candidate");
      "rows",`List trials]

let () =
  let result = match Array.to_list Sys.argv with
    | [_;"differential"] -> differential ()
    | [_;"baseline"] -> benchmark Baseline
    | [_;"candidate"] -> benchmark Candidate
    | [] | [_] | _::_::_ -> invalid_arg "mode required: differential/baseline/candidate"
  in
  print_endline (Yojson.Safe.to_string result)
