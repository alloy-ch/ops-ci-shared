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

# deployment record: which ref of this repo the environment runs, who deployed it and when
if [[ -n ${CODEBUILD_BUILD_ID} ]]; then
  DEPLOY_REPO=$(basename -s .git "${CODEBUILD_SOURCE_REPO_URL}")
  # as in ci-notify-slack.sh: refs/heads/develop ==> develop, otherwise the source version of the build
  DEPLOY_REF=${CODEBUILD_WEBHOOK_HEAD_REF//refs\/heads\//}
  DEPLOY_REF=${DEPLOY_REF:-${CODEBUILD_SOURCE_VERSION}}
  DEPLOY_COMMIT=${CODEBUILD_RESOLVED_SOURCE_VERSION}
  DEPLOY_WHERE="codebuild:${CODEBUILD_BUILD_ID}"
else
  DEPLOY_REPO=$(basename -s .git "$(git config --get remote.origin.url 2>/dev/null)")
  # empty on a detached HEAD, which then records the commit as the ref
  DEPLOY_REF=$(git symbolic-ref --short -q HEAD 2>/dev/null || true)
  DEPLOY_COMMIT=$(git rev-parse HEAD 2>/dev/null || true)
  DEPLOY_REF=${DEPLOY_REF:-${DEPLOY_COMMIT}}
  if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
    DEPLOY_COMMIT="${DEPLOY_COMMIT}+uncommitted"
  fi
  DEPLOY_WHERE="laptop"
fi
DEPLOY_REPO=${DEPLOY_REPO:-${REPO_NAME}}
DEPLOY_REF=${DEPLOY_REF:-${DEPLOY_COMMIT}}
DEPLOY_PARAM="/ops-ci/deployments/${DEPLOY_REPO}"
DEPLOY_WHO=$(aws --region "${AWS_REGION}" sts get-caller-identity --query Arn --output text 2>/dev/null | awk -F/ '{print $NF}')

function build_record() {
  jq -cn --arg ref "${DEPLOY_REF}" --arg commit "${DEPLOY_COMMIT}" --arg who "${DEPLOY_WHO}" \
    --arg where "${DEPLOY_WHERE}" --arg status "$1" --arg when "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg run_tags "${ANSIBLE_RUN_TAGS}" --arg skip_tags "${ANSIBLE_SKIP_TAGS}" \
    --argjson last_succeeded "${last_succeeded:-null}" \
    '{ref: $ref, commit: $commit, who: $who, where: $where, status: $status, when: $when,
      run_tags: $run_tags, skip_tags: $skip_tags}
     + (if $status == "succeeded" or $last_succeeded == null then {} else {last_succeeded: $last_succeeded} end)'
}

function record_deployment() {
  local error
  if ! error=$(aws --region "${AWS_REGION}" ssm put-parameter --name "${DEPLOY_PARAM}" --type String --overwrite \
      --value "$1" 2>&1 >/dev/null); then
    echo "WARNING: could not record the deployment in ${DEPLOY_PARAM}:$(tr -s '\n' ' ' <<<"${error}")"
  fi
}

# deploy summary: the record, the data the roles published with ansible.builtin.set_stats (printed as one
# `RUN: {...}` line per playbook with ANSIBLE_SHOW_CUSTOM_STATS=true), the task counts of the play recaps, and the
# failed tasks from the files of the ansible.builtin.junit callback (which honours no_log)
DEPLOY_OUTPUT_DIR=${DEPLOY_OUTPUT_DIR:-/tmp/ci-deploy/${DEPLOY_REPO}}
mkdir -p "${DEPLOY_OUTPUT_DIR}/junit"
rm -f "${DEPLOY_OUTPUT_DIR}/junit/"*.xml "${DEPLOY_OUTPUT_DIR}/summary.json"
: > "${DEPLOY_OUTPUT_DIR}/ansible.log"

function write_summary() {
  if python3 - "$1" "${DEPLOY_OUTPUT_DIR}/ansible.log" "${DEPLOY_OUTPUT_DIR}/junit" \
      "${DEPLOY_OUTPUT_DIR}/summary.json" <<'PYTHON'
import glob
import json
import re
import sys
import xml.etree.ElementTree as ET

ANSI = re.compile(r'\x1b\[[0-9;]*m')
RECAP_LINE = re.compile(r'^\S+\s+:\s+((?:\w+=\d+\s*)+)$')
COUNTERS = ('ok', 'changed', 'unreachable', 'failed', 'skipped', 'rescued', 'ignored')


def merge(target, source):
    for key, value in source.items():
        if isinstance(value, dict) and isinstance(target.get(key), dict):
            merge(target[key], value)
        elif isinstance(value, list) and isinstance(target.get(key), list):
            target[key] = target[key] + value
        else:
            target[key] = value


def main(record, log_path, junit_dir, output_path):
    summary = json.loads(record)
    stats, warnings, recaps = {}, [], 0
    tasks = dict.fromkeys(COUNTERS, 0)
    # only lines in the CUSTOM STATS and PLAY RECAP sections count, so task output shaped like them is ignored
    section = None
    try:
        with open(log_path, errors='replace') as log:  # empty for a CDK-only deploy
            for line in log:
                line = ANSI.sub('', line)
                stripped = line.strip()
                if line.startswith('CUSTOM STATS'):
                    section = 'stats'
                elif line.startswith('PLAY RECAP'):
                    section = 'recap'
                elif section == 'stats' and (not stripped or line.startswith('\t')):
                    # tab-indented `<host>: {...}` and `RUN: {...}` lines, separated by blank lines
                    if line.startswith('\tRUN: '):
                        try:
                            data = json.loads(line[len('\tRUN: '):])
                        except ValueError as error:
                            warnings.append(f'unreadable custom stats line: {error}')
                        else:
                            if isinstance(data, dict):
                                merge(stats, data)
                            else:
                                warnings.append(f'custom stats line is a JSON {type(data).__name__}, not an object')
                elif section == 'recap' and (match := RECAP_LINE.match(stripped)):
                    recaps += 1
                    for counter in match.group(1).split():
                        name, value = counter.split('=')
                        if name in tasks:
                            tasks[name] += int(value)
                else:
                    section = None
    except OSError as error:
        warnings.append(f'unreadable Ansible log: {error}')

    failed_tasks = []
    junit_files = sorted(glob.glob(f'{junit_dir}/*.xml'))
    for path in junit_files:
        try:
            cases = list(ET.parse(path).getroot().iter('testcase'))
        except ET.ParseError as error:
            warnings.append(f'unreadable junit file {path}: {error}')
            continue
        for case in cases:
            for problem in (case.find('failure'), case.find('error')):
                if problem is not None:
                    failed_tasks.append({'task': case.get('name'), 'message': (problem.get('message') or '')[:500]})
    if recaps and not junit_files:
        warnings.append('the junit callback wrote no files, so failed tasks are not listed')

    summary.update({'stats': stats, 'tasks': tasks, 'failed_tasks': failed_tasks, 'warnings': warnings,
                    'log': log_path, 'junit': junit_dir})
    with open(output_path, 'w') as output:
        json.dump(summary, output, indent=2)
        output.write('\n')


main(*sys.argv[1:5])
PYTHON
  then
    echo "Deploy summary (${DEPLOY_OUTPUT_DIR}/summary.json):"
    cat "${DEPLOY_OUTPUT_DIR}/summary.json"
  else
    echo "WARNING: could not write the deploy summary"
  fi
}

# preflight: fail in the first seconds rather than after the images are built and pushed
partial_deploy=false
if [[ -n ${ANSIBLE_RUN_TAGS} ]] || [[ -n ${ANSIBLE_SKIP_TAGS} ]]; then
  partial_deploy=true
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
      if [[ ${partial_deploy} == "true" ]]; then
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

# PR environments are not recorded, they belong to their pull request
if [[ "$IS_PR_ENV_BUILD" != "true" ]]; then
  previous=$(aws --region "${AWS_REGION}" ssm get-parameter --name "${DEPLOY_PARAM}" --query Parameter.Value --output text 2>/dev/null || true)
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"${previous}"; then
    previous=""
  fi
  # what the environment runs: the previous deployment if it succeeded, otherwise the last one that did
  last_succeeded=$(jq -c '(if .status == "succeeded" then del(.last_succeeded) else .last_succeeded end) // empty' <<<"${previous:-null}")

  if [[ -n ${previous} ]]; then
    echo "Previous deployment (${DEPLOY_PARAM}): ${previous}"
    running_ref=$(jq -r '.ref // empty' <<<"${last_succeeded:-null}")
    if [[ -n ${running_ref} ]] && [[ ${running_ref} != "${DEPLOY_REF}" ]]; then
      echo "WARNING: ${ENV} runs ${running_ref} of ${DEPLOY_REPO}; this deploy replaces it with ${DEPLOY_REF}"
    fi
    if [[ $(jq -r '.status' <<<"${previous}") == "in_progress" ]]; then
      echo "WARNING: the previous deployment has not finished, or was interrupted"
    fi
  fi

  record_deployment "$(build_record "in_progress")"
fi

function on_exit() {
  set +e  # a failure in here must not turn the deploy's exit status into a failure, or skip the summary
  local status="failed" record
  if [[ $1 == 0 ]]; then
    status="succeeded"
  fi
  if ! record=$(build_record "${status}"); then
    echo "WARNING: could not build the deployment record (jq)"
  fi
  if [[ "$IS_PR_ENV_BUILD" != "true" ]]; then
    record_deployment "${record}"
  fi
  write_summary "${record}"
}
trap 'on_exit $?' EXIT
# an interrupted deploy (Ctrl-C, CI timeout) exits through the EXIT trap too
trap 'exit 130' INT
trap 'exit 143' TERM

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

    # for the deploy summary: print the set_stats data, write per-task results (junit), keep a copy of the log;
    # the callbacks of the module's ansible.cfg (e.g. profile_tasks) stay enabled
    summary_env=(ANSIBLE_SHOW_CUSTOM_STATS=true)
    if callbacks=$(ansible-config dump --format json 2>/dev/null \
        | jq -er '.[] | select(.name == "CALLBACKS_ENABLED") | .value | join(",")'); then
      summary_env+=(ANSIBLE_CALLBACKS_ENABLED="${callbacks:+${callbacks},}ansible.builtin.junit"
        JUNIT_OUTPUT_DIR="${DEPLOY_OUTPUT_DIR}/junit")
    else
      echo "WARNING: could not read the enabled Ansible callbacks, so the deploy summary will not list failed tasks"
    fi
    if [[ "$IS_PR_ENV_BUILD" != "true" ]]; then
      playbook_args=(-e env="$ENV" -e project_id="$PROJECT_ID" playbook.yml)
    else
      playbook_args=(-e env="$ENV" -e project_id="$PROJECT_ID" -e is_pr_env_build="$IS_PR_ENV_BUILD" -e pr_number="$PR_NUMBER" playbook.yml)
    fi
    (
      set -o pipefail
      env "${summary_env[@]}" ansible-playbook "${playbook_args[@]}" 2>&1 | tee -a "${DEPLOY_OUTPUT_DIR}/ansible.log"
    )
  fi

  popd
done
