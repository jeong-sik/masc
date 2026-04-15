open Masc_mcp
open Test_command_plane_v2_support

let swarm_live_dir config =
  Filename.concat
    (Filename.concat (Room.masc_dir config) "control-plane")
    "swarm-live"

let write_jsonl_rows path rows =
  let body =
    rows
    |> List.map Yojson.Safe.to_string
    |> String.concat "\n"
  in
  write_text_file path (body ^ "\n")

let make_slot_sample ~timestamp ~active_slots ~ctx_per_slot =
  `Assoc
    [
      ("timestamp", `String timestamp);
      ("total_slots", `Int 12);
      ("active_slots", `Int active_slots);
      ("active_slot_ids", `List []);
      ("ctx_per_slot", `Int ctx_per_slot);
    ]

let test_swarm_proof_fallback_reads_slot_samples_from_bounded_tail () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      with_eio_test base_dir @@ fun config ->
      ignore (Room.init config ~agent_name:(Some "owner"));
      let run_dir = Filename.concat (swarm_live_dir config) "run-001" in
      let slot_samples_path = Filename.concat run_dir "slot-samples.jsonl" in
      let noise_rows =
        List.init 2200 (fun idx ->
            make_slot_sample
              ~timestamp:(Printf.sprintf "2026-03-23T00:%02d:00Z" idx)
              ~active_slots:1 ~ctx_per_slot:(2048 + idx))
      in
      let rows =
        [ make_slot_sample ~timestamp:"2026-03-23T00:00:00Z" ~active_slots:99
            ~ctx_per_slot:1024 ]
        @ noise_rows
        @ [
            make_slot_sample ~timestamp:"2026-03-23T00:03:00Z" ~active_slots:7
              ~ctx_per_slot:8192;
            make_slot_sample ~timestamp:"2026-03-23T00:04:00Z" ~active_slots:8
              ~ctx_per_slot:16384;
            make_slot_sample ~timestamp:"2026-03-23T00:05:00Z" ~active_slots:9
              ~ctx_per_slot:32768;
          ]
      in
      write_jsonl_rows slot_samples_path rows;
      let json = Command_plane_v2.summary_json config in
      let swarm_proof = Yojson.Safe.Util.member "swarm_proof" json in
      Alcotest.(check string) "fallback source" "slot_samples"
        (swarm_proof |> Yojson.Safe.Util.member "source"
       |> Yojson.Safe.Util.to_string);
      Alcotest.(check int) "peak_hot_slots uses recent tail only" 9
        (swarm_proof |> Yojson.Safe.Util.member "peak_hot_slots"
       |> Yojson.Safe.Util.to_int);
      Alcotest.(check int) "ctx_per_slot follows latest tail sample" 32768
        (swarm_proof |> Yojson.Safe.Util.member "ctx_per_slot"
       |> Yojson.Safe.Util.to_int))
