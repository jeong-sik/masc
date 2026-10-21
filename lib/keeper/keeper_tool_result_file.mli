(** Read only the server-selected original invocation from a retained keeper
    trace. No file-size allocation or duplicate body store. Memory includes
    the largest JSONL record, its JSON AST and the selected redacted result. *)
type reading = {
  body : Keeper_tool_result_source.body;
  source_id : string;
  sha256 : string;
}
val read :
  config:Workspace.config -> keeper:string -> Keeper_tool_result_source.target ->
  (reading, string) result
(** Keeper containment, owned no-follow reads and full descriptor snapshot
    equality are checked for every chunk and a final EOF observation. The whole
    retained range is scanned; an early matching finish cannot hide duplicates.
    A missing, changed or invalid source is an error, never a shorter success. *)

module For_testing : sig
  val read :
    read_range:(offset:int -> max_bytes:int -> string ->
      (Fs_compat.owned_regular_file_range option, Fs_compat.owned_regular_file_read_error) result) ->
    config:Workspace.config -> keeper:string -> Keeper_tool_result_source.target ->
    (reading, string) result
end
