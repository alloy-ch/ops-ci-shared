#!/bin/bash


# Example of sources_metadata.yml:
# outputs:
#   - ./assets/data_sharing_sources.yml

set -ex

sources_files=$(find . -name sources_metadata.yml)
for source_file in $sources_files; do
    pushd "$(dirname "$source_file")"
    for local_path in $(yq eval '.outputs[]' "$(basename "$source_file")"); do
        filename=$(basename "$local_path")
        s3_path="s3://$ENV-alloy-common-shared-sources/sources/$filename"
        aws s3 cp "$local_path" "$s3_path"
    done
    popd
done
