#!/bin/bash

set -e

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

if [[ ${CODEBUILD_BUILD_SUCCEEDING} == "1" ]] && [[ -f /tmp/pr_env_url ]] && [[ $(cat /tmp/pr_number 2>/dev/null) =~ ^[0-9]+$ ]]; then
  PR_NUMBER="$(cat /tmp/pr_number 2>/dev/null)"
  URL=$(cat /tmp/pr_env_url 2>/dev/null)

  # token of the PR bot app, limited to this repo's PRs
  if GH_TOKEN=$("$dir"/ci-github-app-token.sh /ops-ci/github-pr-bot '{"pull_requests":"write"}'); then
    export GH_TOKEN
    gh pr comment "$PR_NUMBER" -b "The PR environment is ready at ${URL} (${ENV} @ \`${CODEBUILD_RESOLVED_SOURCE_VERSION}\`)" > /dev/null
  else
    echo "WARNING: no token of the GitHub PR bot app, no PR comment. The PR environment is ready at ${URL}"
  fi

fi

rm -f /tmp/pr_env_url
rm -f /tmp/pr_number
