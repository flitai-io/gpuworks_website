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

release_pair=$(jq -r '
  [
    .[] as $pipeline
    | ([$pipeline.jobs[] | select(.name == "release-build" and .status == "success")][0] // null) as $linux
    | ([$pipeline.jobs[] | select(.name == "release-build-macos" and .status == "success")][0] // null) as $macos
    | select($linux != null and $macos != null)
    | [$pipeline.id, $pipeline.sha, $linux.id, $macos.id]
    | @tsv
  ][0] // empty
' "$work_dir/pipelines.json")

if [ -n "$release_pair" ]; then
  release_pipeline=$(printf '%s\n' "$release_pair" | cut -f1)
  release_commit=$(printf '%s\n' "$release_pair" | cut -f2)
  linux_job=$(printf '%s\n' "$release_pair" | cut -f3)
  macos_job=$(printf '%s\n' "$release_pair" | cut -f4)
  current_pair=""
  if [ -f "$data_dir/release.json" ]; then
    current_pair=$(jq -r '
      if .job_ids.linux and .job_ids.macos
      then "\(.job_ids.linux):\(.job_ids.macos)"
      else empty
      end
    ' "$data_dir/release.json" 2>/dev/null || true)
  fi

  if [ "$linux_job:$macos_job" != "$current_pair" ]; then
    for release_os in linux macos; do
      case "$release_os" in
        linux) release_job=$linux_job ;;
        macos) release_job=$macos_job ;;
      esac
      api_get "$api_base/jobs/$release_job" > "$work_dir/release-job-$release_os.json"
      curl --config "$curl_config" \
        "$api_base/jobs/$release_job/artifacts" > "$work_dir/artifacts-$release_os.zip"
      mkdir -p "$work_dir/artifacts-$release_os"
      unzip -q "$work_dir/artifacts-$release_os.zip" -d "$work_dir/artifacts-$release_os"
      test -f "$work_dir/artifacts-$release_os/dist/release.json"
      test -f "$work_dir/artifacts-$release_os/dist/SHA256SUMS"
      jq empty "$work_dir/artifacts-$release_os/dist/release.json"
    done

    linux_release="$work_dir/artifacts-linux/dist/release.json"
    macos_release="$work_dir/artifacts-macos/dist/release.json"
    jq -e '.files | length == 2 and all(.os == "linux")' "$linux_release" >/dev/null
    jq -e '.files | length == 2 and all(.os == "darwin")' "$macos_release" >/dev/null
    linux_release_id=$(jq -r '.release_id' "$linux_release")
    macos_release_id=$(jq -r '.release_id' "$macos_release")
    linux_commit=$(jq -r '.commit' "$linux_release")
    macos_commit=$(jq -r '.commit' "$macos_release")
    if [ "$linux_release_id" != "$macos_release_id" ] || \
       [ "$linux_commit" != "$macos_commit" ] || \
       [ "$linux_commit" != "$release_commit" ]; then
      echo "release artifact identity mismatch for pipeline $release_pipeline" >&2
      exit 2
    fi

    mkdir -p "$work_dir/combined"
    cat \
      "$work_dir/artifacts-linux/dist/SHA256SUMS" \
      "$work_dir/artifacts-macos/dist/SHA256SUMS" > "$work_dir/combined/SHA256SUMS"
    jq -s '.[0] + {files: (.[0].files + .[1].files)}' \
      "$linux_release" "$macos_release" > "$work_dir/combined/release.json"

    jq -r '.files[].name' "$work_dir/combined/release.json" | while IFS= read -r filename; do
      case "$filename" in
        ""|*/*|*".."*) echo "unsafe artifact filename: $filename" >&2; exit 2 ;;
      esac
      source_file=""
      for release_os in linux macos; do
        candidate="$work_dir/artifacts-$release_os/dist/$filename"
        if [ -f "$candidate" ]; then
          source_file=$candidate
          break
        fi
      done
      test -n "$source_file"
      cp "$source_file" "$work_dir/combined/$filename"
    done
    (cd "$work_dir/combined" && sha256sum -c SHA256SUMS)

    jq -r '.files[].name' "$work_dir/combined/release.json" | while IFS= read -r filename; do
      install -m 0644 "$work_dir/combined/$filename" "$downloads_dir/$filename"
    done
    install -m 0644 "$work_dir/combined/SHA256SUMS" "$downloads_dir/SHA256SUMS"

    linux_job_url=$(jq -r '.web_url' "$work_dir/release-job-linux.json")
    macos_job_url=$(jq -r '.web_url' "$work_dir/release-job-macos.json")
    jq \
      --argjson pipeline_id "$release_pipeline" \
      --argjson linux_job "$linux_job" \
      --argjson macos_job "$macos_job" \
      --arg linux_job_url "$linux_job_url" \
      --arg macos_job_url "$macos_job_url" \
      --arg synced_at "$generated_at" \
      '. + {
        pipeline_id: $pipeline_id,
        job_id: $linux_job,
        job_url: $linux_job_url,
        job_ids: {linux: $linux_job, macos: $macos_job},
        job_urls: {linux: $linux_job_url, macos: $macos_job_url},
        synced_at: $synced_at
      }' "$work_dir/combined/release.json" > "$work_dir/release-published.json"
    install -m 0644 "$work_dir/release-published.json" "$data_dir/release.json.new"
    mv "$data_dir/release.json.new" "$data_dir/release.json"
    echo "published release pipeline $release_pipeline jobs $linux_job/$macos_job"
  fi
fi

echo "refreshed $pipeline_count pipelines at $generated_at"
