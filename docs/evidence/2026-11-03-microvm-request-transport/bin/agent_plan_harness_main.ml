(* Drives the copied masc code (copied.ml, cut verbatim from the L5a worktree)
   for one agent plan:
     render  NAME SOCKET IDENTITY SHIM          -> argv as a JSON list
     digest  SOCKET IDENTITY SHIM               -> the plan's boot_plan label
     assess  NAME SOCKET IDENTITY SHIM INSPECT IMAGE_INSPECT -> assessment *)
module Plan = Keeper_microvm_boot_plan
module Size = Keeper_microvm_guest_size

let ok = function Ok value -> value | Error detail -> failwith detail

let plan ~socket ~identity ~shim : Plan.t =
  { Plan.image = "masc-sandbox-ocaml:20260928T0216Z-c48e1e05"
  ; guest_size = {Size.memory = ok (Size.memory_of_string "1g"); cpus = ok (Size.cpus_of_int 1)}
  ; user = "0:0"; working_directory = "/masc-work"
  ; command = ["/opt/masc-exec-shim/masc-exec-shim"; "--serve"; "/run/masc-agent/agent.sock"; "502:20"]
  ; mounts =
      [ Plan.Host_dir {source = identity; destination = "/masc-identity"; read_only = true}
      ; Plan.Named_volume {name = "fixture-agent-work"; destination = "/masc-work"}
      ; Plan.Named_volume {name = "fixture-agent-build"; destination = "/masc-build"}
      ; Plan.Host_dir {source = shim; destination = "/opt/masc-exec-shim"; read_only = true} ]
  ; isolation = Keeper_microvm_backend.[Drop_all_capabilities; Remove_on_exit; Scratch_tmpfs]
  ; capabilities_added = [Plan.Cap_setuid; Plan.Cap_setgid; Plan.Cap_sys_admin]
  ; published_sockets = [{Plan.host_path = socket; guest_path = "/run/masc-agent/agent.sock"}]
  ; network = Plan.Network_none
  ; environment = ["HOME", "/tmp"; "MASC_EXEC_SHIM_CONFIG", "/opt/masc-exec-shim/masc-exec-shim.conf";
                   "GH_CONFIG_DIR", "/masc-identity"]
  ; labels = ["masc.mcp.keeper", "fixture-agent"; "masc.mcp.microvm_backend", "apple_container"] }

let lifecycle_labels = ["masc.mcp.owner_pid", "4242"; "masc.mcp.started_at", "1793690000"]

let read path = In_channel.with_open_bin path In_channel.input_all

let () =
  match Array.to_list Sys.argv |> List.tl with
  | ["render"; name; socket; identity; shim] ->
    (match Sandbox.apple_turn_start_argv ~container_name:name ~plan:(plan ~socket ~identity ~shim)
             ~lifecycle_labels ~dns:None ~policy_proxy:None with
     | Ok argv -> print_string (Yojson.Safe.to_string (`List (List.map (fun a -> `String a) argv)))
     | Error (Sandbox.Apple_invalid_boot_plan errors) ->
       failwith (String.concat "; " (List.map Plan.invalid_plan_message errors))
     | Error (Sandbox.Apple_network_unavailable detail) -> failwith detail
     | Error (Sandbox.Apple_constraints_unexpressible _) -> failwith "constraints unexpressible")
  | ["digest"; socket; identity; shim] -> print_string (Plan.digest (plan ~socket ~identity ~shim))
  | ["assess"; name; socket; identity; shim; inspect; image_inspect] ->
    let plan = plan ~socket ~identity ~shim in
    let reading = Sandbox.apple_guest_facts ~container_name:name (read inspect) in
    (match reading with
     | Plan.Unreadable detail -> Printf.printf "unreadable: %s\n" detail
     | Plan.Facts facts ->
       let image_command = Keeper_microvm_image_command.of_apple_inspect ~reference:plan.image
           ~identity:facts.image_identity (read image_inspect)
         |> Result.map_error Keeper_microvm_image_command.error_message in
       (match image_command with
        | Ok image_command ->
          Printf.printf "differences: [%s]\n" (String.concat "; "
            (List.map Plan.difference_label (Plan.differences ~image_command plan facts)))
        | Error detail -> Printf.printf "image command: %s\n" detail);
       Printf.printf "plan_label matches digest: %b\n" (facts.plan_label = Some (Plan.digest plan));
       let assessment = Plan.assess ~plan ~policy_environment:[] ~identity_reading:Plan.Identity_readable
           ~image_command reading in
       print_endline (match assessment with
         | Plan.Matches_plan -> "assessment: Matches_plan"
         | Plan.Replace differences ->
           "assessment: Replace [" ^ String.concat "; " (List.map Plan.difference_label differences) ^ "]"
         | Plan.Refuse refusal -> "assessment: Refuse " ^ Plan.refusal_message refusal))
  | _ -> prerr_endline "usage: render|digest|assess ..."; exit 2
