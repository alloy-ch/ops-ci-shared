#!/bin/bash

set -e

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# shellcheck source=.
. "$dir"/ci-safeguard.sh

if [[ -f /tmp/is_deploy_flag ]]; then
  rm /tmp/is_deploy_flag
fi

# NOTE: All the actions below are only executed conditionally on the hook which triggers the build.
#       And the hooks which trigger CodeBuild project builds are environment and project and also repo specific,
#       e.g. as of 2023-09-14 the only repositories which will trigger CodeBuild deployments on a git tag push
#       are rcplus-alloy-cockpit-*. The triggering hooks are defined in
#       https://github.com/alloy-ch/ops-ci-codebuild/blob/main/infrastructure/roles/configure-ci/files/cf-codebuild.yml#L198
if [[ ${AGGRESSIVE_DEVELOPMENT} == "1" ]]; then
  if [[ ${CODEBUILD_WEBHOOK_HEAD_REF} == "refs/heads/develop" ]] || [[ ${CODEBUILD_WEBHOOK_HEAD_REF} == "refs/heads/main" ]]; then
    DEPLOYING="Will deploy (because: develop or main branch)"
    echo "1" > /tmp/is_deploy_flag
  elif [[ ${FORCE_DEPLOY} == "1" ]] || [[ ${FORCE_DEPLOY} == "true" ]]; then
    DEPLOYING="Will deploy (because: FORCE_DEPLOY)"
    echo "1" > /tmp/is_deploy_flag
  else
    DEPLOYING="Will not deploy"
  fi
else
  if [[ ${CODEBUILD_WEBHOOK_HEAD_REF} == "refs/heads/main" ]] && [[ ${ENV} == "stg" ]]; then
    DEPLOYING="Will deploy (because: main on stg)"
    echo "1" > /tmp/is_deploy_flag
  elif [[ ${CODEBUILD_WEBHOOK_HEAD_REF} == "refs/tags/v"* ]] && [[ ${ENV} == "prod" ]]; then
    DEPLOYING="Will deploy (because: tag on prod)"
    echo "1" > /tmp/is_deploy_flag
  elif [[ ${FORCE_DEPLOY} == "1" ]] || [[ ${FORCE_DEPLOY} == "true" ]]; then
    DEPLOYING="Will deploy (because: FORCE_DEPLOY)"
    echo "1" > /tmp/is_deploy_flag
  else
    DEPLOYING="Will not deploy"
  fi
fi

echo ENV=\""${ENV}"\", CODEBUILD_WEBHOOK_HEAD_REF=\""${CODEBUILD_WEBHOOK_HEAD_REF}"\", FORCE_DEPLOY=\""${FORCE_DEPLOY}"\". "${DEPLOYING}".

# shellcheck disable=SC2046
echo /tmp/is_deploy_flag: \"$(cat /tmp/is_deploy_flag 2>/dev/null)\"

# Setup npmrc
if [[ ! -f ~/.npmrc ]]; then
  echo "Creating ~/.npmrc"
  github_token=$(aws --region "${AWS_REGION}" ssm get-parameter --output json --name /ops-ci/github-access-token --with-decryption | jq -crM '.Parameter.Value')
  echo "//npm.pkg.github.com/:_authToken=$github_token" >> ~/.npmrc
  echo "ringier-data:registry=https://npm.pkg.github.com" >> ~/.npmrc
  echo "alloy-ch:registry=https://npm.pkg.github.com" >> ~/.npmrc
else
  echo "Skipping ~/.npmrc as already exists"
fi

# Login into Docker/ECR
registry_uri=$(aws --region "${AWS_REGION}" sts get-caller-identity --output json | jq -r '.Account').dkr.ecr.${AWS_REGION}.amazonaws.com
password=$(aws --region "${AWS_REGION}" ecr get-login-password 2>/dev/null)
if [[ -z ${password} ]]; then
    echo "No credential retrieved. This is ok if this is the very first run at a new AWS account."
else
    echo "$password" | docker login --username AWS --password-stdin "$registry_uri"
fi
