module Offline = Board_posts_initialization_offline

type action = Inspect | Bootstrap of { expected_intent_sha256 : string }
  | Adopt of { expected_intent_sha256 : string }
type request = { base_path : string; action : action }

let intent =
  let parse text = match Agent_core_sha256.consistent_of_hex_opt text with
    | Some digest when String.equal text (Agent_core_sha256.to_hex digest) -> Ok text
    | Some _ | None -> Error (`Msg "expected 64 lowercase hexadecimal SHA256 characters") in
  Cmdliner.Arg.conv ~docv:"SHA256" (parse, Format.pp_print_string)

let cmd ~base_path ~run =
  let open Cmdliner in
  let expected = Arg.(required & opt (some intent) None & info ["expected-intent-sha256"]
      ~docv:"SHA256" ~doc:"Require the exact root/action/content intent displayed by inspect.") in
  let leaf name doc action =
    Cmd.v (Cmd.info name ~doc)
      Term.(const run $ (const (fun base_path action -> { base_path; action }) $ base_path $ action)) in
  Cmd.group (Cmd.info "board-posts" ~doc:"Inspect or explicitly initialize posts while offline. Live Board loads and writes do not read the initialization guard.")
    [leaf "inspect" "Observe existing posts initialization without creating files." (Term.const Inspect);
     leaf "bootstrap" "Explicitly initialize an unused posts layout while the workspace is offline."
       Term.(const (fun expected_intent_sha256 -> Bootstrap { expected_intent_sha256 }) $ expected);
     leaf "adopt" "Confirm exact current posts bytes and publish their initialization guard while offline."
       Term.(const (fun expected_intent_sha256 -> Adopt { expected_intent_sha256 }) $ expected)]

let run ?(out = stdout) request =
  let response = match request.action with
    | Inspect -> Offline.inspect ~base_path:request.base_path
    | Bootstrap { expected_intent_sha256 } -> Offline.bootstrap ~base_path:request.base_path ~expected_intent_sha256
    | Adopt { expected_intent_sha256 } -> Offline.adopt ~base_path:request.base_path ~expected_intent_sha256 in
  let reporting_failure =
    try
      output_string out (Yojson.Safe.to_string (Offline.response_to_yojson response));
      output_char out '\n'; flush out;
      None
    with exception_ -> Some (exception_, Printexc.get_raw_backtrace ()) in
  (* Always settle before reporting errors: an original reserved operation
     failure must not disappear behind a failed renderer/output channel. *)
  Offline.finish response;
  match reporting_failure with
  | Some (exception_, backtrace) -> Printexc.raise_with_backtrace exception_ backtrace
  | None -> Offline.exit_code response
