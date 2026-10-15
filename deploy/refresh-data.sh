#!/bin/sh
set -eu

: "${GITLAB_URL:?GITLAB_URL is required}"
: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"
: "${SITE_ROOT:?SITE_ROOT is required}"

project_path=${GITLAB_PROJECT_PATH:-wei.wang%2Fgpuworks}
ref=${GITLAB_REF:-master}
api_base="${GITLAB_URL%/}/api/v4/projects/${project_path}"
data_dir="$SITE_ROOT/data"
downloads_dir="$SITE_ROOT/downloads"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/gpuworks-site-refresh.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT INT TERM
curl_config="$work_dir/curl.conf"
umask 077
printf '%s\n' \
  'fail' \
  'silent' \
  'show-error' \
  'retry = 3' \
  'retry-delay = 2' \
  'connect-timeout = 10' \
  'max-time = 45' \
  "header = \"PRIVATE-TOKEN: ${GITLAB_TOKEN}\"" > "$curl_config"
umask 022

mkdir -p "$data_dir" "$downloads_dir"

api_get() {
  curl --config "$curl_config" "$1"
}

encoded_ref=$(printf '%s' "$ref" | jq -sRr @uri)
api_get "$api_base/pipelines?ref=$encoded_ref&per_page=20&order_by=id&sort=desc" > "$work_dir/pipeline-list.json"

pipeline_count=0
for pipeline_id in $(jq -r '.[].id' "$work_dir/pipeline-list.json"); do
  (
    api_get "$api_base/pipelines/$pipeline_id" > "$work_dir/pipeline-$pipeline_id.json"
    api_get "$api_base/pipelines/$pipeline_id/jobs?per_page=100" > "$work_dir/jobs-$pipeline_id.json"
    jq -n \
      --slurpfile pipeline "$work_dir/pipeline-$pipeline_id.json" \
      --slurpfile jobs "$work_dir/jobs-$pipeline_id.json" \
      '{
        id: $pipeline[0].id,
        status: $pipeline[0].status,
        ref: $pipeline[0].ref,
        sha: $pipeline[0].sha,
        web_url: $pipeline[0].web_url,
        source: $pipeline[0].source,
        created_at: $pipeline[0].created_at,
        updated_at: $pipeline[0].updated_at,
        started_at: $pipeline[0].started_at,
        finished_at: $pipeline[0].finished_at,
        duration: $pipeline[0].duration,
        jobs: [
          $jobs[0][] | {
            id, name, stage, status, allow_failure, web_url,
            created_at, started_at, finished_at, duration, queued_duration
          }
        ]
      }' > "$work_dir/normalized-$pipeline_id.json"
  ) &
  pipeline_count=$((pipeline_count + 1))
done
wait

if [ "$pipeline_count" -eq 0 ]; then
  echo "GitLab returned no pipelines for $ref" >&2
  exit 1
fi

jq -s 'sort_by(.id) | reverse' "$work_dir"/normalized-*.json > "$work_dir/pipelines.json"
generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n \
  --arg generated_at "$generated_at" \
  --arg ref "$ref" \
  --arg project_path "$project_path" \
  --slurpfile pipelines "$work_dir/pipelines.json" \
  '{
    generated_at: $generated_at,
    ref: $ref,
    project: $project_path,
    methodology: {
      pipeline_window: ($pipelines[0] | length),
      pass_rate_numerator: "success",
      pass_rate_denominator: ["success", "failed"],
      excluded_states: ["running", "pending", "waiting_for_resource", "canceled", "skipped", "manual"],
      note: "The site also exposes the effective sample size, non-run count, latest effective result, latest successful completion time, and that successful job duration."
    },
    pipelines: $pipelines[0]
  }' > "$work_dir/ci.json"
jq empty "$work_dir/ci.json"
install -m 0644 "$work_dir/ci.json" "$data_dir/ci.json.new"
mv "$data_dir/ci.json.new" "$data_dir/ci.json"

docs_pair=$(jq -r '
  [
    .[] as $pipeline
    | select($pipeline.status == "success" and $pipeline.ref == $ref)
    | ($pipeline.jobs[] | select(.name == "docs-build" and .status == "success")) as $docs
    | [$pipeline.id, $pipeline.sha, $docs.id]
    | @tsv
  ][0] // empty
' --arg ref "$ref" "$work_dir/pipelines.json")

if [ -n "$docs_pair" ]; then
  docs_pipeline=$(printf '%s\n' "$docs_pair" | cut -f1)
  docs_commit=$(printf '%s\n' "$docs_pair" | cut -f2)
  docs_job=$(printf '%s\n' "$docs_pair" | cut -f3)
  current_docs_commit=""
  if [ -f "$SITE_ROOT/docs/docs-manifest.json" ]; then
    current_docs_commit=$(jq -r '.commit // empty' "$SITE_ROOT/docs/docs-manifest.json" 2>/dev/null || true)
  fi

  if [ "$docs_commit" != "$current_docs_commit" ]; then
    curl --config "$curl_config" \
      "$api_base/jobs/$docs_job/artifacts" > "$work_dir/docs-artifacts.zip"
    if unzip -Z1 "$work_dir/docs-artifacts.zip" | grep -Eq '(^/|(^|/)\.\.?(/|$))'; then
      echo "unsafe path in docs artifact from job $docs_job" >&2
      exit 2
    fi
    mkdir -p "$work_dir/docs-artifacts"
    unzip -q "$work_dir/docs-artifacts.zip" -d "$work_dir/docs-artifacts"
    docs_public="$work_dir/docs-artifacts/docs-site/public"
    test -s "$docs_public/index.html"
    test -s "$docs_public/tutorials/getting-started/index.html"
    test -s "$docs_public/docs-manifest.json"
    test -n "$(find "$docs_public" -maxdepth 1 -name 'offline-search-index.*.json' -print -quit)"
    jq -e --arg commit "$docs_commit" \
      '.project == "gpuworks" and .commit == $commit and .generator == "hugo-oink"' \
      "$docs_public/docs-manifest.json" >/dev/null

    docs_stage="$work_dir/docs.next"
    mkdir -p "$docs_stage"
    cp -a "$docs_public"/. "$docs_stage"/
    docs_current="$SITE_ROOT/docs"
    docs_previous="$SITE_ROOT/docs.previous"
    docs_old="$work_dir/docs.previous"
    if [ -e "$docs_current" ]; then
      mv "$docs_current" "$docs_old"
    fi
    if ! mv "$docs_stage" "$docs_current"; then
      if [ -e "$docs_old" ]; then mv "$docs_old" "$docs_current"; fi
      echo "failed to activate docs artifact from job $docs_job" >&2
      exit 1
    fi
    rm -rf "$docs_previous"
    if [ -e "$docs_old" ]; then mv "$docs_old" "$docs_previous"; fi
    echo "published docs pipeline $docs_pipeline job $docs_job commit $docs_commit"
  fi
else
  echo "no successful docs-build found for $ref; keeping current docs" >&2
fi

# The release archives of a pipeline come from several jobs: one per archive
# since gpuworks MR !410 (each job's artifacts must stay under GitLab's size
# limit), one per OS before it. The newest pipeline in which every job of
# either set succeeded is the one to publish.
release_jobs=$(jq -r '
  [
    .[] as $pipeline
    | ([$pipeline.jobs[] | select(.status == "success")] | map({key: .name, value: .id}) | from_entries) as $ok
    | ([
        ["release-build-linux-amd64", "release-build-linux-arm64", "release-build-macos-amd64", "release-build-macos-arm64"],
        ["release-build", "release-build-macos"]
      ][] | select(all(.[]; $ok[.] != null))) as $names
    | [$pipeline.id, $pipeline.sha, ($names | map($ok[.]) | join(" "))]
    | @tsv
  ][0] // empty
' "$work_dir/pipelines.json")

if [ -n "$release_jobs" ]; then
  release_pipeline=$(printf '%s\n' "$release_jobs" | cut -f1)
  release_commit=$(printf '%s\n' "$release_jobs" | cut -f2)
  job_list=$(printf '%s\n' "$release_jobs" | cut -f3)
  current_jobs=""
  if [ -f "$data_dir/release.json" ]; then
    current_jobs=$(jq -r '(.job_list // empty) | join(" ")' "$data_dir/release.json" 2>/dev/null || true)
  fi

  if [ "$job_list" != "$current_jobs" ]; then
    mkdir -p "$work_dir/combined"
    : > "$work_dir/combined/SHA256SUMS"
    for release_job in $job_list; do
      job_dir="$work_dir/artifacts-$release_job"
      api_get "$api_base/jobs/$release_job" > "$work_dir/release-job-$release_job.json"
      curl --config "$curl_config" \
        "$api_base/jobs/$release_job/artifacts" > "$job_dir.zip"
      if unzip -Z1 "$job_dir.zip" | grep -Eq '(^/|(^|/)\.\.?(/|$))'; then
        echo "unsafe path in release artifact from job $release_job" >&2
        exit 2
      fi
      mkdir -p "$job_dir"
      unzip -q "$job_dir.zip" -d "$job_dir"
      test -f "$job_dir/dist/release.json"
      test -f "$job_dir/dist/SHA256SUMS"
      jq -e '.files | length >= 1' "$job_dir/dist/release.json" >/dev/null
      # Every job built the same commit, which is the pipeline's.
      job_commit=$(jq -r '.commit' "$job_dir/dist/release.json")
      if [ "$job_commit" != "$release_commit" ]; then
        echo "release artifact of job $release_job is from $job_commit, not $release_commit" >&2
        exit 2
      fi
      cat "$job_dir/dist/SHA256SUMS" >> "$work_dir/combined/SHA256SUMS"
      jq -r '.files[].name' "$job_dir/dist/release.json" | while IFS= read -r filename; do
        case "$filename" in
          ""|*/*|*".."*) echo "unsafe artifact filename: $filename" >&2; exit 2 ;;
        esac
        cp "$job_dir/dist/$filename" "$work_dir/combined/$filename"
      done
    done

    # One manifest: the first job's, with every job's files, all of one
    # release id and no archive twice.
    set --
    for release_job in $job_list; do
      set -- "$@" "$work_dir/artifacts-$release_job/dist/release.json"
    done
    jq -s '
      if (map(.release_id) | unique | length) != 1 then error("release ids differ across jobs") else . end
      | .[0] + {files: (map(.files) | add)}
      | if (.files | map(.name) | unique | length) != (.files | length) then error("an archive appears twice") else . end
    ' "$@" > "$work_dir/combined/release.json"
    (cd "$work_dir/combined" && sha256sum -c --quiet SHA256SUMS)

    jq -r '.files[].name' "$work_dir/combined/release.json" | while IFS= read -r filename; do
      install -m 0644 "$work_dir/combined/$filename" "$downloads_dir/$filename"
    done
    install -m 0644 "$work_dir/combined/SHA256SUMS" "$downloads_dir/SHA256SUMS"

    first_job=${job_list%% *}
    first_job_url=$(jq -r '.web_url' "$work_dir/release-job-$first_job.json")
    jq \
      --argjson pipeline_id "$release_pipeline" \
      --argjson first_job "$first_job" \
      --arg first_job_url "$first_job_url" \
      --arg job_list "$job_list" \
      --arg synced_at "$generated_at" \
      '. + {
        pipeline_id: $pipeline_id,
        job_id: $first_job,
        job_url: $first_job_url,
        job_list: ($job_list | split(" ") | map(tonumber)),
        synced_at: $synced_at
      }' "$work_dir/combined/release.json" > "$work_dir/release-published.json"
    install -m 0644 "$work_dir/release-published.json" "$data_dir/release.json.new"
    mv "$data_dir/release.json.new" "$data_dir/release.json"
    echo "published release pipeline $release_pipeline jobs $job_list"
  fi
fi

echo "refreshed $pipeline_count pipelines at $generated_at"
