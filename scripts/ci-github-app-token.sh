#!/bin/bash
# Prints a GitHub App installation token for this build's repo only, valid for 1 hour.
#
# Usage: ci-github-app-token.sh <ssm prefix> <permissions json>
#   e.g. ci-github-app-token.sh /ops-ci/github-pr-bot '{"pull_requests":"write"}'
# Reads <prefix>/app-id and <prefix>/app-private-key from SSM. The permissions must be a subset of the app's.

set -euo pipefail

prefix=$1
permissions=$2

ssm_value() {
  aws --region "${AWS_REGION}" ssm get-parameter --output json --name "$1" --with-decryption | jq -erM '.Parameter.Value'
}

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

key_file=$(mktemp)
trap 'rm -f "$key_file"' EXIT
app_id=$(ssm_value "${prefix}/app-id")
ssm_value "${prefix}/app-private-key" >"$key_file"

# JWT of the app (RS256, at most 10 minutes); iat 60 s in the past against clock drift
now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$app_id" | b64url)
signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$key_file" -binary | b64url)
jwt="${header}.${payload}.${signature}"

# CODEBUILD_SOURCE_REPO_URL is https://github.com/<owner>/<repo>.git
repo_path=$(sed -E 's#^https://github\.com/##; s#\.git$##' <<<"${CODEBUILD_SOURCE_REPO_URL}")
repo_name=${repo_path#*/}

github_api() {
  curl -fsS -H "Authorization: Bearer ${jwt}" -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

installation_id=$(github_api "https://api.github.com/repos/${repo_path}/installation" | jq -erM '.id')
github_api -X POST "https://api.github.com/app/installations/${installation_id}/access_tokens" \
  -d "{\"repositories\":[\"${repo_name}\"],\"permissions\":${permissions}}" | jq -erM '.token'
