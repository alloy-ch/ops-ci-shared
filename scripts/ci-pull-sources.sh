#!/bin/bash

set -e

# Example of sources_metadata.yml:
# inputs:
#   - path: reporting/models/sources/data_sharing_sources.yml
#     source:
#       repo: git@github.com:alloy-ch/rcplus-alloy-data-sharing.git
#       rev: v3.3.0
#       path: app/dbt/reporting/models/sources/data_sharing_sources.yml
#   - path: reporting/models/sources/audience_sources.yml
#     source:
#       repo: git@github.com:alloy-ch/rcplus-alloy-audience-segments
#       path: app/batch-processor/assets/audience_sources.yml
#       rev: v2.1.0
#   - path: reporting/models/sources/contextual_gam_keys_sources.yml
#     source:
#       repo: git@github.com:alloy-ch/rcplus-alloy-contextual-data
#       path: app/gam-key-values/assets/contextual_gam_keys_sources.yml
#       rev: v2.2.0
#   - path: reporting/models/sources/advertising_data_sources.yml
#     source:
#       repo: git@github.com:alloy-ch/rcplus-alloy-advertising-data.git
#       path: app/advertising/assets/advertising_data_sources.yml
#       rev: v1.1.0


sources_files=$(find . -name sources_metadata.yml)
for source_file in $sources_files; do
    input_sources=( $(yq e -o=j -I=0 '.inputs[]' "$source_file" ) )
    pushd "$(dirname "$source_file")" > /dev/null
    # clone the repo into a temporary directory
    for source in "${input_sources[@]}"; do
        repo=$(echo "$source" | jq -r '.source.repo')
        rev=$(echo "$source" | jq -r '.source.rev')
        path=$(echo "$source" | jq -r '.source.path')
        destination_path=$(echo "$source" | jq -r '.path')
        git clone -c advice.detachedHead=false --quiet --depth 1 --branch "$rev" "$repo" /tmp/repo
        cp -r /tmp/repo/"$path" "$destination_path"
        rm -rf /tmp/repo
        git add "$destination_path" || true
    done
    popd > /dev/null
done
git diff --staged --quiet || (printf "Sources have changed run \n\n\t./ops-ci-shared/scripts/ci-pull-sources.sh\n\nin order to update them and commit the changes.\n" && exit 1)
