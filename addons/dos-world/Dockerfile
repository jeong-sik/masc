# Build only in CI. Both stages use the same pinned, multi-architecture image.
FROM node:22-bookworm-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5 AS build
RUN apt-get update && apt-get install -y --no-install-recommends nasm \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/dos-world
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts
COPY . .
RUN nasm -f bin guest/lanedemo.asm -o guest/LANEDEMO.COM \
    && sha256sum guest/lanedemo.asm guest/LANEDEMO.COM environment/dosbox.conf \
       node_modules/emulators/dist/emulators.js node_modules/emulators/dist/wdosbox.js \
       node_modules/emulators/dist/wdosbox.wasm > BUILD_SHA256SUMS

FROM node:22-bookworm-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5
WORKDIR /opt/dos-world
COPY --from=build /opt/dos-world ./
USER 65534:65534
CMD ["node", "/opt/dos-world/server.mjs"]
