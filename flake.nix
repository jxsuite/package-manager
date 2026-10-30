{
  description = "Jx's lockfile-only package service, as a container image for the Jx cloud platform";

  # One input on purpose: Dependabot's `nix` ecosystem bumps it weekly, and every other dependency
  # comes from package-lock.json, which Dependabot's `npm` ecosystem bumps. Neither leaves a hash
  # behind for a human to refresh (see `npmDeps` below).
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      manifest = lib.importJSON ./package.json;
      serverVersion = manifest.dependencies."@jxsuite/server";
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./package.json
              ./package-lock.json
              ./entry.ts
              ./scripts/prune-modules.mjs
            ];
          };

          # The runtime is Node, the version line Electron's desktop backend runs the same installer on,
          # so the cloud and the desktop answer a package operation identically. Slim, because npm is
          # only needed by the build.
          node = pkgs.nodejs-slim_24;

          # The service is `@jxsuite/server/packages-service` and nothing else, built the way the
          # desktop app builds its backend. @jxsuite/server publishes TypeScript sources, which Node
          # will not strip inside node_modules, so esbuild compiles entry.ts and everything it reaches
          # into one ESM bundle for Node. Arborist stays out of it, because it finds helpers of its
          # own by path at run time (node-gyp's, @npmcli/run-script's), and node_modules is cut down
          # to Arborist and its dependencies.
          service = pkgs.buildNpmPackage {
            pname = "jx-package-service";
            inherit (manifest) version;
            inherit src;

            # importNpmLock fetches every tarball by the integrity package-lock.json already records,
            # so there is no `npmDepsHash` to go stale: a Dependabot lockfile bump builds as it lands.
            npmDeps = pkgs.importNpmLock { npmRoot = src; };
            npmConfigHook = pkgs.importNpmLock.npmConfigHook;

            # No install script runs, here or in the image: the service only resolves lockfiles, and
            # the native addons @jxsuite/server's other entry points carry are never loaded.
            npmFlags = [ "--ignore-scripts" ];
            npmRebuildFlags = [ "--ignore-scripts" ];
            dontPatchShebangs = true;
            disallowedReferences = [
              pkgs.bun
              pkgs.esbuild
              pkgs.nodejs
              pkgs.python3
            ];

            nativeBuildInputs = [
              pkgs.esbuild
              pkgs.makeWrapper
            ];
            # `#serve` resolves to its Node side under esbuild's default conditions. ws's optional
            # native speedups are `require`d inside a try and are not installed, so they stay
            # external; the banner gives the ESM bundle the `require` its inlined CommonJS calls.
            buildPhase = ''
              runHook preBuild
              esbuild entry.ts --bundle --platform=node --format=esm --target=node24 \
                --external:@npmcli/arborist --external:bufferutil --external:utf-8-validate \
                --banner:js="import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);" \
                --outfile=dist/index.mjs
              if grep -Eq '\bBun\.[A-Za-z]+' dist/index.mjs; then
                echo "the service bundle calls a Bun API; it runs on Node" >&2
                exit 1
              fi
              node scripts/prune-modules.mjs node_modules @npmcli/arborist
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib/jx-package-service $out/bin
              # npm's hidden lockfile records each package's `resolved` as the store path importNpmLock
              # fetched it to, which would carry every tarball into the image beside its unpacked copy.
              rm -f node_modules/.package-lock.json
              cp -r node_modules $out/lib/jx-package-service/
              cp dist/index.mjs $out/lib/jx-package-service/
              # npmConfigHook points the packages' scripts at Nix's interpreters (Node for bin scripts,
              # Python for node-gyp). Nothing here runs them, and each reference would put another
              # runtime in the image, so they go back to the `env` form they were published with.
              grep -rlZ '^#!/nix/store/' $out/lib | xargs -0 -r sed -i '1s|^#!/nix/store/[^/]*/bin/|#!/usr/bin/env |'
              makeWrapper ${lib.getExe node} $out/bin/jx-package-service \
                --add-flags $out/lib/jx-package-service/index.mjs
              runHook postInstall
            '';

            meta.mainProgram = "jx-package-service";
          };

          image = pkgs.dockerTools.streamLayeredImage {
            name = "ghcr.io/jxsuite/package-manager";
            tag = "latest";
            # Arborist writes each request's scratch directory and its cache under /tmp.
            extraCommands = "mkdir -m 1777 tmp";
            config = {
              Cmd = [ (lib.getExe service) ];
              Env = [
                "PORT=8080"
                "HOME=/tmp"
                "NODE_ENV=production"
                "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              ];
              ExposedPorts."8080/tcp" = { };
              User = "65534:65534";
              Labels = {
                "org.opencontainers.image.source" = "https://github.com/jxsuite/package-manager";
                "org.opencontainers.image.description" =
                  "Jx's lockfile-only package service (@jxsuite/server ${serverVersion})";
                "org.opencontainers.image.licenses" = "MIT";
                "org.opencontainers.image.revision" = self.rev or "dirty";
                "org.opencontainers.image.version" = serverVersion;
              };
            };
          };
        in
        {
          inherit service image;
          default = service;
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.esbuild
            pkgs.nodejs_24
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
