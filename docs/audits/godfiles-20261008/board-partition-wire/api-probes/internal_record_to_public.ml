module P = Masc.Keeper_board_attention_partition
module Internal = Masc__Keeper_board_attention_partition_types
let smuggle (p : Internal.t) = P.to_yojson p
