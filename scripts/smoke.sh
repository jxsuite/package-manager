#!/usr/bin/env bash
# Run the image and put it through what the platform asks of it: health, an add resolved against the
# real registry as the image's own unprivileged user, and a refusal. CI runs this before anything is
# pushed, so an image that cannot do its one job never reaches ghcr.io.
#
#   nix build .#image && ./result | docker load && scripts/smoke.sh ghcr.io/jxsuite/package-manager:latest
set -euo pipefail

image="${1:?usage: smoke.sh <image>}"
port="${SMOKE_PORT:-18080}"
name="package-manager-smoke-$$"

cleanup() {
  docker logs "$name" >&2 2>&1 || true
  docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --name "$name" -p "127.0.0.1:${port}:8080" "$image" >/dev/null
base="http://127.0.0.1:${port}"

for _ in $(seq 60); do
  curl -sf "$base/health" >/dev/null && break
  sleep 0.5
done
curl -sf "$base/health" | jq -e '.ok == true' >/dev/null
echo "ok: /health"

post() {
  curl -sf "$base/" -H 'content-type: application/json' -d "$1"
}

added="$(post '{"op":"add","args":{"spec":"is-number@^7"},"files":{"package.json":"{\"name\":\"smoke\",\"version\":\"1.0.0\"}"}}')"
jq -e '.result.ok == true' <<<"$added" >/dev/null || { echo "add failed: $added" >&2; exit 1; }
jq -e '.files["package.json"] | fromjson | .dependencies["is-number"] == "^7.0.0"' <<<"$added" >/dev/null
jq -e '.files["package-lock.json"] | fromjson | .packages["node_modules/is-number"].version | startswith("7.")' <<<"$added" >/dev/null
echo "ok: add is-number@^7 wrote package.json and package-lock.json"

removed="$(post "$(jq -c '{op: "remove", args: {name: "is-number"}, files: .files}' <<<"$added")")"
jq -e '.result.ok == true and (.files["package.json"] | fromjson | .dependencies // {} | has("is-number") | not)' <<<"$removed" >/dev/null
echo "ok: remove is-number"

refused="$(post '{"op":"add","args":{"spec":"github:jxsuite/jx"},"files":{"package.json":"{}"}}')"
jq -e '.result.ok == false' <<<"$refused" >/dev/null
echo "ok: a git specifier is refused"

status="$(curl -s -o /dev/null -w '%{http_code}' "$base/" -d '{"op":"publish","args":{},"files":{"package.json":"{}"}}')"
[ "$status" = 400 ] || { echo "expected 400 for an unknown op, got $status" >&2; exit 1; }
echo "ok: an unknown operation is a 400"
