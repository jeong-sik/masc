# Persistent Docker image selection

A Keeper whose `sandbox_image` changes previously adopted its running container because the persistent coordinate contained only keeper, network mode and base path. The requested image reached configuration and approval records, but the reused container could still run the previous image.

The Docker coordinate now includes the full SHA256 of the resolved image reference. Startup resolves the reference once and uses that value for both the coordinate and image creation. The same reference adopts the same running container; a changed reference creates or adopts another coordinate. This does not refresh mutable contents behind an unchanged tag.

An existing turn retains its cached Running container and immutable metadata. New turn runtimes use the new configuration. Both coordinates retain the same host workspace, and this change neither stops nor removes the older running container. Existing keeper teardown remains label-based and removes all persistent coordinates for that keeper/base.

The Docker route behavior test invokes real CLI fixture subprocesses. It verifies old image creation, same-image adoption, changed-image creation, new-image adoption, continued old-turn selection, exactly two create commands with the requested images, no stop/remove commands, and preserved workspace path/content. It does not prove Docker isolation. No local build was performed; behavioral execution is delegated to CI.
