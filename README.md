# ops-ci-shared

**Current version: v2.2.1**

This repository hosts the CI/CD shell scripts for projects to be deployed into AWS.

This repo is designed to be included into other repo as a git submodule. To include it:
```shell-script
git submodule add -b main https://github.com/alloy-ch/ops-ci-shared.git
```

NOTE: it is important to add submodule using `https` instead of `git` protocol, because the AWS CodeBuild agent does not have an SSH key
to access Github.
