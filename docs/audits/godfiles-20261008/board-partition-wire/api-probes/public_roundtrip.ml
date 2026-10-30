module P = Masc.Keeper_board_attention_partition
let roundtrip (p : P.t) = P.of_yojson (P.to_yojson p)
let epoch () = P.Worker_epoch.generate ()
