module Head = Fs_compat.Capability_head

let schema = "masc.keeper-shutdown-generation-floor.v1"
let root_leaf = "keeper-shutdown-generation-floors-v1"
let head_entropy_bytes = 32 * 33
let retry_limit = 2
let fd_backed_parent_opening_key : unit Eio.Fiber.key = Eio.Fiber.create_key ()

type t =
  { keeper_id : string
  ; generation : int64
  }

type error =
  | Invalid_base_path of string
  | Invalid_keeper_id
  | Invalid_generation of int64
  | Filesystem_capability_unavailable
  | Directory_prepare_failed of string
  | Entropy_source_failed of string
  | Invalid_current of string
  | Head_read_failed of Head.failure
  | Head_read_settlement_failed of Head.settlement_warning list
  | Head_write_failed of Head.failure
  | Contention_exhausted of
      { attempts : int
      ; last_failure : Head.failure
      }
  | Published_with_warnings of
      { generation : int64
      ; warnings : Head.settlement_warning list
      }
  | Published_with_failure of
      { generation : int64
      ; failure : Head.failure
      }
  | Publication_indeterminate of
      { generation : int64
      ; failure : Head.failure
      }

let ( let* ) result fn = match result with Ok value -> fn value | Error error -> Error error
let generation floor = floor.generation
let sha256 value = Digestif.SHA256.(to_hex (digest_string value))

let root_path_for_base_path ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) root_leaf
;;

let authority_leaf ~keeper_id =
  let binding =
    Printf.sprintf "keeper-shutdown-generation-floor\000%d:%s" (String.length keeper_id) keeper_id
  in
  "floor-" ^ sha256 binding ^ ".json"
;;

let payload_bytes floor =
  `Assoc
    [ "schema", `String schema
    ; "keeper_id", `String floor.keeper_id
    ; "generation", `Intlit (Int64.to_string floor.generation)
    ]
  |> Yojson.Safe.to_string
;;

let checksum floor =
  sha256 ("keeper-shutdown-generation-floor-checksum-v1\000" ^ payload_bytes floor)
;;

let row_bytes floor =
  `Assoc
    [ "schema", `String schema
    ; "keeper_id", `String floor.keeper_id
    ; "generation", `Intlit (Int64.to_string floor.generation)
    ; "checksum_sha256", `String (checksum floor)
    ]
  |> Yojson.Safe.to_string
;;

let decode_positive_int64 = function
  | `Int value when value > 0 -> Ok (Int64.of_int value)
  | `Intlit raw ->
    (match Int64.of_string_opt raw with
     | Some value
       when Int64.compare value 0L > 0 && String.equal raw (Int64.to_string value) ->
       Ok value
     | Some _ | None -> Error (Invalid_current "generation is not a canonical positive int64"))
  | _ -> Error (Invalid_current "generation is not a canonical positive int64")
;;

let decode_row ~keeper_id raw =
  let invalid detail = Error (Invalid_current detail) in
  match Yojson.Safe.from_string raw with
  | exception Yojson.Json_error _ -> invalid "authority is not current canonical JSON"
  | `Assoc fields ->
    let names = List.map fst fields |> List.sort String.compare in
    let expected =
      [ "checksum_sha256"; "generation"; "keeper_id"; "schema" ]
    in
    if not (List.equal String.equal names expected)
    then invalid "authority does not have the exact current field set"
    else
      (match
         List.assoc_opt "schema" fields,
         List.assoc_opt "keeper_id" fields,
         List.assoc_opt "generation" fields,
         List.assoc_opt "checksum_sha256" fields
       with
       | Some (`String observed_schema), Some (`String observed_keeper), Some generation_json,
         Some (`String observed_checksum)
         when String.equal observed_schema schema && String.equal observed_keeper keeper_id ->
         let* generation = decode_positive_int64 generation_json in
         let floor = { keeper_id; generation } in
         if not (String.equal observed_checksum (checksum floor))
         then invalid "authority checksum does not match"
         else if not (String.equal raw (row_bytes floor))
         then invalid "authority is not canonical"
         else Ok floor
       | _ -> invalid "authority does not match the exact current schema")
  | _ -> invalid "authority is not a JSON object"
;;

let reraise_fatal exception_ backtrace =
  match exception_ with
  | Out_of_memory | Stack_overflow | Sys.Break ->
    Printexc.raise_with_backtrace exception_ backtrace
  | _ -> ()
;;

let directory_failure_to_string = function
  | Keeper_fs_durable_directory.Directory_chain_failed
      (Keeper_fs_durable_directory.Non_directory_ancestor { path }) ->
    "non-directory ancestor: " ^ path
  | Directory_chain_failed (Outside_ownership_root { ownership_root; path }) ->
    Printf.sprintf "path %s is outside ownership root %s" path ownership_root
  | Directory_chain_failed (Missing_root { path }) -> "ownership root is missing: " ^ path
  | Directory_chain_failed (Creation_not_observed { path }) ->
    "directory creation was not observed: " ^ path
  | Operation_failed (exception_, backtrace) ->
    reraise_fatal exception_ backtrace;
    Printexc.to_string exception_
;;

let with_head_parent parent fn =
  match Eio.Fiber.get fd_backed_parent_opening_key with
  | Some () -> Eio.Path.with_open_dir parent fn
  | None -> fn parent
;;

let rec prepare_root ~base_path =
  match Fs_compat.get_fs_opt () with
  | None -> Error Filesystem_capability_unavailable
  | Some fs ->
    let ownership_root = Common.masc_dir_from_base_path ~base_path in
    let root_path = root_path_for_base_path ~base_path in
    (match
       Keeper_fs_durable_directory.ensure
         ~before_prepare:Fun.id
         ~before_directory_fsync:(fun _ -> ())
         ~ownership_root
         root_path
     with
     | Error failure -> Error (Directory_prepare_failed (directory_failure_to_string failure))
     | Ok lease ->
       if Keeper_fs_durable_directory.lease_is_current lease
       then Ok Eio.Path.(fs / root_path)
       else prepare_root ~base_path)
;;

let entropy_source () =
  try Ok (Eio.Flow.string_source (Crypto_rng.generate head_entropy_bytes)) with
  | Eio.Cancel.Cancelled _ as exception_ -> raise exception_
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    reraise_fatal exception_ backtrace;
    Error (Entropy_source_failed (Printexc.to_string exception_))
;;

let validate_inputs ~base_path ~keeper_id =
  if Filename.is_relative base_path
  then Error (Invalid_base_path base_path)
  else if
    String.equal (String.trim keeper_id) ""
    || not (String.equal keeper_id (String.trim keeper_id))
  then Error Invalid_keeper_id
  else Ok ()
;;

let point_read ~base_path ~keeper_id () =
  let* () = validate_inputs ~base_path ~keeper_id in
  let* root = prepare_root ~base_path in
  let* secure_random = entropy_source () in
  match
    with_head_parent root (fun parent ->
      Head.read ~secure_random ~parent ~leaf:(authority_leaf ~keeper_id))
  with
  | Error failure -> Error (Head_read_failed failure)
  | Ok snapshot ->
    let warnings = Head.snapshot_settlement_warnings snapshot in
    if warnings <> []
    then Error (Head_read_settlement_failed warnings)
    else
      (match Head.snapshot_row snapshot with
       | None -> Ok None
       | Some raw -> decode_row ~keeper_id raw |> Result.map Option.some)
;;

let rec record
          ~remaining_retries
          ~attempts
          ~root
          ~keeper_id
          ~requested_generation
  =
  let retry failure =
    if remaining_retries = 0
    then Error (Contention_exhausted { attempts; last_failure = failure })
    else (
      Eio.Fiber.check ();
      Eio.Fiber.yield ();
      record
        ~remaining_retries:(remaining_retries - 1)
        ~attempts:(attempts + 1)
        ~root
        ~keeper_id
        ~requested_generation)
  in
  let leaf = authority_leaf ~keeper_id in
  let* read_random = entropy_source () in
  match with_head_parent root (fun parent -> Head.read ~secure_random:read_random ~parent ~leaf) with
  | Error failure when failure.error = Head.Busy -> retry failure
  | Error failure -> Error (Head_read_failed failure)
  | Ok snapshot ->
    let warnings = Head.snapshot_settlement_warnings snapshot in
    if warnings <> []
    then Error (Head_read_settlement_failed warnings)
    else
      let* current =
        match Head.snapshot_row snapshot with
        | None -> Ok None
        | Some raw -> decode_row ~keeper_id raw |> Result.map Option.some
      in
      (match current with
       | Some floor when Int64.compare floor.generation requested_generation >= 0 -> Ok floor
       | None | Some _ ->
         let desired = { keeper_id; generation = requested_generation } in
         let* write_random = entropy_source () in
         (match
            with_head_parent root (fun parent ->
              Head.compare_and_swap
                ~secure_random:write_random
                ~parent
                ~leaf
                ~expected:(Head.snapshot_cursor snapshot)
                ~row:(row_bytes desired))
          with
          | Ok publication ->
            let warnings = Head.publication_settlement_warnings publication in
            if warnings = []
            then Ok desired
            else Error (Published_with_warnings { generation = requested_generation; warnings })
          | Error failure ->
            (match failure.target_effect, failure.error with
             | Head.Unchanged, (Head.Busy | Head.Conflict _) -> retry failure
             | Head.Published _, _ ->
               Error (Published_with_failure { generation = requested_generation; failure })
             | Head.Publication_indeterminate _, _ ->
               Error (Publication_indeterminate { generation = requested_generation; failure })
             | Head.Unchanged, _ -> Error (Head_write_failed failure))))
;;

let record_exact ~base_path ~keeper_id ~generation () =
  let* () = validate_inputs ~base_path ~keeper_id in
  if Int64.compare generation 0L <= 0
  then Error (Invalid_generation generation)
  else
    let* root = prepare_root ~base_path in
    record
      ~remaining_retries:retry_limit
      ~attempts:1
      ~root
      ~keeper_id
      ~requested_generation:generation
;;

let error_to_string = function
  | Invalid_base_path path -> "shutdown generation floor base path is not absolute: " ^ path
  | Invalid_keeper_id -> "shutdown generation floor keeper_id is invalid"
  | Invalid_generation generation ->
    Printf.sprintf "shutdown generation floor must be positive: %Ld" generation
  | Filesystem_capability_unavailable ->
    "shutdown generation floor filesystem capability is unavailable"
  | Directory_prepare_failed detail ->
    "shutdown generation floor directory preparation failed: " ^ detail
  | Entropy_source_failed detail -> "shutdown generation floor entropy failed: " ^ detail
  | Invalid_current _ ->
    "shutdown generation floor current evidence is invalid; operator reset is required"
  | Head_read_failed _ -> "shutdown generation floor HEAD read failed"
  | Head_read_settlement_failed warnings ->
    Printf.sprintf "shutdown generation floor HEAD read settlement failed (%d warning(s))" (List.length warnings)
  | Head_write_failed _ -> "shutdown generation floor HEAD write failed"
  | Contention_exhausted { attempts; _ } ->
    Printf.sprintf "shutdown generation floor contention exhausted after %d attempts" attempts
  | Published_with_warnings { generation; warnings } ->
    Printf.sprintf "shutdown generation floor %Ld published with %d warning(s)" generation (List.length warnings)
  | Published_with_failure { generation; _ } ->
    Printf.sprintf "shutdown generation floor %Ld published but settlement failed" generation
  | Publication_indeterminate { generation; _ } ->
    Printf.sprintf "shutdown generation floor %Ld publication is indeterminate" generation
;;

module For_testing = struct
  let root_path_for_base_path = root_path_for_base_path
  let authority_leaf = authority_leaf
  let with_fd_backed_parent_opening fn =
    Eio.Fiber.with_binding fd_backed_parent_opening_key () fn
  ;;
end
