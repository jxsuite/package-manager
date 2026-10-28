# Jx package manager image

The container image the [Jx cloud platform](https://jxsuite.com) runs its package service in: `@jxsuite/server/packages-service` on Bun, built with Nix. Studio's add, remove and update-versions operations for a cloud project run here, lockfile-only. Nothing is installed: the service resolves against the public npm registry, runs no install script, and answers with the project's new `package.json` and `package-lock.json`.

```
ghcr.io/jxsuite/package-manager:latest
ghcr.io/jxsuite/package-manager:sha-<commit>
ghcr.io/jxsuite/package-manager:server-<@jxsuite/server version>
```

The protocol is `POST /` with `{ op, args, files }`, plus `GET /health`. It is defined, with its tests, in [`packages/server/src/packages-service.ts`](https://github.com/jxsuite/jx/blob/main/packages/server/src/packages-service.ts) in the jx repository. This repository only packages it.

## How it stays current

- **Dependabot** bumps `package-lock.json` daily (this is how a new `@jxsuite/server` reaches the image), the flake's nixpkgs input weekly, and the workflows' actions weekly.
- **Auto-merge** (`.github/workflows/dependabot-auto-merge.yml`) hands each of those pull requests to GitHub, which merges it once `ci` is green. `ci` is a required check on `main`.
- **`ci`** (`.github/workflows/ci.yml`) builds the image with Nix, runs `scripts/smoke.sh` against it (health, an add and a remove against the real registry, two refusals), and on `main` pushes it. An image that fails the smoke test is never pushed.

A merge made by auto-merge starts no `push` workflow, so `ci` also runs hourly and publishes any `main` commit that has no `sha-<commit>` tag yet.

There is no hash to refresh by hand: npm tarballs are fetched by the integrity `package-lock.json` already records (`importNpmLock`), and nixpkgs is the flake's only input.

## Building locally

```sh
nix build .#image
./result | docker load
scripts/smoke.sh ghcr.io/jxsuite/package-manager:latest
```

The image is about 260 MB uncompressed: Bun, glibc, the CA bundle and `@jxsuite/server`'s dependency tree. Interpreter shebangs inside `node_modules` are rewritten to `/usr/bin/env` so that neither Node nor Python is pulled in, and the build refuses either one as a reference.

## Using it from Cloudflare Containers

Cloudflare Containers cannot pull from ghcr.io, so the platform's container Dockerfile is one line that wrangler builds and pushes to Cloudflare's own registry:

```dockerfile
FROM ghcr.io/jxsuite/package-manager:server-8.0.0
```

The image listens on `PORT` (default 8080) as an unprivileged user and reaches only `registry.npmjs.org`.

## License

MIT
