# ops-ci-shared

Current version: **v2.9.0**

This repository hosts the CI/CD shell scripts for projects to be deployed into AWS.

This repo was designed to be included into other repo as a git submodule.
After the rollout of `alloy-ch/ops-ci-basics`, the submodule approach was abandoned in favor of GitHub Actions.

## `scripts/ci-deploy.sh`

Deploys the modules in `INFRASTRUCTURE_FOLDERS` (default `infrastructure`) with Ansible, or with CDK for a module with a `package.json` and a `package-lock.json`.

- **Deploy flag:** it deploys only when `/tmp/is_deploy_flag` contains `1`, otherwise it prints why and exits 0. `ci-init.sh` sets the flag in CI. For a local deploy, run `echo 1 > /tmp/is_deploy_flag`.
- **Partial deploys:** Ansible reads `ANSIBLE_RUN_TAGS` and `ANSIBLE_SKIP_TAGS` from the environment, so a tagged playbook can be deployed in part, e.g. `ANSIBLE_RUN_TAGS=api ./ops-ci-shared/scripts/ci-deploy.sh`. The script prints the selection before it starts.
- **Preflight:** before deploying, it checks that Docker and `docker buildx` respond if a module builds images (`build_push_docker_image`). With a tag selection, a problem is only a warning, because the selected tasks may build no image. Then it runs `<module>/preflight.sh`, from the module folder, if the module has an executable one. Use that hook for checks only the repo knows, such as whether its database is reachable. A failing hook stops the deploy before anything is built. All hooks run before the first module deploys, so a hook must not depend on what another module of the same repo creates.
- **Deployment record:** it writes the deployed ref, commit, who, where (`laptop` or the CodeBuild build), the tag selection and the status (`in_progress`, `succeeded`, `failed`) to the SSM parameter `/ops-ci/deployments/<repo>`. While a deployment is running or after it failed, `last_succeeded` keeps the last deployment that succeeded. A failed deployment may still have changed part of the environment. Before deploying, it prints the previous record and warns when it replaces a different ref or when the previous deployment did not finish. PR environments are not recorded. Check what an environment runs with `aws ssm get-parameter --name /ops-ci/deployments/<repo> --query Parameter.Value --output text`.
