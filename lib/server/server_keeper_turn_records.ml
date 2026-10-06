let read ~store ~limit =
  Result.map
    (fun rows ->
      let reversed, skipped =
        List.fold_left
          (fun (acc, skipped) -> function
            | Dated_jsonl.Malformed_json _ -> acc, skipped + 1
            | Dated_jsonl.Parsed json ->
              match Turn_record.of_json json with
              | Ok record -> record :: acc, skipped
              | Error _ -> acc, skipped + 1)
          ([], 0) rows
      in
      List.rev reversed, skipped)
    (Dated_jsonl.read_recent_result store limit)
