(** masc-trace — print receipts matching a (keeper, turn_id) pair.

    This is the foundation of the Step 10 turn-tracing CLI from the
    bloodflow restoration plan.  The first cut intentionally reads
    only execution-receipts JSONL since that's the path that already
    populates [turn_count] (post-Step 0a it carries the structured
    [keeper_turn_id] for silent skip / cascade error / livelock
    paths too).

    Follow-up stacks will widen the source set:
      - .masc/tool_calls/<YYYY-MM>/<DD>.jsonl
      - .masc/logs/system_log_<date>.jsonl (post 0a-2 caller adoption)
      - .masc/traces/<keeper>/<trace_id>/

    Usage:  masc-trace <base-path> <keeper> <turn_id>
    Example: masc-trace ~/me nick0cave 5
*)

let usage_and_exit () =
  prerr_endline "Usage: masc-trace <base-path> <keeper> <turn_id>";
  exit 2

let read_lines path =
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    let acc = ref [] in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        try
          while true do
            acc := input_line ic :: !acc
          done;
          assert false
        with End_of_file -> List.rev !acc)

let int_field json key =
  match Yojson.Safe.Util.member key json with `Int n -> Some n | _ -> None

let string_field json key =
  match Yojson.Safe.Util.member key json with
  | `String s -> Some s
  | _ -> None

let receipts_dir ~base_path ~keeper =
  List.fold_left Filename.concat base_path
    [ ".masc"; "keepers"; keeper; "execution-receipts" ]

let dump_receipts ~base_path ~keeper ~turn_id =
  let dir = receipts_dir ~base_path ~keeper in
  if not (Sys.file_exists dir) then begin
    Printf.eprintf "[masc-trace] no receipts dir: %s\n" dir;
    ()
  end
  else
    let files =
      Sys.readdir dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".jsonl")
      |> List.sort compare
    in
    let matches =
      List.concat_map
        (fun f ->
          let path = Filename.concat dir f in
          read_lines path
          |> List.filter_map (fun line ->
                 try
                   let json = Yojson.Safe.from_string line in
                   if int_field json "turn_count" = Some turn_id then
                     Some (f, json)
                   else None
                 with _ -> None))
        files
    in
    if matches = [] then
      Printf.eprintf
        "[masc-trace] no receipt found for keeper=%s turn_id=%d\n"
        keeper turn_id
    else
      List.iter
        (fun (f, json) ->
          let outcome =
            Option.value (string_field json "outcome") ~default:"-"
          in
          let reason =
            Option.value
              (string_field json "terminal_reason_code")
              ~default:"-"
          in
          let cascade =
            Option.value (string_field json "cascade_name") ~default:"-"
          in
          let ended =
            Option.value (string_field json "ended_at") ~default:"-"
          in
          Printf.printf
            "%s [receipt %s] cascade=%s outcome=%s reason=%s\n"
            ended f cascade outcome reason)
        matches

let () =
  match Array.to_list Sys.argv with
  | _ :: base_path :: keeper :: turn_id_str :: _ -> (
      match int_of_string_opt turn_id_str with
      | Some turn_id -> dump_receipts ~base_path ~keeper ~turn_id
      | None ->
          prerr_endline "turn_id must be an integer";
          usage_and_exit ())
  | _ -> usage_and_exit ()
