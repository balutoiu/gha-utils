#!/usr/bin/env bash

if [[ -z $1 ]]; then
    echo "Usage: $0 <PR_NUMBER>"
    exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

function argocd_app_diff_markdown() {
    local DIFF_FILE="$1"
    local SUMMARY="$2"
    local FENCE_LANG="$3"
    echo ""
    echo "<details>"
    echo "<summary>${SUMMARY}</summary>"
    echo ""
    echo "\`\`\`${FENCE_LANG}"
    cat $DIFF_FILE 2>&1
    echo ""
    echo '```'
    echo ""
    echo "</details>"
}

function get_modified_argo_app_files() {
    local PR_NUMBER="$1"
    # This extracts lines in the format "<CLUSTER_NAME>/<APP_NAME>" from the files modified in the pull request.
    gh pr diff --name-only $PR_NUMBER | grep -E "^argo-cd/apps/|^argo-cd/helm_values/|^argo-cd/extras/" | cut -d '/' -f3- | cut -d '/' -f1,2 | cut -d '.' -f1 | sort | uniq | while read line; do
        CLUSTER_NAME="${line%%/*}"
        if [[ -n "$ARGOCD_APP_DIFF_CLUSTERS" && " $ARGOCD_APP_DIFF_CLUSTERS " != *" $CLUSTER_NAME "* ]]; then
            continue
        fi
        APP_FILE="argo-cd/apps/${line}.yaml" && [[ -f $APP_FILE ]] && echo $APP_FILE
    done
}

export KUBECTL_EXTERNAL_DIFF="diff -u"

PR_NUMBER="$1"
DIFF_COMMENT_FILE="/tmp/gh-diff-comment.md"
DIFF_DIR="/tmp/argo-diffs"

FAILED_APP_FILES=()

trap 'rm -rf $DIFF_DIR $DIFF_COMMENT_FILE' EXIT

APP_FILES=$(get_modified_argo_app_files $PR_NUMBER)
if [[ -z "$APP_FILES" ]]; then
    echo "No changes to Argo CD application files were found in this pull request."
    exit 0
fi

echo "⏳ Generating Argo CD app diffs for:"
echo $APP_FILES | tr ' ' '\n' | sed 's/^/ - /'
echo ""

for APP_FILE in $APP_FILES; do
    echo "🚀 Processing Argo CD app file: $APP_FILE"
    rm -rf $DIFF_DIR
    mkdir -p $DIFF_DIR
    CLUSTER_NAME="$(echo $APP_FILE | cut -d '/' -f 3)"
    export ARGOCD_EXTRA_OPTS="--argocd-context $CLUSTER_NAME"
    #
    # Get Argo CD app diff output.
    #
    # Exit code 20 means a diff was found, anything else non-zero is an error.
    #
    ${DIR}/show-app-diff.sh $APP_FILE > $DIFF_DIR/argo-app.diff 2>&1 && RC=0 || RC=$?
    if [[ $RC -ne 0 && $RC -ne 20 ]]; then
        echo "::error file=${APP_FILE}::Argo CD app diff failed (exit code ${RC})"
        cat $DIFF_DIR/argo-app.diff
        FAILED_APP_FILES+=("$APP_FILE")
        TITLE="Argo CD App Diff Failed"
        SUMMARY=":x: Show Error"
        FENCE_LANG="text"
    else
        TITLE="Argo CD App Diff"
        SUMMARY=":open_file_folder: Show Output"
        FENCE_LANG="diff"
    fi
    #
    # Handle large diffs by splitting into parts.
    #
    if [[ $(wc -c < $DIFF_DIR/argo-app.diff) -gt 65000 ]]; then
        split -b 65000 --additional-suffix=.diff $DIFF_DIR/argo-app.diff $DIFF_DIR/argo-app-diff-part-
        rm $DIFF_DIR/argo-app.diff
    fi
    #
    # Build the markdown comment(s) for the Argo CD app diff output, and post to the PR.
    #
    TOTAL_PARTS=$(ls $DIFF_DIR/*.diff | wc -l | tr -d ' ')
    PART_COUNT=1
    for PART_FILE in $DIFF_DIR/*.diff; do
        echo "## ${TITLE}" > $DIFF_COMMENT_FILE
        echo "### (${PART_COUNT}/${TOTAL_PARTS}) \`${APP_FILE}\`" >> $DIFF_COMMENT_FILE
        argocd_app_diff_markdown $PART_FILE "$SUMMARY" $FENCE_LANG >> $DIFF_COMMENT_FILE
        gh pr comment $PR_NUMBER -F $DIFF_COMMENT_FILE
        PART_COUNT=$(($PART_COUNT + 1))
    done
done

if [[ ${#FAILED_APP_FILES[@]} -gt 0 ]]; then
    echo ""
    echo "❌ Argo CD app diff failed for:"
    printf ' - %s\n' "${FAILED_APP_FILES[@]}"
    exit 1
fi
