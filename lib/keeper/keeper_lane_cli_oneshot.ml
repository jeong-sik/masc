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
  runtime_id:string
  -> system_prompt:string
  -> output_schema:Yojson.Safe.t
  -> prompt:string
  -> (string, string) result

let default_runner ~base_dir : runner =
  fun ~runtime_id ~system_prompt ~output_schema ~prompt ->
  Fusion_official_client.run_panelist
    ~base_dir
    ~runtime_id
    ~system_prompt
    ~output_schema
    ~prompt
    ()
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
    (* Same words as the HTTP path's prompt-carried schema ([Off]/[JsonMode]).
       The instruction stays even though the transport now carries the schema
       too: the Claude and Antigravity CLIs enforce by validating their own
       answer and re-prompting, so a model that was told the shape needs fewer
       rounds to produce it, and llama.cpp's own documentation notes that a
       schema handed to a grammar is never shown to the model at all. The two
       channels answer different halves -- one says what to write, the other
       refuses what does not match. *)
    let prompt =
      prompt ^ "\n\n" ^ Exact_output.schema_instruction_text requirement
    in
    match
      runner
        ~runtime_id
        ~system_prompt
        ~output_schema:(Exact_output.domain_schema requirement)
        ~prompt
    with
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
