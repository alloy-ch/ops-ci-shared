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

# check that each module contains something deployable
for module in "${MODULES[@]}"; do
  pushd "${module}"
  if ! { [[ -f "./package.json" && -f "./package-lock.json" ]] || [[ -f "./playbook.yml" ]]; }; then
    echo "No deployable unit found in ./${module}. Nothing will be deployed."
    exit 1
  fi
  popd
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
    ansible-playbook -e env="$ENV" playbook.yml
  fi

  popd
done
