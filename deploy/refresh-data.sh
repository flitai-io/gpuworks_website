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

release_job=$(jq -r '
  [.[] | .jobs[] | select(.name == "release-build" and .status == "success")][0].id // empty
' "$work_dir/pipelines.json")

if [ -n "$release_job" ]; then
  current_job=""
  if [ -f "$data_dir/release.json" ]; then
    current_job=$(jq -r '.job_id // empty' "$data_dir/release.json" 2>/dev/null || true)
  fi
  if [ "$release_job" != "$current_job" ]; then
    api_get "$api_base/jobs/$release_job" > "$work_dir/release-job.json"
    curl --config "$curl_config" \
      "$api_base/jobs/$release_job/artifacts" > "$work_dir/artifacts.zip"
    mkdir -p "$work_dir/artifacts"
    unzip -q "$work_dir/artifacts.zip" -d "$work_dir/artifacts"
    release_source="$work_dir/artifacts/dist/release.json"
    test -f "$release_source"
    test -f "$work_dir/artifacts/dist/SHA256SUMS"
    jq empty "$release_source"

    jq -r '.files[].name' "$release_source" | while IFS= read -r filename; do
      case "$filename" in
        ""|*/*|*".."*) echo "unsafe artifact filename: $filename" >&2; exit 2 ;;
      esac
      test -f "$work_dir/artifacts/dist/$filename"
      install -m 0644 "$work_dir/artifacts/dist/$filename" "$downloads_dir/$filename"
    done
    install -m 0644 "$work_dir/artifacts/dist/SHA256SUMS" "$downloads_dir/SHA256SUMS"

    job_url=$(jq -r '.web_url' "$work_dir/release-job.json")
    jq \
      --argjson job_id "$release_job" \
      --arg job_url "$job_url" \
      --arg synced_at "$generated_at" \
      '. + {job_id: $job_id, job_url: $job_url, synced_at: $synced_at}' \
      "$release_source" > "$work_dir/release-published.json"
    install -m 0644 "$work_dir/release-published.json" "$data_dir/release.json.new"
    mv "$data_dir/release.json.new" "$data_dir/release.json"
    echo "published release-build job $release_job"
  fi
fi

echo "refreshed $pipeline_count pipelines at $generated_at"
