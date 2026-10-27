#!/bin/bash

set -e

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_NAME=$(basename $(realpath "${dir}/../../"))

# shellcheck source=.
. "$dir"/ci-safeguard.sh

if [[ $(cat /tmp/is_deploy_flag 2>/dev/null) != "1" ]]; then
  if [[ ${AGGRESSIVE_DEVELOPMENT} == "1" ]]; then
    echo "Skipping deploy as FORCE_DEPLOY is not set and branch isn't develop or main"
  else
    echo "Skipping deploy as deployment flag is not set"
  fi
  echo "(ci-init.sh sets /tmp/is_deploy_flag in CI. For a local deploy, run: echo 1 > /tmp/is_deploy_flag)"
  exit 0
fi

if [[ -z ${ANSIBLE_FOLDERS} ]]; then
  ANSIBLE_FOLDERS="infrastructure"
fi

if [[ -z ${INFRASTRUCTURE_FOLDERS} ]]; then
  INFRASTRUCTURE_FOLDERS=${ANSIBLE_FOLDERS}
fi

if [[ -z ${OPS_CI_AWS_BRANCH} ]]; then
  OPS_CI_AWS_BRANCH="main"
fi

if [[ -z ${ANSIBLE_VERBOSITY} ]]; then
  ANSIBLE_VERBOSITY="1"
fi

# shellcheck source=.
. "$dir"/ci-include.sh

MODULES=(${INFRASTRUCTURE_FOLDERS//,/ })

# PR Environment condition
if [[ $(cat /tmp/is_pr_env_deploy_flag 2>/dev/null) == "1" ]] && [[ $(cat /tmp/pr_number 2>/dev/null) =~ ^[0-9]+$ ]]; then
  PR_NUMBER="$(cat /tmp/pr_number 2>/dev/null)"
  IS_PR_ENV_BUILD="true"
else
  IS_PR_ENV_BUILD="false"
fi


# check that each module contains something deployable
for module in "${MODULES[@]}"; do
  pushd "${module}"
  if ! { [[ -f "./package.json" && -f "./package-lock.json" ]] || [[ -f "./playbook.yml" ]]; }; then
    echo "No deployable unit found in ./${module}. Nothing will be deployed."
    exit 1
  fi
  popd
done

# preflight: fail in the first seconds rather than after the images are built and pushed
if [[ -n ${ANSIBLE_RUN_TAGS} ]] || [[ -n ${ANSIBLE_SKIP_TAGS} ]]; then
  echo "Partial deploy: ANSIBLE_RUN_TAGS=\"${ANSIBLE_RUN_TAGS}\" ANSIBLE_SKIP_TAGS=\"${ANSIBLE_SKIP_TAGS}\""
fi

for module in "${MODULES[@]}"; do
  if grep -rqs --include='*.yml' "build_push_docker_image" "${module}"; then
    if ! docker info >/dev/null 2>&1; then
      echo "Preflight failed: ${module} builds Docker images, but the Docker daemon does not respond"
      exit 1
    fi
    if ! docker buildx version >/dev/null 2>&1; then
      echo "Preflight failed: ${module} builds Docker images, but docker buildx is not available"
      exit 1
    fi
    break
  fi
done

# repo-specific checks, e.g. that the database is reachable (VPN)
for module in "${MODULES[@]}"; do
  if [[ -x "${module}/preflight.sh" ]]; then
    echo "Running ${module}/preflight.sh..."
    if ! "${module}/preflight.sh"; then
      echo "Preflight failed: ${module}/preflight.sh"
      exit 1
    fi
  fi
done

for module in "${MODULES[@]}"; do
  echo Deploying "${module}" module...
  pushd "${module}"

  if [[ -f "./package.json" && -f "./package-lock.json" ]]; then
    npm --no-color ci
    npm --no-color run cdk diff -- --context env=${ENV}
    npm --no-color run cdk deploy -- --all --require-approval=never --context env=${ENV}
  else
    if [[ ${OPS_CI_AWS_BRANCH} != "main" || ${REPO_NAME} == "ops-ci-codebuild-image" ]]; then
      # install the collection for CI/CD (the main branch is already baked into the CodeBuild custom image)
      ansible-galaxy collection install --force git+https://github.com/alloy-ch/ops-ci-aws.git,"${OPS_CI_AWS_BRANCH}"
    fi

    if [[ -f "requirements.txt" ]]; then
      pip install -r requirements.txt
    fi

    if [[ "$IS_PR_ENV_BUILD" != "true" ]]; then
      ansible-playbook -e env="$ENV" -e project_id="$PROJECT_ID" playbook.yml
    else
      ansible-playbook -e env="$ENV" -e project_id="$PROJECT_ID" -e is_pr_env_build="$IS_PR_ENV_BUILD" -e pr_number="$PR_NUMBER" playbook.yml
    fi
    
  fi

  popd
done
