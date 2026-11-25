#!/bin/sh
# Mirror the newest formal release of every release line (vYY.M.PATCH tags,
# grouped by YY.M) and describe release/YY.M branches that have no tag yet.
#
# Tags and branches come from the GitLab API; the archives and SHA256SUMS come
# from the public distribution source (Aliyun OSS releases/<tag>/), which keeps
# version-tag directories forever, unlike the 30-day CI job artifacts. Each tag
# lands in downloads/<tag>/ only after every archive checks out against that
# tag's SHA256SUMS (a stage directory renamed into place), so a tag directory
# that has its SHA256SUMS is complete and is not downloaded again.
#
# Writes data/releases.json. On any failure the previous file stays in place.
set -eu

: "${GITLAB_URL:?GITLAB_URL is required}"
: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"
: "${SITE_ROOT:?SITE_ROOT is required}"

project_path=${GITLAB_PROJECT_PATH:-wei.wang%2Fgpuworks}
dist_base=${GPUWORKS_DIST_BASE:-https://gpuworks-dl.oss-cn-shanghai.aliyuncs.com}
api_base="${GITLAB_URL%/}/api/v4/projects/${project_path}"
data_dir="$SITE_ROOT/data"
downloads_dir="$SITE_ROOT/downloads"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/gpuworks-site-releases.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT INT TERM
curl_config="$work_dir/curl.conf"
umask 077
printf '%s\n' \
  'fail' 'silent' 'show-error' 'retry = 3' 'retry-delay = 2' \
  'connect-timeout = 10' 'max-time = 45' \
  "header = \"PRIVATE-TOKEN: ${GITLAB_TOKEN}\"" > "$curl_config"
umask 022

api_get() {
  curl --config "$curl_config" "$1"
}

dist_get() {
  curl --fail --silent --show-error --retry 3 --retry-delay 2 \
    --connect-timeout 10 --max-time 900 -o "$2" "$dist_base/$1"
}

mkdir -p "$data_dir" "$downloads_dir"

# GitLab 14 has no regex search; "^v" is a prefix search, the jq below keeps
# exact vYY.M.PATCH names only.
api_get "$api_base/repository/tags?search=%5Ev&per_page=100" > "$work_dir/tags.json"
api_get "$api_base/repository/branches?search=%5Erelease%2F&per_page=100" > "$work_dir/branches.json"

# One entry per line YY.M: its newest tag (by version), the number of tags in
# the line, and the release/YY.M branch head when that branch exists.
jq -n \
  --slurpfile tags "$work_dir/tags.json" \
  --slurpfile branches "$work_dir/branches.json" '
  def vkey: ltrimstr("v") | split(".") | map(tonumber);
  ([$tags[0][] | select(.name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
     | {name, commit: .commit.id, committed_at: .commit.committed_date,
        line: (.name | ltrimstr("v") | split(".")[0:2] | join("."))}]) as $t
  | ([$branches[0][] | select(.name | test("^release/[0-9]+\\.[0-9]+$"))
     | {key: (.name | ltrimstr("release/")),
        value: {name, commit: .commit.id, committed_at: .commit.committed_date, web_url}}]
     | from_entries) as $b
  | (($t | map(.line)) + ($b | keys) | unique) as $lines
  | [$lines[] as $line
     | ($t | map(select(.line == $line)) | sort_by(.name | vkey)) as $lt
     | {line: $line,
        latest: ($lt | last),
        tag_count: ($lt | length),
        branch: $b[$line]}]
  | sort_by(.line | split(".") | map(tonumber)) | reverse
' > "$work_dir/lines.json"

# Mirror every line's newest tag that is not on this host yet.
for tag in $(jq -r '.[] | .latest.name // empty' "$work_dir/lines.json"); do
  case "$tag" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "unexpected tag name: $tag" >&2; exit 2 ;;
  esac
  target="$downloads_dir/$tag"
  # downloads/<tag>/ only ever appears by renaming a verified stage.
  if [ -f "$target/SHA256SUMS" ]; then
    continue
  fi
  stage="$work_dir/stage-$tag"
  mkdir -p "$stage"
  dist_get "releases/$tag/SHA256SUMS" "$stage/SHA256SUMS"
  # Only gpuworks-<tag>-<os>-<arch>.tar.gz names are accepted, so nothing in
  # the sums file can point outside the stage directory.
  awk '{print $2}' "$stage/SHA256SUMS" | while IFS= read -r name; do
    if ! printf '%s\n' "$name" | grep -Eq "^gpuworks-$tag-(linux|darwin)-(amd64|arm64)\.tar\.gz$"; then
      echo "unexpected archive name in $tag SHA256SUMS: $name" >&2
      exit 2
    fi
    dist_get "releases/$tag/$name" "$stage/$name"
  done
  test -n "$(awk '{print $2}' "$stage/SHA256SUMS")"
  (cd "$stage" && sha256sum -c --quiet SHA256SUMS)
  chmod 0644 "$stage"/*
  chmod 0755 "$stage"
  rm -rf "$target"
  mv "$stage" "$target"
  echo "mirrored release $tag"
done

# Mirror the newest build of every release/YY.M branch head: the newest of the
# branch's recent pipelines in which all four release-build jobs succeeded
# (the pipeline itself may still have failed elsewhere, as on master). The
# build replaces the line's previous one in downloads/release-<YY.M>/ only
# after every archive checks out against the merged SHA256SUMS.
release_build_jobs='release-build-linux-amd64 release-build-linux-arm64 release-build-macos-amd64 release-build-macos-arm64'
for line in $(jq -r '.[] | select(.branch) | .line' "$work_dir/lines.json"); do
  case "$line" in
    *[!0-9.]*|"") echo "unexpected release line: $line" >&2; exit 2 ;;
  esac
  ref=$(printf 'release/%s' "$line" | jq -sRr @uri)
  api_get "$api_base/pipelines?ref=$ref&per_page=20&order_by=id&sort=desc" > "$work_dir/branch-pipelines.json"
  found=""
  for pipeline_id in $(jq -r '.[].id' "$work_dir/branch-pipelines.json"); do
    api_get "$api_base/pipelines/$pipeline_id/jobs?per_page=100" > "$work_dir/branch-jobs.json"
    found=$(jq -r --arg names "$release_build_jobs" --argjson id "$pipeline_id" \
      --slurpfile pipelines "$work_dir/branch-pipelines.json" '
      ([.[] | select(.status == "success")] | map({key: .name, value: .id}) | from_entries) as $ok
      | ($names | split(" ")) as $want
      | ($pipelines[0][] | select(.id == $id)) as $p
      | if all($want[]; $ok[.] != null) then
          [$p.id, $p.sha, $p.web_url, ($want | map($ok[.] | tostring) | join(" "))] | @tsv
        else empty end
    ' "$work_dir/branch-jobs.json")
    [ -n "$found" ] && break
  done
  if [ -z "$found" ]; then
    continue
  fi
  pipeline_id=$(printf '%s\n' "$found" | cut -f1)
  pipeline_sha=$(printf '%s\n' "$found" | cut -f2)
  pipeline_url=$(printf '%s\n' "$found" | cut -f3)
  job_list=$(printf '%s\n' "$found" | cut -f4)
  target="$downloads_dir/release-$line"
  if [ -f "$target/build.json" ] &&
    [ "$(jq -r '.job_list | map(tostring) | join(" ")' "$target/build.json" 2>/dev/null)" = "$job_list" ]; then
    continue
  fi

  stage="$work_dir/stage-release-$line"
  mkdir -p "$stage"
  : > "$stage/SHA256SUMS"
  set --
  for job in $job_list; do
    job_dir="$work_dir/branch-artifacts-$line-$job"
    curl --config "$curl_config" --max-time 900 "$api_base/jobs/$job/artifacts" > "$job_dir.zip"
    if unzip -Z1 "$job_dir.zip" | grep -Eq '(^/|(^|/)\.\.?(/|$))'; then
      echo "unsafe path in release artifact from job $job" >&2
      exit 2
    fi
    mkdir -p "$job_dir"
    unzip -qo "$job_dir.zip" -d "$job_dir" </dev/null
    test -f "$job_dir/dist/release.json"
    test -f "$job_dir/dist/SHA256SUMS"
    job_commit=$(jq -r '.commit' "$job_dir/dist/release.json")
    if [ "$job_commit" != "$pipeline_sha" ]; then
      echo "release artifact of job $job is from $job_commit, not $pipeline_sha" >&2
      exit 2
    fi
    cat "$job_dir/dist/SHA256SUMS" >> "$stage/SHA256SUMS"
    for name in $(jq -r '.files[].name' "$job_dir/dist/release.json"); do
      case "$name" in
        ""|*/*|*".."*) echo "unsafe artifact filename: $name" >&2; exit 2 ;;
      esac
      cp "$job_dir/dist/$name" "$stage/$name"
    done
    set -- "$@" "$job_dir/dist/release.json"
  done
  (cd "$stage" && sha256sum -c --quiet SHA256SUMS)
  jq -s \
    --arg line "$line" \
    --argjson pipeline_id "$pipeline_id" \
    --arg pipeline_url "$pipeline_url" \
    --arg job_list "$job_list" \
    --arg synced_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    if (map(.release_id) | unique | length) != 1 then error("release ids differ across jobs") else . end
    | {
        branch: ("release/" + $line),
        release_id: .[0].release_id,
        commit: .[0].commit,
        build_at: .[0].build_at,
        pipeline_id: $pipeline_id,
        pipeline_url: $pipeline_url,
        job_list: ($job_list | split(" ") | map(tonumber)),
        synced_at: $synced_at,
        files: (map(.files) | add | map({name, os, arch: (.goarch // .arch), size, sha256})
          | sort_by({"linux": 0, "darwin": 1}[.os] * 10 + {"amd64": 0, "arm64": 1}[.arch]))
      }
    | if (.files | map(.name) | unique | length) != (.files | length) then error("an archive appears twice") else . end
  ' "$@" > "$stage/build.json"
  chmod 0644 "$stage"/*
  chmod 0755 "$stage"
  rm -rf "$target"
  mv "$stage" "$target"
  echo "mirrored release/$line pipeline $pipeline_id jobs $job_list"
done

# Describe each mirrored archive from the sums file and the file on disk.
for tag in $(jq -r '.[] | .latest.name // empty' "$work_dir/lines.json"); do
  while read -r sha name; do
    size=$(stat -c %s "$downloads_dir/$tag/$name")
    printf '%s\n' "$name" | sed -E "s/^gpuworks-$tag-([a-z]+)-([a-z0-9]+)\.tar\.gz$/\1 \2/" | {
      read -r os arch
      jq -n --arg tag "$tag" --arg name "$name" --arg sha "$sha" --arg os "$os" \
        --arg arch "$arch" --argjson size "$size" \
        '{tag: $tag, name: $name, os: $os, arch: $arch, size: $size, sha256: $sha}'
    }
  done < "$downloads_dir/$tag/SHA256SUMS"
done | jq -s '.' > "$work_dir/files.json"

# Branch builds on this host, keyed by line, for lines whose branch still exists.
for line in $(jq -r '.[] | select(.branch) | .line' "$work_dir/lines.json"); do
  if [ -f "$downloads_dir/release-$line/build.json" ]; then
    jq --arg line "$line" '{key: $line, value: (. + {
        checksums: ("/downloads/release-" + $line + "/SHA256SUMS"),
        directory: ("/downloads/release-" + $line + "/")
      })}' "$downloads_dir/release-$line/build.json"
  fi
done | jq -s 'from_entries' > "$work_dir/builds.json"

generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n \
  --slurpfile builds "$work_dir/builds.json" \
  --arg generated_at "$generated_at" \
  --arg dist_base "$dist_base" \
  --slurpfile lines "$work_dir/lines.json" \
  --slurpfile files "$work_dir/files.json" '
  def order: {"linux": 0, "darwin": 1}[.os] * 10 + {"amd64": 0, "arm64": 1}[.arch];
  {
    generated_at: $generated_at,
    source: $dist_base,
    lines: [$lines[0][] | . as $l | . + {
      latest: (if $l.latest then $l.latest + {
        files: ([$files[0][] | select(.tag == $l.latest.name) | del(.tag)] | sort_by(order)),
        checksums: ("/downloads/" + $l.latest.name + "/SHA256SUMS")
      } else null end),
      branch_build: ($builds[0][$l.line] // null)
    }]
  }' > "$work_dir/releases.json"

install -m 0644 "$work_dir/releases.json" "$data_dir/releases.json.new"
mv "$data_dir/releases.json.new" "$data_dir/releases.json"
echo "refreshed $(jq '.lines | length' "$work_dir/releases.json") release lines at $generated_at"
