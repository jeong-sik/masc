(** Stack 3 tests for RFC-0471: sealed frame JSON round-trips and strict
    rejects. *)

open Alcotest

module Frame = Collab_frame

let frame_t = testable Fmt.nop ( = )

let check_roundtrip msg frame =
  let json = Frame.frame_to_json frame in
  check (option frame_t) msg (Some frame) (Frame.frame_of_json json);
  check
    (option frame_t)
    (msg ^ " via string")
    (Some frame)
    (Frame.frame_of_string (Frame.frame_to_string frame))
;;

let test_all_frames_roundtrip () =
  check_roundtrip
    "hello"
    (Frame.Hello { proto = 1; write_token = Some "dG9rZW4" });
  check_roundtrip "hello view" (Frame.Hello { proto = 1; write_token = None });
  check_roundtrip
    "welcome"
    (Frame.Welcome
       { proto = 1
       ; header = { keeper = "imp"; operation = "op-1" }
       ; state = { active = true; guests = 2 }
       ; entry_count = 41
       ; read_only = true
       });
  check_roundtrip
    "chunk"
    (Frame.Snapshot_chunk
       { entries = [ `Assoc [ "seq", `Int 0 ]; `String "row" ]; final = false });
  check_roundtrip
    "entry"
    (Frame.Entry
       { seq = 7
       ; op = "op-1"
       ; op_seq = 3
       ; ts = 1.5
       ; event = `Assoc [ "type", `String "text_delta" ]
       });
  check_roundtrip
    "state"
    (Frame.Live_state { active = false; guests = 0 });
  check_roundtrip "prompt" (Frame.Prompt "hello keeper");
  check_roundtrip "abort" Frame.Abort;
  check_roundtrip
    "fetch"
    (Frame.Fetch_transcript { req_id = 9; max_bytes = 1024 });
  check_roundtrip
    "transcript"
    (Frame.Transcript
       { req_id = 9; text = "hi"; new_size = 2; error = None });
  check_roundtrip
    "transcript error"
    (Frame.Transcript
       { req_id = 9; text = ""; new_size = 2; error = Some "gone" });
  check_roundtrip "bye" (Frame.Bye "host stopped sharing");
  check_roundtrip "error" (Frame.Error_frame "nope")
;;

let test_exact_vectors () =
  check
    string
    "hello"
    {|{"t":"hello","proto":1}|}
    (Frame.frame_to_string (Frame.Hello { proto = 1; write_token = None }));
  check
    string
    "abort"
    {|{"t":"abort"}|}
    (Frame.frame_to_string Frame.Abort);
  check
    string
    "entry"
    {|{"t":"entry","seq":1,"op":"op","op_seq":0,"ts":2.0,"event":{}}|}
    (Frame.frame_to_string
       (Frame.Entry { seq = 1; op = "op"; op_seq = 0; ts = 2.0; event = `Assoc [] }))
;;

let test_strict_rejects () =
  let bad =
    [
      "not json";
      {|{}|};
      {|{"t":"nope"}|};
      {|{"t":42}|};
      {|{"t":"hello"}|};
      {|{"t":"hello","proto":"1"}|};
      {|{"t":"hello","proto":1,"write_token":42}|};
      {|{"t":"welcome","proto":1}|};
      {|{"t":"welcome","proto":1,"header":{"keeper":"k"},"state":{"active":true,"guests":0},"entry_count":0,"read_only":false}|};
      {|{"t":"snapshot-chunk","entries":[],"final":"yes"}|};
      {|{"t":"snapshot-chunk","entries":{},"final":true}|};
      {|{"t":"entry","seq":-1,"op":"o","op_seq":0,"ts":0.0,"event":{}}|};
      {|{"t":"entry","seq":1,"op":"o","ts":0.0,"event":{}}|};
      {|{"t":"state","active":true,"guests":-1}|};
      {|{"t":"prompt"}|};
      {|{"t":"fetch-transcript","req_id":1,"max_bytes":-5}|};
      {|{"t":"transcript","req_id":1,"text":"x","new_size":1,"error":7}|};
      {|{"t":"bye"}|};
      {|{"t":"error","message":null}|};
      {|[]|};
    ]
  in
  List.iter
    (fun s ->
      check (option frame_t) ("rejects " ^ s) None (Frame.frame_of_string s))
    bad
;;

let test_tolerant_bits () =
  (* Proto takes any int: a mismatch is reported, not a decode failure. *)
  check
    bool
    "odd proto decodes"
    true
    (Frame.frame_of_string {|{"t":"hello","proto":99}|} <> None);
  (* Unknown extra fields are ignored for forward compatibility. *)
  check
    (option frame_t)
    "extra fields ignored"
    (Some Frame.Abort)
    (Frame.frame_of_string {|{"t":"abort","future":1}|});
  (* Absent and null optionals both mean None. *)
  check
    (option frame_t)
    "null token"
    (Some (Frame.Hello { proto = 1; write_token = None }))
    (Frame.frame_of_string {|{"t":"hello","proto":1,"write_token":null}|});
  (* Integer ts decodes (JSON numbers without a fraction). *)
  check
    bool
    "int ts decodes"
    true
    (Frame.frame_of_string
       {|{"t":"entry","seq":1,"op":"o","op_seq":0,"ts":2,"event":{}}|}
     <> None)
;;

let () =
  run
    "collab-frame"
    [
      ( "frame",
        [
          test_case "all frames roundtrip" `Quick test_all_frames_roundtrip;
          test_case "exact vectors" `Quick test_exact_vectors;
          test_case "strict rejects" `Quick test_strict_rejects;
          test_case "tolerant bits" `Quick test_tolerant_bits;
        ] );
    ]
;;
