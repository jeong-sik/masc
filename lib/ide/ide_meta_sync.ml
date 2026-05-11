(** IDE meta sync — Keeper activity → .masc-ide/ synchronization engine. *)

open Ide_annotation_types
open Ide_region_tracker

type config =
  { base_path : string
  ; flush_on_turn_complete : bool
  ; batch_size : int
  }

let default_config = { base_path = ""; flush_on_turn_complete = true; batch_size = 100 }

type sync_state =
  { pending_regions : code_region list
  ; pending_annotations : annotation list
  ; last_flush_time : float
  ; turn_count : int
  }

let initial_state =
  { pending_regions = []
  ; pending_annotations = []
  ; last_flush_time = Unix.gettimeofday ()
  ; turn_count = 0
  }
;;

let extract_regions_from_tool_call
      ~(keeper_id : string)
      ~(turn : int)
      ~(tool_name : string)
      ~(file_path : string)
      ~(diff_text : string option)
      ~(full_content : string option)
  : code_region list
  =
  match diff_text, full_content with
  | Some diff, _ -> extract_regions_from_diff ~keeper_id ~file_path ~turn ~diff_text:diff
  | None, Some content ->
    let region = extract_region_from_full_file ~keeper_id ~file_path ~turn ~content in
    [ region ]
  | None, None -> []
;;

let queue_regions (state : sync_state) (regions : code_region list) : sync_state =
  { state with
    pending_regions = List.rev_append (List.rev regions) state.pending_regions
  }
;;

let flush_regions (config : config) (state : sync_state) : sync_state =
  match state.pending_regions with
  | [] -> state
  | pending ->
    let index_file = Filename.concat config.base_path ".masc-ide/index.jsonl" in
    let ensure_dir () =
      let dir = Filename.dirname index_file in
      if not (Sys.file_exists dir) then Unix.mkdir dir 0o755
    in
    ensure_dir ();
    let oc = open_out_gen [ Open_append; Open_creat; Open_binary ] 0o644 index_file in
    Fun.protect
      ~finally:(fun () -> close_out oc)
      (fun () ->
         List.iter
           (fun (region : code_region) ->
              let json =
                `Assoc
                  [ "file_path", `String region.file_path
                  ; "line_start", `Int region.line_start
                  ; "line_end", `Int region.line_end
                  ; "keeper_id", `String region.keeper_id
                  ; ( "source"
                    , `String
                        (match region.source with
                         | Tool_call { tool_name; turn } ->
                           Printf.sprintf "tool:%s:turn:%d" tool_name turn
                         | Manual { note } -> Printf.sprintf "manual:%s" note) )
                  ; "timestamp_ms", `Intlit (Int64.to_string region.timestamp_ms)
                  ]
              in
              output_string oc (Yojson.Safe.to_string json);
              output_char oc '\n')
           pending);
    { state with pending_regions = []; last_flush_time = Unix.gettimeofday () }
;;

let on_tool_call_complete
      config
      state
      ~keeper_id
      ~turn
      ~tool_name
      ~file_path
      ~diff_text
      ~full_content
  =
  let regions =
    extract_regions_from_tool_call
      ~keeper_id
      ~turn
      ~tool_name
      ~file_path
      ~diff_text
      ~full_content
  in
  let state = queue_regions state regions in
  if List.length state.pending_regions >= config.batch_size
  then flush_regions config state
  else state
;;

let on_turn_complete config state =
  if config.flush_on_turn_complete
  then flush_regions config { state with turn_count = state.turn_count + 1 }
  else state
;;

type stats =
  { pending_region_count : int
  ; pending_annotation_count : int
  ; turn_count : int
  ; last_flush_ago : float
  }

let get_stats (state : sync_state) : stats =
  { pending_region_count = List.length state.pending_regions
  ; pending_annotation_count = List.length state.pending_annotations
  ; turn_count = state.turn_count
  ; last_flush_ago = Unix.gettimeofday () -. state.last_flush_time
  }
;;
