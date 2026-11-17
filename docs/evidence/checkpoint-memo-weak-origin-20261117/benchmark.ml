open Agent_core
module O = Objects_under_test
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


let get = function Ok x -> x | Error e -> failwith (Error.to_string e)
let allocated () = let minor,promoted,major=Gc.counters () in minor+.major-.promoted
let measure f =
  let before_allocated=allocated () and before_cpu=Sys.time () and before_wall=Unix.gettimeofday () in
  let result=f () in
  let cpu=Sys.time ()-.before_cpu and wall=Unix.gettimeofday ()-.before_wall in
  result, cpu, wall, (allocated ()-.before_allocated)*.8.
let trial count bytes mode =
  let messages=List.init count (fun i -> Types.user_msg (Printf.sprintf "%d:%s" i (String.make bytes 'x'))) in
  let cp=checkpoint messages and memo=O.create_memo () in
  let first,cold_cpu,cold_wall,cold_allocated=measure(fun()->get(O.plan_save memo O.Turn_closes cp)) in
  let current=if mode="original" then cp else first.decoded in
  Gc.full_major ();
  let last,cpu,wall,allocated=measure(fun()->
    let last=ref first in
    for _=1 to 100 do last:=get(O.plan_save memo ~previous:first.head O.Turn_continues current) done;
    !last) in
  if last.head_bytes<>first.head_bytes || last.content<>first.content then failwith "warm bytes changed";
  ignore(Sys.opaque_identity current);
  `Assoc["messages",`Int count;"text_bytes_per_message",`Int bytes;"mode",`String mode;
    "iterations",`Int 100;"cold_cpu",`Float cold_cpu;"cold_wall",`Float cold_wall;"cold_allocated",`Float cold_allocated;
    "warm_cpu",`Float cpu;"warm_wall",`Float wall;"warm_allocated",`Float allocated;
    "encoded_memo_bytes",`Int(O.memo_encoded_bytes memo)]
let () =
  let rows=List.concat_map(fun(count,bytes)->List.map(trial count bytes)["original";"decoded"])[2000,128;512,4096] in
  print_endline(Yojson.Safe.to_string(`List rows))
