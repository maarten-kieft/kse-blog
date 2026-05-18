---
layout: default
title: How we keep AI coding assistants and other tools consistent across 85+ repositories
---

# How we keep AI coding assistants and other tools consistent across 85+ repositories

## Overview

AI coding assistants are only as good as the context you give them. If every repository has different instructions — or none at all — every developer gets a different AI experience, and the code it generates drifts from your team's conventions. We solved this, along with a broader consistency problem, by building a pipeline that pushes shared files from one central repository to every project we own automatically.

![Overview](https://www.kieftsoftwareengineering.nl/blog/assets/images/2026-05-18-multi-repo-shared-files.png)

## The problem with multi-repo setups

When you work across dozens of repositories, consistency is a constant battle. Linting configs drift. Renovate rules diverge. That one file everyone agreed on six months ago has quietly become twelve different versions across twelve different repos.

The same problem hits AI tooling hard. Most AI coding assistants (GitHub Copilot, Cursor, Claude) pick up instructions from a file in the repository root — `agents.md`, `.github/copilot-instructions.md`, or similar. Without a shared source of truth, each repo either has no instructions at all, or a stale copy that nobody remembers to update.

## The setup: one repo to rule them all

We maintain a `shared` repository with a `shared/` folder. Anything placed in that folder gets synchronized to every repository in our GitLab group. The pipeline runs on every merge to `main` and uses the GitLab Commits API to write the files directly — no cloning, no SSH keys, no checkout of target repos.

The core of the pipeline is straightforward:

1. Scan all files in `shared/`
2. Fetch all projects in the GitLab group via the API
3. For each project, build a commit payload with all files
4. POST it to `/api/v4/projects/:id/repository/commits`

The resulting pipeline:

```yaml
stages:
  - publish

variables:
  PROJECTS_INCLUDE:
    value: ""
    description: "Filter on project name (for example: MyProject). Leave empty for all projects"


publish-applications:
  stage: publish
  variables:
    GROUP_ID: 2542
  extends: .publish-shared
  only:
    - main

publish-libraries:
  stage: publish
  variables:
    GROUP_ID: 2541
  extends: .publish-shared
  only:
    - main

.publish-shared:
  image: badouralix/curl-jq:latest
  script:
    - |
      SYNC_DIR="shared"
      COMMIT_MSG="$CI_COMMIT_MESSAGE (from Shared) [ci skip]"
      AUTHOR_NAME=$(echo "$CI_COMMIT_AUTHOR" | sed 's/ <.*//')
      AUTHOR_EMAIL=$(echo "$CI_COMMIT_AUTHOR" | sed 's/.*<\(.*\)>/\1/')

      SYNC_FILES_TMP=$(mktemp)
      echo "Scanning files in $SYNC_DIR/..."
      find "./$SYNC_DIR" -type f | sed 's|^\./||' > "$SYNC_FILES_TMP"
      cat "$SYNC_FILES_TMP"

      PROJECTS_TMP=$(mktemp)
      echo "Fetching projects from group $GROUP_ID..."
      curl --silent --header "PRIVATE-TOKEN: $GITLABTOK" \
        "$CI_SERVER_URL/api/v4/groups/$GROUP_ID/projects?per_page=1000" \
        | jq -c '.[]' > "$PROJECTS_TMP"

      while read -r project; do
        PID=$(echo "$project" | jq '.id')
        P_NAME=$(echo "$project" | jq -r '.name')
        DEFAULT_BRANCH=$(echo "$project" | jq -r '.default_branch')

        MATCH=false
        if [ -z "$PROJECTS_INCLUDE" ]; then
          MATCH=true
        else
          for PROJECT_INCLUDE in $PROJECTS_INCLUDE; do
            if [[ "$P_NAME" == *"$PROJECT_INCLUDE"* ]]; then
              MATCH=true
              break
            fi
          done
        fi

        if [ "$MATCH" = false ]; then
          echo "Skipping '$P_NAME'..."
          continue
        fi

        echo "Preparing commit for $P_NAME (ID: $PID)..."
        ACTIONS="[]"

        while read -r FILE; do
          TARGET_FILE="${FILE#$SYNC_DIR/}"
          ENCODED_FILE=$(printf '%s' "$TARGET_FILE" | jq -Rr @uri)

          HTTP_STATUS=$(curl --silent --output /dev/null --write-out "%{http_code}" \
            --header "PRIVATE-TOKEN: $GITLABTOK" \
            "$CI_SERVER_URL/api/v4/projects/$PID/repository/files/$ENCODED_FILE?ref=$DEFAULT_BRANCH")

          ACTION=$([ "$HTTP_STATUS" = "200" ] && echo "update" || echo "create")

          if grep -q 'SHARED:BEGIN' "./$FILE" && [ "$HTTP_STATUS" = "200" ]; then
            echo "  [$ACTION] $TARGET_FILE (merge mode)"
            EXISTING=$(curl --silent \
              --header "PRIVATE-TOKEN: $GITLABTOK" \
              "$CI_SERVER_URL/api/v4/projects/$PID/repository/files/$ENCODED_FILE/raw?ref=$DEFAULT_BRANCH")

            NEW_BLOCK=$(sed -n '/SHARED:BEGIN/,/SHARED:END/p' "./$FILE")

            if echo "$EXISTING" | grep -q 'SHARED:BEGIN'; then
              BEFORE=$(printf '%s' "$EXISTING" | sed '/SHARED:BEGIN/,$d')
              AFTER=$(printf '%s' "$EXISTING" | sed '1,/SHARED:END/d')
              CONTENT=$(printf '%s%s\n%s' "$BEFORE" "$NEW_BLOCK" "$AFTER" | jq -Rs .)
            else
              CONTENT=$(printf '%s\n%s' "$NEW_BLOCK" "$EXISTING" | jq -Rs .)
            fi
          else
            echo "  [$ACTION] $TARGET_FILE"
            CONTENT=$(jq -Rs . < "./$FILE")
          fi

          ACTIONS=$(echo "$ACTIONS" | jq \
            --arg action "$ACTION" \
            --arg path "$TARGET_FILE" \
            --argjson content "$CONTENT" \
            '. += [{"action": $action, "file_path": $path, "content": $content}]')
        done < "$SYNC_FILES_TMP"

        echo "Committing $(echo "$ACTIONS" | jq length) files to $P_NAME..."
        curl --silent --request POST \
          --header "PRIVATE-TOKEN: $GITLABTOK" \
          --header "Content-Type: application/json" \
          --data "$(jq -n \
            --arg branch "$DEFAULT_BRANCH" \
            --arg msg "$COMMIT_MSG" \
            --arg author_name "$AUTHOR_NAME" \
            --arg author_email "$AUTHOR_EMAIL" \
            --argjson actions "$ACTIONS" \
            '{
              branch: $branch,
              commit_message: $msg,
              author_email: $author_email,
              author_name: $author_name,
              actions: $actions
            }')" \
          "$CI_SERVER_URL/api/v4/projects/$PID/repository/commits" \
          | jq '{id: .id, title: .title}'
      done < "$PROJECTS_TMP"

      rm -f "$SYNC_FILES_TMP" "$PROJECTS_TMP"
```

One commit, one API call per project, zero manual work. When you update `renovate.json` in the shared repo, every project gets it within minutes.


## What we actually share

The obvious candidates are tooling configs: `renovate.json`, `.editorconfig`, linting rules. But the most impactful thing we share is a Markdown file with our **team conventions for AI tools**.

We maintain one canonical `agents.md` that describes:

- How we write unit tests (xUnit, Shouldly, NSubstitute — with the exact class/method naming pattern)
- Our integration patterns (event processors, event publishers, syncers)
- Our tech stack and deployment context
- Things the AI should always do before starting work (like activating the MCP server for the project)

Every developer in every repo gets the same AI behaviour out of the box. New projects start with the right conventions on day one. When we update the guidance — say, we adopt a new testing library — one commit in the shared repo propagates it everywhere.

## Letting projects extend without being overwritten

Full overwrite works well for most files. But `agents.md` is one where a project might legitimately want to add something extra — a project-specific pattern, a domain term the AI should know about.

We handle this with guard markers. If the shared file wraps its content in `SHARED:BEGIN` / `SHARED:END` comments, the pipeline fetches the existing file from the target, replaces only the marked section, and leaves everything else untouched:

```markdown
<!-- SHARED:BEGIN -->
# Team instructions
...shared conventions managed from the shared repo...
<!-- SHARED:END -->

## Project-specific context
This section is owned by the project and never touched by the sync.
```

The detection is automatic: if the shared file contains a `SHARED:BEGIN` marker, merge mode is used. Files without markers are fully overwritten — no breaking change, no extra configuration.

```sh
if grep -q 'SHARED:BEGIN' "./$FILE" && [ "$HTTP_STATUS" = "200" ]; then
  EXISTING=$(curl --silent ... "$ENCODED_FILE/raw?ref=$DEFAULT_BRANCH")
  NEW_BLOCK=$(sed -n '/SHARED:BEGIN/,/SHARED:END/p' "./$FILE")
  BEFORE=$(printf '%s' "$EXISTING" | sed '/SHARED:BEGIN/,$d')
  AFTER=$(printf '%s' "$EXISTING" | sed '1,/SHARED:END/d')
  CONTENT=$(printf '%s%s\n%s' "$BEFORE" "$NEW_BLOCK" "$AFTER" | jq -Rs .)
else
  CONTENT=$(jq -Rs . < "./$FILE")
fi
```

---

## The result

Every repository in our group stays in sync with zero manual overhead. Tooling configs are consistent. The AI tools every developer uses are guided by the same up-to-date team conventions. And when something changes, one PR in the shared repo is all it takes.
