# Recording availability build failure

[Run36610580606](https://github.com/jeong-sik/masc/actions/runs/36610580606), head `379a90db85b9a8969f68b2c160eb622c7e620db5`, failed before executing any selected behavioral suite. The new registry-publication scenario referenced `Candle_config` without declaring its library directly in the test stanza. Dune reports an unbound module at test_candle_goal_flow.ml:254.

Commit `57d584cbbc6b61841b1072054faa7a5031b79020` adds the direct `masc_candle_config` dependency. Syntax-only parsing did not establish module visibility. Native behavior after that fix remains unverified here. The full original log is retained, including the seven-suite build command.
