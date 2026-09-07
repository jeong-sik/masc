# Main integration regression

The production source interpreter passed 89 Firefox assertions after
merging BrowserInteract, explicit Gecko binary selection, and native client
routing from main.
PNG structure and pixel-stream validation also passed in the Python harness.
The run used stock Firefox 155.0.1 and geckodriver 0.37.1.

New coverage switches from a nested cross-origin frame to BrowserInteract,
checks the returned task tab, rejects a stale expected URL, and confirms the
rejected fill did not overwrite the form input. The complete frame, dialog,
upload lifetime, multipart, download and session teardown scenario also ran.

This is source-interpreter evidence. Its download publisher is the explicit
byte-count callback; compiled CI separately exercises the real durable store
and paged artifact reader. No deployed Keeper/model execution is claimed.
