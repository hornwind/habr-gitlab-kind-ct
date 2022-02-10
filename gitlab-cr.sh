#!/usr/bin/env bash

# Copyright The Helm Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

needy_tools=("jq" "yq" "helm")

show_help() {
cat << EOF
Usage: $(basename "$0") <options>
    -h, --help               Display help
    -d, --charts-dir         The charts directory (default: charts)
    -u, --charts-repo-url    The Gitlab helm package registry URL (default: "<CI_API_V4_URL>/projects/<CI_PROJECT_ID>/packages/helm/stable")
    -r, --repo               The repo name
EOF
}

main() {
    local charts_dir=charts
    local repo=
    local charts_repo_url=

    parse_command_line "$@"

    for tool in "${needy_tools[@]}"; do
        assert_tools "$tool"
    done

    local repo_root
    repo_root=$(git rev-parse --show-toplevel)
    pushd "$repo_root" > /dev/null

    echo 'Looking up latest tag...'
    local latest_tag
    latest_tag=$(lookup_latest_tag)

    echo "Discovering changed charts since '$latest_tag'..."
    local changed_charts=()
    readarray -t changed_charts <<< "$(lookup_changed_charts "$latest_tag")"

    if [[ -n "${changed_charts[*]}" ]]; then

        rm -rf .cr-release-packages
        mkdir -p .cr-release-packages

        rm -rf .cr-index
        mkdir -p .cr-index

        for chart in "${changed_charts[@]}"; do
            if [[ -d "$chart" ]]; then
                package_chart "$chart"
            else
                echo "Chart '$chart' no longer exists in repo. Skipping it..."
            fi
        done

        release_charts "$repo"
    else
        echo "Nothing to do. No chart changes detected."
    fi

    popd > /dev/null
}

parse_command_line() {
    while :; do
        case "${1:-}" in
            -h|--help)
                show_help
                exit
                ;;
            -d|--charts-dir)
                if [[ -n "${2:-}" ]]; then
                    charts_dir="$2"
                    shift
                else
                    echo "ERROR: '-d|--charts-dir' cannot be empty." >&2
                    show_help
                    exit 1
                fi
                ;;
            -u|--charts-repo-url)
                if [[ -n "${2:-}" ]]; then
                    charts_repo_url="$2"
                    shift
                else
                    echo "ERROR: '-u|--charts-repo-url' cannot be empty." >&2
                    show_help
                    exit 1
                fi
                ;;
            -r|--repo)
                if [[ -n "${2:-}" ]]; then
                    repo="$2"
                    shift
                else
                    echo "ERROR: '--repo' cannot be empty." >&2
                    show_help
                    exit 1
                fi
                ;;
            *)
                break
                ;;
        esac

        shift
    done

    if [[ -z "$repo" ]]; then
        echo "ERROR: '-r|--repo' is required." >&2
        show_help
        exit 1
    fi

    if [[ -z "$charts_repo_url" ]]; then
        charts_repo_url="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages/helm/stable"
    fi
}

lookup_latest_tag() {
    git fetch --tags > /dev/null 2>&1

    if ! git describe --tags --abbrev=0 2> /dev/null; then
        git rev-list --max-parents=0 --first-parent HEAD
    fi
}

filter_charts() {
    while read -r chart; do
        [[ ! -d "$chart" ]] && continue
        local file="$chart/Chart.yaml"
        if [[ -f "$file" ]]; then
            echo "$chart"
        else
            echo "WARNING: $file is missing, assuming that '$chart' is not a Helm chart. Skipping." 1>&2
        fi
    done
}

lookup_changed_charts() {
    local commit="$1"

    local changed_files
    changed_files=$(git diff --find-renames --name-only "$commit" -- "$charts_dir")

    local depth=$(( $(tr "/" "\n" <<< "$charts_dir" | sed '/^\(\.\)*$/d' | wc -l) + 1 ))
    local fields="1-${depth}"

    cut -d '/' -f "$fields" <<< "$changed_files" | uniq | filter_charts
}

lookup_chart_in_repo_by_version() {
    local chart="$1"
    local chart_version
    chart_version="$(yq r "${chart}/Chart.yaml" 'version')"
    local chart_name
    chart_name="$(yq r "${chart}/Chart.yaml" 'name')"

    helm search repo "${repo}/${chart_name}" --version "$chart_version" -o json | jq -r '.[].version'
}

package_chart() {
    local chart="$1"
    local chart_version_in_repo
    chart_version_in_repo="$(lookup_chart_in_repo_by_version "$chart")"
    local args=("$chart" --destination .cr-release-packages)

    if [[ -z "$chart_version_in_repo" ]]; then
        echo "Packaging chart '$chart'..."
        helm package "${args[@]}"
    else
        echo "$chart with version $chart_version_in_repo already exist ​in repo. Skipping..."
    fi
}

release_charts() {
    local repo="$1"

    echo 'Releasing charts...'
    for f in .cr-release-packages/*.tgz
    do
        [ -e "$f" ] || break
        helm cm-push "$f" "$repo"
    done
}

assert_tools() {
    local tool="$1"

    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: ${tool} is not installed." >&2
        exit 1
        }
}

main "$@"
