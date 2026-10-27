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
  if grep -rqs --include='*.yml' --include='*.yaml' --exclude-dir=node_modules --exclude-dir=.venv \
      "build_push_docker_image" "${module}"; then
    docker_problem=""
    if ! docker info >/dev/null 2>&1; then
      docker_problem="the Docker daemon does not respond"
    elif ! docker buildx version >/dev/null 2>&1; then
      docker_problem="docker buildx is not available"
    fi
    if [[ -n ${docker_problem} ]]; then
      # with a tag selection, the selected tasks may not build any image
      if [[ -n ${ANSIBLE_RUN_TAGS} ]] || [[ -n ${ANSIBLE_SKIP_TAGS} ]]; then
        echo "WARNING: ${module} builds Docker images, but ${docker_problem}"
      else
        echo "Preflight failed: ${module} builds Docker images, but ${docker_problem}"
        exit 1
      fi
    fi
    break
  fi
done

# repo-specific checks, e.g. that the database is reachable (VPN); run in the module folder, before any module deploys
for module in "${MODULES[@]}"; do
  if [[ -f "${module}/preflight.sh" ]] && [[ ! -x "${module}/preflight.sh" ]]; then
    echo "WARNING: ${module}/preflight.sh is not executable, skipping it"
  elif [[ -x "${module}/preflight.sh" ]]; then
    echo "Running ${module}/preflight.sh..."
    pushd "${module}"
    if ! ./preflight.sh; then
      echo "Preflight failed: ${module}/preflight.sh"
      exit 1
    fi
    popd
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
