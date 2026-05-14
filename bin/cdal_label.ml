(** cdal-label — CDAL labeling protocol v0 CLI.

    Subcommands:
    - [apply]: read verdict JSON, apply label, write labeled verdict
    - [metrics]: read labeled verdicts, compute output contract *)

module CT = Cdal_types
module L = Labeling

let read_json_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = Bytes.create n in
  really_input ic s 0 n;
  close_in ic;
  Yojson.Safe.from_string (Bytes.to_string s)

let write_json_file path json =
  let oc = open_out path in
  output_string oc (Yojson.Safe.pretty_to_string json);
  output_char oc '\n';
  close_out oc

(* ================================================================ *)
(* apply subcommand                                                  *)
(* ================================================================ *)

let apply_cmd verdict_path label_str labeler note output_path =
  let json = read_json_file verdict_path in
  match CT.contract_verdict_of_json json with
  | Error e ->
    Printf.eprintf "error parsing verdict: %s\n" e;
    exit 1
  | Ok verdict -> (
    match L.label_of_string label_str with
    | Error e ->
      Printf.eprintf "error: %s\n" e;
      exit 1
    | Ok label ->
      let now =
        let t = Unix.gettimeofday () in
        let tm = Unix.gmtime t in
        Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
          (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
          tm.tm_hour tm.tm_min tm.tm_sec
      in
      let lv : L.labeled_verdict =
        { verdict; label; labeler; note; labeled_at = now }
      in
      let out_json = L.labeled_verdict_to_json lv in
      (match output_path with
       | Some path ->
         write_json_file path out_json;
         Printf.printf "labeled verdict written to %s\n" path
       | None ->
         print_endline (Yojson.Safe.pretty_to_string out_json)))

(* ================================================================ *)
(* metrics subcommand                                                *)
(* ================================================================ *)

let collect_labeled_verdicts dir =
  let entries = Sys.readdir dir in
  Array.to_list entries
  |> List.filter (fun f -> Filename.check_suffix f ".json")
  |> List.sort String.compare
  |> List.filter_map (fun f ->
       let path = Filename.concat dir f in
       let json = read_json_file path in
       match L.labeled_verdict_of_json json with
       | Ok lv -> Some lv
       | Error e ->
         Printf.eprintf "warning: skipping %s: %s\n" f e;
         None)

let metrics_cmd input_dir workload_name judge_version label_owner
    metric_owner total_claims drift_note =
  let verdicts = collect_labeled_verdicts input_dir in
  if verdicts = [] then (
    Printf.eprintf "no labeled verdicts found in %s\n" input_dir;
    exit 1);
  let oc =
    L.build_output_contract ~workload_name ~protocol_version:"v0.1"
      ~judge_protocol_version:judge_version ~label_owner ~metric_owner
      ~total_claims ~drift_note verdicts
  in
  print_endline (Yojson.Safe.pretty_to_string (L.output_contract_to_json oc))

(* ================================================================ *)
(* Cmdliner setup                                                    *)
(* ================================================================ *)

open Cmdliner

let verdict_path_arg =
  let doc = "Path to verdict JSON file." in
  Arg.(required & pos 0 (some file) None & info [] ~docv:"VERDICT" ~doc)

let label_arg =
  let doc = "Label to apply: supported, unsupported, ambiguous, drift." in
  Arg.(required & opt (some string) None & info [ "label"; "l" ] ~docv:"LABEL" ~doc)

let labeler_arg =
  let doc = "Labeler identifier (e.g. human:alice)." in
  Arg.(required & opt (some string) None & info [ "labeler" ] ~docv:"LABELER" ~doc)

let note_arg =
  let doc = "Optional labeling note." in
  Arg.(value & opt (some string) None & info [ "note"; "n" ] ~docv:"NOTE" ~doc)

let output_arg =
  let doc = "Output file path (stdout if omitted)." in
  Arg.(value & opt (some string) None & info [ "output"; "o" ] ~docv:"OUTPUT" ~doc)

let apply_term =
  let doc = "Apply a label to a verdict." in
  let info = Cmd.info "apply" ~doc in
  Cmd.v info
    Term.(const apply_cmd $ verdict_path_arg $ label_arg $ labeler_arg $ note_arg $ output_arg)

let input_dir_arg =
  let doc = "Directory containing labeled verdict JSON files." in
  Arg.(required & opt (some dir) None & info [ "input-dir"; "d" ] ~docv:"DIR" ~doc)

let workload_arg =
  let doc = "Workload name." in
  Arg.(required & opt (some string) None & info [ "workload"; "w" ] ~docv:"NAME" ~doc)

let judge_version_arg =
  let doc = "Judge protocol version." in
  Arg.(value & opt string "v0" & info [ "judge-version" ] ~docv:"VERSION" ~doc)

let label_owner_arg =
  let doc = "Label owner." in
  Arg.(required & opt (some string) None & info [ "label-owner" ] ~docv:"OWNER" ~doc)

let metric_owner_arg =
  let doc = "Metric owner." in
  Arg.(required & opt (some string) None & info [ "metric-owner" ] ~docv:"OWNER" ~doc)

let total_claims_arg =
  let doc = "Total material claims count." in
  Arg.(required & opt (some int) None & info [ "total-claims" ] ~docv:"N" ~doc)

let drift_note_arg =
  let doc = "Drift note." in
  Arg.(value & opt string "" & info [ "drift-note" ] ~docv:"NOTE" ~doc)

let metrics_term =
  let doc = "Compute output contract metrics from labeled verdicts." in
  let info = Cmd.info "metrics" ~doc in
  Cmd.v info
    Term.(
      const metrics_cmd $ input_dir_arg $ workload_arg $ judge_version_arg
      $ label_owner_arg $ metric_owner_arg $ total_claims_arg $ drift_note_arg)

let main_cmd =
  let doc = "CDAL labeling protocol v0 CLI." in
  let info = Cmd.info "cdal-label" ~version:"v0" ~doc in
  Cmd.group info [ apply_term; metrics_term ]

let () = exit (Cmd.eval main_cmd)
