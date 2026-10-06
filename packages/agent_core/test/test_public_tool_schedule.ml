(* A package consumer must compile using the public CMI closure, without
   access to Agent Core's private execution modules. *)
module Schedule = Agent_core.Execution_tool_schedule
module Contract = Agent_core.Tool_contract

let () =
  let schedule : Contract.schedule =
    { planned_index = 0; batch_index = 0; batch_size = 1; execution_mode = Serial }
  in
  (match Schedule.of_yojson (Schedule.to_yojson schedule) with
   | Ok decoded when Schedule.equal schedule decoded -> ()
   | _ -> failwith "public schedule codec did not roundtrip");
  (match Schedule.validate { schedule with batch_size = 0 } with
   | Error Schedule.Non_positive_batch_size -> ()
   | _ -> failwith "public schedule validation accepted an empty batch");
  print_endline "Public tool schedule consumer: PASS"
