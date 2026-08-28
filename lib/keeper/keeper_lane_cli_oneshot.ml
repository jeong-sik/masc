module Exact_output = Agent_core.Exact_output

type failure =
  | Not_an_official_client of { runtime_id : string }
  | Execution_failed of
      { runtime_id : string
      ; detail : string
      }
  | Invalid_json_output of
      { runtime_id : string
      ; detail : string
      }

let failure_to_string = function
  | Not_an_official_client { runtime_id } ->
    Printf.sprintf "cli lane slot %s is not an official-client runtime" runtime_id
  | Execution_failed { runtime_id; detail } ->
    Printf.sprintf "cli lane slot %s failed to answer: %s" runtime_id detail
  | Invalid_json_output { runtime_id; detail } ->
    Printf.sprintf "cli lane slot %s answered non-JSON: %s" runtime_id detail

type runner =
  runtime_id:string -> system_prompt:string -> prompt:string -> (string, string) result

let default_runner ~base_dir : runner =
  fun ~runtime_id ~system_prompt ~prompt ->
  Fusion_official_client.run_panelist ~base_dir ~runtime_id ~system_prompt ~prompt ()
  |> Result.map_error Fusion_types.show_panel_failure
;;

let run ?runner ~base_dir ~runtime_id ~system_prompt ~requirement ~prompt () =
  if not (Fusion_official_client.is_official_client ~runtime_id)
  then Error (Not_an_official_client { runtime_id })
  else (
    let runner =
      match runner with
      | Some runner -> runner
      | None -> default_runner ~base_dir
    in
    (* Same words as the HTTP path's prompt-carried schema ([Off]/[JsonMode]):
       the CLI's tool-call machinery is not in play here, so the instruction
       is the only schema channel this transport has. *)
    let prompt =
      prompt ^ "\n\n" ^ Exact_output.schema_instruction_text requirement
    in
    match runner ~runtime_id ~system_prompt ~prompt with
    | Error detail -> Error (Execution_failed { runtime_id; detail })
    | Ok answer ->
      (* Strict on purpose: Agent Core parses a [Json_syntax_only] HTTP body
         with exactly [Yojson.Safe.from_string] and no repair, and a lane
         slot changes transport, not contract. *)
      (try Ok (Yojson.Safe.from_string answer) with
       | Yojson.Json_error detail -> Error (Invalid_json_output { runtime_id; detail })))
;;

let walk ?runner ~base_dir ~cli_slots ~system_prompt ~requirement ~prompt () =
  let rec loop failures = function
    | [] -> Error (List.rev failures)
    | runtime_id :: rest ->
      (match run ?runner ~base_dir ~runtime_id ~system_prompt ~requirement ~prompt () with
       | Ok value -> Ok (runtime_id, value)
       | Error failure -> loop (failure :: failures) rest)
  in
  loop [] cli_slots
;;
