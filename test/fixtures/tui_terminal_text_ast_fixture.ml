type item = {
  safe : string;
  raw : string;
}

let render item =
  Terminal_text.single_line item.safe ^ item.raw

let report path err =
  sink (Terminal_text.single_line path) err
