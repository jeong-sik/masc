type inspection = Board_initialization_inspect.t
type outcome = Board_initialization_protocol.t
type decision = Board_initialization_inspect.decision =
  | Bootstrap_required | Adoption_required | Ready_observed | Refused
type completion = Board_initialization_protocol.completion = Completed | Not_completed

let live_guard_enforced = Board_posts_source.live_guard_enforced

let inspect ~base_path = Board_initialization_inspect.read ~base_path ()
let decision = Board_initialization_inspect.decision
let intent_sha256 = Board_initialization_inspect.intent_sha256
let posts_source_sha256 = Board_initialization_inspect.posts_source_sha256
let inspection_to_yojson = Board_initialization_inspect.to_yojson
let finish_inspection = Board_initialization_inspect.finish
let bootstrap_offline ~base_path ~expected_intent_sha256 =
  Board_initialization_protocol.run ~action:Bootstrap ~base_path ~expected_intent_sha256 ()
let adopt_offline ~base_path ~expected_intent_sha256 =
  Board_initialization_protocol.run ~action:Adopt ~base_path ~expected_intent_sha256 ()
let completion = Board_initialization_protocol.completion
let outcome_to_yojson = Board_initialization_protocol.to_yojson
let finish_outcome = Board_initialization_protocol.finish

module For_testing = struct
  type file_io = Board_initialization_inspect.file_io = {
    posts : Fs_compat.private_jsonl_transaction_io_for_testing;
    guard : Fs_compat.private_jsonl_transaction_io_for_testing;
  }
  type io = Board_initialization_protocol.io = { read : file_io; write : file_io }
  let inspect ~base_path ~io = Board_initialization_inspect.read ~io ~base_path ()
  let bootstrap_offline ~base_path ~expected_intent_sha256 ~io =
    Board_initialization_protocol.run ~io ~action:Bootstrap ~base_path ~expected_intent_sha256 ()
  let adopt_offline ~base_path ~expected_intent_sha256 ~io =
    Board_initialization_protocol.run ~io ~action:Adopt ~base_path ~expected_intent_sha256 ()
end
