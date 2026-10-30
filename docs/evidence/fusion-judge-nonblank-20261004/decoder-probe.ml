let () =
  let emit label text =
    let result = match Fusion_judge_parse.of_string text with
      | Ok _ -> "accepted"
      | Error detail -> "rejected:" ^ detail in
    Printf.printf "%s=%s\n" label result in
  emit "empty_answer" {|{"resolved_answer":"","decision":{"kind":"answer","answer":""}}|};
  emit "blank_answer" {|{"resolved_answer":" \t\n","decision":{"kind":"answer","answer":" \t"}}|};
  emit "insufficient" {|{"resolved_answer":"","decision":{"kind":"insufficient","missing":["evidence"]}}|};
  emit "supported_answer" {|{"resolved_answer":"Supported","decision":{"kind":"answer","answer":"Supported"}}|};
  Out_channel.with_open_bin "schema.json" (fun out -> output_string out (Yojson.Safe.pretty_to_string Fusion_judge_parse.output_schema))
