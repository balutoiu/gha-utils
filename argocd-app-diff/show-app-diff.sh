#!/usr/bin/env bash
set -e
set -o pipefail

if [[ -z $1 ]]; then
    echo "Usage: $0 <path-to-argo-app-file>"
    exit 1
fi

# Reduce a GitHub repo URL to "owner/repo".
function github_repo_name() {
    echo $1 | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##; s#/$##' | tr '[:upper:]' '[:lower:]'
}

# Sources from the repo under review render at the PR branch, others at their own revision.
SELF_REPO=$(github_repo_name "${GITHUB_REPOSITORY:-$(git remote get-url origin)}")

function git_repo_revision() {
    local repo_url=$1
    local revision=$2
    if [[ "$(github_repo_name $repo_url)" = "$SELF_REPO" ]]; then
        if [[ ! -z $GITHUB_HEAD_REF ]]; then
            revision="$GITHUB_HEAD_REF"
        else
            revision=$(git branch --show-current)
        fi
    fi
    echo $revision
}

ARGO_APP_FILE="$1"
ARGO_APP_NAME=$(cat $ARGO_APP_FILE | yq '.metadata.name')
ARGOCD_APP_DIFF_CMD="argocd app diff --hard-refresh --diff-exit-code 20 $ARGOCD_EXTRA_OPTS $ARGO_APP_NAME"

IS_MULTI_SOURCES_APP=$(cat $ARGO_APP_FILE | yq '.spec | has("sources")')
if [[ "$IS_MULTI_SOURCES_APP" = "true" ]]; then
    SOURCE_POSITION=1
    for SOURCE in $(cat $ARGO_APP_FILE | yq '.spec.sources[] | "\(.repoURL)|\(.targetRevision)"'); do
        REPO_URL=$(echo $SOURCE | cut -d '|' -f 1)
        REVISION=$(echo $SOURCE | cut -d '|' -f 2)
        REVISION=$(git_repo_revision $REPO_URL $REVISION)
        ARGOCD_APP_DIFF_CMD+=" --source-positions $SOURCE_POSITION --revisions $REVISION"
        SOURCE_POSITION=$((SOURCE_POSITION + 1))
    done
else
    SOURCE=$(cat $ARGO_APP_FILE | yq '.spec.source | "\(.repoURL)|\(.targetRevision)"')
    REPO_URL=$(echo $SOURCE | cut -d '|' -f 1)
    REVISION=$(echo $SOURCE | cut -d '|' -f 2)
    REVISION=$(git_repo_revision $REPO_URL $REVISION)
    ARGOCD_APP_DIFF_CMD+=" --revision $REVISION"
fi

eval $ARGOCD_APP_DIFF_CMD
