# Installed Ego SDK help inventory

Captured on 2026-10-28 against installed guide v2.1.0 and Ego Lite 0.6.1.11,
while the MASC source inventory targeted pending stack source
`bd800dc94952b00a33efaf1751d24313ffbc2a9a`.

Commands:

```sh
ego-browser skill
ego-browser nodejs -e 'help()'
```

The guide was byte-identical to the already-read installed v2.1.0 guide.
`help.txt` contains the complete unmodified 445-line help output, including
its update notice. SHA256:
`891d2f472bb48baf7f305db3f8998b186f6967780be11b2644371d38552bda6e`.
`inventory.json` records all 74 unique API/property/handle entries. They match
all 74 rows in the coverage guide, with no missing or extra entries.

This is API discovery evidence only. No profiles were enumerated or selected;
no Space was created, claimed, taken over or finished; no Page operation was
performed, and Ego was not upgraded. Space 32's control-return question remained
pending. The help listing does not prove MASC source support, SDK execution,
installed Keeper behavior, window visibility or login. See the coverage guide
for those distinct boundaries and the remaining gaps.
