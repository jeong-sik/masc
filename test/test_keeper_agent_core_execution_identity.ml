module Identity = Keeper_agent_core_execution_identity

let expect_ok = function
  | Ok value -> value
  | Error error -> failwith (Identity.error_to_string error)
;;

let operation
      ?(candidate_index = 0)
      ?(context_shrink_attempt = 0)
      ?(context_capacity_bytes = 4096)
      ?thinking_override
      ()
  =
  Identity.create
    ~keeper_name:"sangsu"
    ~trace_id:"trace-keeper-1"
    ~keeper_turn_id:42
    ~runtime_id:"glm.coding-plan"
    ~candidate_index
    ~context_shrink_attempt
    ~context_capacity_bytes
    ~thinking_override
  |> expect_ok
;;

let id operation =
  operation |> Identity.operation_id |> Identity.operation_id_to_string
;;

let assert_distinct label left right =
  if String.equal (id left) (id right)
  then failwith (label ^ " did not change the durable operation id")
;;

let contains haystack needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec loop offset =
    if offset + needle_length > haystack_length
    then false
    else if String.sub haystack offset needle_length = needle
    then true
    else loop (offset + 1)
  in
  needle_length = 0 || loop 0
;;

let () =
  let base = operation () in
  if not (String.equal (id base) (id (operation ())))
  then failwith "identical typed inputs produced unstable operation ids";
  assert_distinct "outer candidate attempt" base (operation ~candidate_index:1 ());
  assert_distinct
    "context shrink attempt"
    base
    (operation ~context_shrink_attempt:1 ~context_capacity_bytes:2048 ());
  assert_distinct
    "forced no-thinking attempt"
    base
    (operation ~thinking_override:false ());
  assert_distinct
    "forced thinking attempt"
    base
    (operation ~thinking_override:true ());
  (match
     Identity.create
       ~keeper_name:"sangsu"
       ~trace_id:"trace-keeper-1"
       ~keeper_turn_id:42
       ~runtime_id:"glm.coding-plan"
       ~candidate_index:(-1)
       ~context_shrink_attempt:0
       ~context_capacity_bytes:4096
       ~thinking_override:None
   with
   | Error (Identity.Negative_candidate_attempt (-1)) -> ()
  | Error error -> failwith ("wrong validation error: " ^ Identity.error_to_string error)
  | Ok _ -> failwith "negative candidate attempt was accepted");
  let json = Identity.to_yojson base |> Yojson.Safe.to_string in
  if contains json "generation"
  then failwith "generation must not enter crash-stable execution identity";
  print_endline "test_keeper_agent_core_execution_identity: OK"
;;
