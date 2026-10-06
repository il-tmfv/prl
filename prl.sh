#!/usr/bin/env bash
# Menu: (1) list open PRs in org ChatPush where the current user is author or assignee,
# (2) mark all comments of HIDE_USER on a given PR as outdated.
# List: oldest first; shows draft/ready, CI rollup, approval count vs REQUIRED_APPROVALS (default 1), URL, first 3 body lines.
set -euo pipefail

ORG="${ORG:-ChatPush}"
# Approvals needed to consider a PR ready to proceed.
REQUIRED_APPROVALS="${REQUIRED_APPROVALS:-1}"
# Author whose comments option 2 marks as outdated.
HIDE_USER="${HIDE_USER:-valera-architect[bot]}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing dependency: $1" >&2
    exit 1
  }
}

need gh
need jq

GQL_QUERY='
query($search: String!, $after: String) {
  search(query: $search, type: ISSUE, first: 50, after: $after) {
    pageInfo {
      hasNextPage
      endCursor
    }
    nodes {
      ... on PullRequest {
        title
        url
        number
        createdAt
        isDraft
        body
        reviewDecision
        repository { nameWithOwner }
        latestReviews(first: 50) {
          nodes {
            state
            author { login }
          }
        }
        statusCheckRollup {
          state
          contexts(first: 40) {
            nodes {
              __typename
              ... on CheckRun {
                name
                status
                conclusion
              }
              ... on StatusContext {
                context
                state
              }
            }
          }
        }
      }
    }
  }
}
'

fetch_search() {
  local search="$1"
  local after=""
  local page

  while true; do
    if [[ -n "$after" ]]; then
      page="$(gh api graphql -f query="$GQL_QUERY" -f search="$search" -f after="$after")"
    else
      page="$(gh api graphql -f query="$GQL_QUERY" -f search="$search")"
    fi

    jq -c '.data.search.nodes[] | select(.url != null)' <<<"$page"

    local has_next cursor
    has_next="$(jq -r '.data.search.pageInfo.hasNextPage' <<<"$page")"
    cursor="$(jq -r '.data.search.pageInfo.endCursor // empty' <<<"$page")"
    if [[ "$has_next" != "true" || -z "$cursor" ]]; then
      break
    fi
    after="$cursor"
  done
}

color_enabled=0
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  color_enabled=1
fi

c() {
  local name="$1"
  shift
  if [[ "$color_enabled" -eq 0 ]]; then
    printf '%s' "$*"
    return
  fi
  case "$name" in
    green) printf '\033[32m%s\033[0m' "$*" ;;
    red) printf '\033[31m%s\033[0m' "$*" ;;
    yellow) printf '\033[33m%s\033[0m' "$*" ;;
    cyan) printf '\033[36m%s\033[0m' "$*" ;;
    dim) printf '\033[2m%s\033[0m' "$*" ;;
    bold) printf '\033[1m%s\033[0m' "$*" ;;
    *) printf '%s' "$*" ;;
  esac
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

list_prs() {
  {
    fetch_search "org:${ORG} is:open is:pr author:@me"
    fetch_search "org:${ORG} is:open is:pr assignee:@me"
  } >"$tmp"

  if [[ ! -s "$tmp" ]]; then
    echo "No open PRs in ${ORG} where you are author or assignee."
    return 0
  fi

  formatted="$(
    jq -s '
      unique_by(.url)
      | sort_by(.createdAt)
      | map(
          . as $pr
          | {
              createdAt: (.createdAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | strftime("%Y-%m-%d")),
              repo: .repository.nameWithOwner,
              number: .number,
              title: .title,
              url: .url,
              draft: (if .isDraft then "DRAFT" else "READY" end),
              reviewDecision: (.reviewDecision // "NONE"),
              approvals: (
                (.latestReviews.nodes // [])
                | map(select(.state == "APPROVED" and .author != null))
                | unique_by(.author.login)
                | length
              ),
              ci_state: (.statusCheckRollup.state // "NONE"),
              ci_bad: (
                (.statusCheckRollup.contexts.nodes // [])
                | map(
                    if .__typename == "CheckRun" then
                      {
                        name: .name,
                        bad: ((.status != "COMPLETED") or ((.conclusion // "") != "SUCCESS"))
                      }
                    else
                      {
                        name: .context,
                        bad: ((.state // "") != "SUCCESS")
                      }
                    end
                  )
                | map(select(.bad))
                | map(.name)
              ),
              preview: (
                (.body // "")
                | gsub("\r"; "")
                | split("\n")
                | until(length == 0 or .[0] != ""; .[1:])
                | .[0:3]
              )
            }
        )
    ' "$tmp"
  )"

  count="$(jq 'length' <<<"$formatted")"
  echo "$(c bold "${count} open PR(s)") in ${ORG} (author or assignee), oldest first"
  echo

  jq -c '.[]' <<<"$formatted" | while IFS= read -r row; do
    created="$(jq -r '.createdAt' <<<"$row")"
    draft="$(jq -r '.draft' <<<"$row")"
    ci="$(jq -r '.ci_state' <<<"$row")"
    approvals="$(jq -r '.approvals' <<<"$row")"
    decision="$(jq -r '.reviewDecision' <<<"$row")"
    repo="$(jq -r '.repo' <<<"$row")"
    number="$(jq -r '.number' <<<"$row")"
    title="$(jq -r '.title' <<<"$row")"
    url="$(jq -r '.url' <<<"$row")"
    ci_bad="$(jq -r '.ci_bad | join(", ")' <<<"$row")"

    case "$draft" in
      DRAFT) draft_fmt="$(c yellow DRAFT)" ;;
      *) draft_fmt="$(c green READY)" ;;
    esac

    case "$ci" in
      SUCCESS) ci_fmt="$(c green "CI:${ci}")" ;;
      FAILURE|ERROR) ci_fmt="$(c red "CI:${ci}")" ;;
      PENDING|EXPECTED) ci_fmt="$(c yellow "CI:${ci}")" ;;
      *) ci_fmt="$(c dim "CI:${ci}")" ;;
    esac

    if [[ -n "$ci_bad" ]]; then
      ci_fmt="${ci_fmt} $(c dim "(${ci_bad})")"
    fi

    if (( approvals >= REQUIRED_APPROVALS )); then
      approvals_fmt="$(c green "✅ approvals:${approvals}/${REQUIRED_APPROVALS} [${decision}]")"
    else
      approvals_fmt="$(c yellow "⏳ approvals:${approvals}/${REQUIRED_APPROVALS} [${decision}]")"
    fi

    printf '%s  %s  %s  %s  %s\n' \
      "$(c dim "$created")" \
      "$draft_fmt" \
      "$ci_fmt" \
      "$approvals_fmt" \
      "$(c cyan "${repo}#${number}")"
    printf '  %s\n' "$(c bold "$title")"
    printf '  %s\n' "$(c cyan "$url")"

    preview_n="$(jq '.preview | length' <<<"$row")"
    if [[ "$preview_n" -eq 0 ]]; then
      printf '  %s\n' "$(c dim "(no description)")"
    else
      jq -r '.preview[]' <<<"$row" | while IFS= read -r line; do
        printf '  %s\n' "$(c dim "$line")"
      done
    fi
    echo
  done
}

# Mark all comments (issue, inline review comments, review bodies) of HIDE_USER on a PR as outdated.
hide_comments() {
  local url="$1"
  local owner repo number
  if [[ "$url" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    number="${BASH_REMATCH[3]}"
  else
    echo "Not a PR URL: ${url}" >&2
    return 1
  fi

  local ids
  ids="$(
    {
      gh api --paginate "repos/${owner}/${repo}/issues/${number}/comments"
      gh api --paginate "repos/${owner}/${repo}/pulls/${number}/comments"
      gh api --paginate "repos/${owner}/${repo}/pulls/${number}/reviews"
    } | jq -r --arg user "$HIDE_USER" '.[] | select(.user.login == $user) | .node_id'
  )"

  if [[ -z "$ids" ]]; then
    echo "No comments from ${HIDE_USER} in ${owner}/${repo}#${number}."
    return 0
  fi

  local done_n=0 fail_n=0 id
  while IFS= read -r id; do
    if gh api graphql \
      -f query='mutation($id: ID!) { minimizeComment(input: {subjectId: $id, classifier: OUTDATED}) { minimizedComment { isMinimized } } }' \
      -f id="$id" >/dev/null; then
      done_n=$((done_n + 1))
    else
      fail_n=$((fail_n + 1))
    fi
  done <<<"$ids"

  echo "$(c green "Marked ${done_n} comment(s) as outdated") from ${HIDE_USER} in ${owner}/${repo}#${number}."
  if (( fail_n > 0 )); then
    echo "$(c red "Failed: ${fail_n}")" >&2
    return 1
  fi
}

echo "$(c bold "prl")"
echo "  1) List my open PRs"
echo "  2) Mark ${HIDE_USER} comments on a PR as outdated"
echo
read -r -p "Choice [1-2]: " choice

case "$choice" in
  1) list_prs ;;
  2)
    read -r -p "PR URL: " pr_url
    hide_comments "$pr_url"
    ;;
  *)
    echo "Unknown choice: ${choice}" >&2
    exit 1
    ;;
esac
