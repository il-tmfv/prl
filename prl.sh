#!/usr/bin/env bash
# List open PRs in org ChatPush where the current user is author or assignee.
# Oldest first. Shows draft/ready, CI rollup, approval count vs REQUIRED_APPROVALS (default 1), URL, first 3 body lines.
set -euo pipefail

ORG="${ORG:-ChatPush}"
# Approvals needed to consider a PR ready to proceed.
REQUIRED_APPROVALS="${REQUIRED_APPROVALS:-1}"

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

{
  fetch_search "org:${ORG} is:open is:pr author:@me"
  fetch_search "org:${ORG} is:open is:pr assignee:@me"
} >"$tmp"

if [[ ! -s "$tmp" ]]; then
  echo "No open PRs in ${ORG} where you are author or assignee."
  exit 0
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
