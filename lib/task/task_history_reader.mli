(** Bounded reads of one dated file: a [reader] holds the descriptor and a
    block memo that are checked against the file snapshot, and rows are found
    by scanning newlines from a byte offset across any number of transfer
    blocks. [Task_history_page] includes this module. *)

open Task_history_types
open Task_history_inventory

val io_block_bytes : int

module String_set : Set.S with type elt = string

module String_map : Map.S with type key = string

type reader = {
  root : string;
  file : file;
  mutable fd : Unix.file_descr option;
  mutable parent_stat : Unix.stats option;
  mutable block_from : int;
  mutable block_len : int;
  mutable block : string;
  mutable top_block_from : int;
  mutable top_block_len : int;
  mutable top_block : string;
  mutable retained_blocks : (int * int * string) list;
}

val with_reader :
  root:string ->
  file ->
  (reader -> ('a, error) result) ->
  ('a, error) result

val reset_reader_block_memo : reader -> unit

val load_block :
  reader ->
  int -> (unit, error) result

val byte :
  reader ->
  int -> (char, error) result

type row_slice = {
  mutable row_offset : int;
  mutable row_buf : string;
  mutable row_pos : int;
  mutable row_len : int;
}

val slice_to_string : row_slice -> string

val previous_slice :
  reader ->
  row_slice ->
  int -> (bool, error) result

val read_line_at_bounded :
  reader ->
  limit:int ->
  int -> (string option, error) result

val anchor_matches :
  reader ->
  position ->
  (unit, error) result
