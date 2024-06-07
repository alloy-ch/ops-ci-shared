#!/bin/bash

set -e

# Example of sources_metadata.yml:
# inputs:
#   - filepath: ./reporting/models/sources/data_sharing_sources.yml
#     env: prod
#   - filepath: ./reporting/models/sources/audience_sources.yml
#     env: prod
#   - filepath: ./reporting/models/sources/contextual_gam_keys_sources.yml
#     env: prod
#   - filepath: ./reporting/models/sources/advertising_data_sources.yml
#     env: land

sources_files=$(find . -name sources_metadata.yml)
for source_file in $sources_files; do
    input_sources=( $(yq e -o=j -I=0 '.inputs[]' "$source_file" ) )
    pushd "$(dirname "$source_file")"
    for source in "${input_sources[@]}"; do
        local_path=$(echo "$source" | yq eval '.filepath')
        filename=$(basename "$local_path")
        env_tag=$(echo "$source" | jq -r '.env')
        s3_path="s3://$env_tag-alloy-common-shared-sources/sources/$filename"
        aws s3 --quiet cp "$s3_path" "$local_path"
    done
    popd
done
git add .
git diff --staged --quiet || (printf "Sources have changed run \n\n\t./ops-ci-shared/scripts/ci-pull-sources.sh\n\nin order to update them and commit the changes.\n" && exit 1)
