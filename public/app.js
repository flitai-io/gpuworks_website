const CORE_JOBS = new Set([
  "core-ui", "core-test", "core-vet", "core-l2", "core-l3", "core-blueprint-seed",
]);

const LIVE_STAGES = new Set(["cloud-smoke", "cloud-full"]);

const STATUS_LABELS = {
  success: "通过", failed: "失败", running: "运行中", pending: "等待中",
  waiting_for_resource: "等待资源", created: "已创建", canceled: "已取消",
  skipped: "已跳过", manual: "手动", none: "未运行",
};

function text(id, value) {
  const node = document.getElementById(id);
  if (node) node.textContent = value;
}

function formatBytes(value) {
  if (!Number.isFinite(value)) return "—";
  const units = ["B", "KiB", "MiB", "GiB"];
  let size = value;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  return size.toFixed(unit > 1 ? 1 : 0) + " " + units[unit];
}

function formatDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "—";
  const rounded = Math.round(seconds);
  const hours = Math.floor(rounded / 3600);
  const minutes = Math.floor((rounded % 3600) / 60);
  const secs = rounded % 60;
  if (hours) return hours + " 小时 " + minutes + " 分";
  if (minutes) return minutes + " 分 " + secs + " 秒";
  return secs + " 秒";
}

function formatDate(value) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) return "—";
  return new Intl.DateTimeFormat("zh-CN", {
    month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false,
  }).format(date);
}

function shortSha(value) {
  return value ? String(value).slice(0, 8) : "—";
}

function statusBadge(status) {
  const value = STATUS_LABELS[status] ? status : "none";
  const span = document.createElement("span");
  span.className = "badge " + value;
  span.textContent = STATUS_LABELS[value];
  return span;
}

function setStatus(id, status) {
  const node = document.getElementById(id);
  if (!node) return;
  node.textContent = "";
  node.append(statusBadge(status));
}

function cell(value) {
  const td = document.createElement("td");
  if (value instanceof Node) td.append(value);
  else td.textContent = value;
  return td;
}

function linkCell(label, href) {
  const anchor = document.createElement("a");
  anchor.textContent = label;
  anchor.href = href || "#";
  if (href) {
    anchor.target = "_blank";
    anchor.rel = "noreferrer";
  }
  return cell(anchor);
}

function summarizeJobs(jobs, predicate) {
  const selected = (jobs || []).filter(predicate);
  if (!selected.length) return "none";
  const statuses = selected.map(function (job) { return job.status; });
  if (statuses.includes("failed")) return "failed";
  if (statuses.includes("running")) return "running";
  if (statuses.includes("waiting_for_resource")) return "waiting_for_resource";
  if (statuses.some(function (status) { return ["pending", "created"].includes(status); })) return "pending";
  const effective = statuses.filter(function (status) {
    return !["manual", "skipped", "canceled"].includes(status);
  });
  if (effective.length && effective.every(function (status) { return status === "success"; })) return "success";
  if (!effective.length) return "none";
  return statuses[0] || "none";
}

function isLiveJob(job) {
  return LIVE_STAGES.has(job.stage);
}

function discoverLiveTests(pipelines) {
  const tests = new Map();
  pipelines.forEach(function (pipeline) {
    (pipeline.jobs || []).forEach(function (job) {
      if (isLiveJob(job) && !tests.has(job.name)) {
        tests.set(job.name, { name: job.name, stage: job.stage });
      }
    });
  });
  const stageOrder = { "cloud-smoke": 0, "cloud-full": 1 };
  return Array.from(tests.values()).sort(function (left, right) {
    const stageDiff = (stageOrder[left.stage] ?? 99) - (stageOrder[right.stage] ?? 99);
    return stageDiff || left.name.localeCompare(right.name, "en");
  });
}

function testNameCell(test) {
  const wrapper = document.createElement("div");
  wrapper.className = "test-name";
  const name = document.createElement("code");
  name.textContent = test.name;
  const stage = document.createElement("small");
  stage.textContent = test.stage;
  wrapper.append(name, stage);
  return cell(wrapper);
}

async function loadRelease() {
  const response = await fetch("/data/release.json", { cache: "no-store" });
  if (!response.ok) throw new Error("release metadata: " + response.status);
  const release = await response.json();
  text("release-id", "构建 " + (release.release_id || shortSha(release.commit)));
  const build = formatDate(release.build_at);
  const job = release.job_id ? " · CI job #" + release.job_id : "";
  text("release-detail", "commit " + shortSha(release.commit) + " · " + build + job);

  (release.files || []).forEach(function (file) {
    const card = document.querySelector('.download-card[data-arch="' + file.arch + '"]');
    if (!card) return;
    const size = card.querySelector('[data-field="size"]');
    const sha = card.querySelector('[data-field="sha"]');
    const anchor = card.querySelector(".download-link");
    if (size) size.textContent = formatBytes(Number(file.size));
    if (sha) {
      sha.textContent = file.sha256 || "—";
      sha.title = file.sha256 || "";
    }
    if (anchor && file.name) {
      anchor.href = "/downloads/" + encodeURIComponent(file.name);
      anchor.removeAttribute("aria-disabled");
    }
  });

  const amd64 = (release.files || []).find(function (file) { return file.arch === "amd64"; });
  if (amd64) {
    const packageDir = amd64.name.replace(/\.tar\.gz$/, "");
    text("server-install-command", [
      "curl -fLO https://gpuworks.zstack.ai/downloads/" + amd64.name,
      "curl -fLO https://gpuworks.zstack.ai/downloads/SHA256SUMS",
      "sha256sum -c SHA256SUMS --ignore-missing",
      "tar -xzf " + amd64.name,
      "cd " + packageDir,
      "./gpuworks install",
    ].join("\n"));
    // The public sources (ADR 0040) carry the same archives under
    // releases/<release_id>/; OSS is the default in the command, the hint
    // above it names the OBS and R2 alternates.
    const distDir = "https://gpuworks-dl.oss-cn-shanghai.aliyuncs.com/releases/" + (release.release_id || shortSha(release.commit));
    text("server-install-command-public", [
      "curl -fLO " + distDir + "/" + amd64.name,
      "curl -fLO " + distDir + "/SHA256SUMS",
      "sha256sum -c SHA256SUMS --ignore-missing",
      "tar -xzf " + amd64.name,
      "cd " + packageDir,
      "./gpuworks install",
    ].join("\n"));
  }
  return release;
}

function selectInstallTab(tab) {
  document.querySelectorAll(".install-tab").forEach(function (other) {
    const selected = other === tab;
    other.setAttribute("aria-selected", selected ? "true" : "false");
    other.tabIndex = selected ? 0 : -1;
    const panel = document.getElementById(other.getAttribute("aria-controls"));
    if (panel) panel.hidden = !selected;
  });
}

function setupInstallTabs() {
  const tabs = Array.from(document.querySelectorAll(".install-tab"));
  tabs.forEach(function (tab, index) {
    tab.addEventListener("click", function () { selectInstallTab(tab); });
    tab.addEventListener("keydown", function (event) {
      let offset = 0;
      if (event.key === "ArrowRight") offset = 1;
      else if (event.key === "ArrowLeft") offset = -1;
      else return;
      event.preventDefault();
      const next = tabs[(index + offset + tabs.length) % tabs.length];
      next.focus();
      selectInstallTab(next);
    });
  });
}

function renderLiveTests(pipelines) {
  const tbody = document.getElementById("live-test-rows");
  tbody.textContent = "";
  let allSuccess = 0;
  let allEffective = 0;
  const tests = discoverLiveTests(pipelines);

  tests.forEach(function (test) {
    const name = test.name;
    const runs = [];
    pipelines.forEach(function (pipeline) {
      (pipeline.jobs || []).forEach(function (job) {
        if (job.name === name) runs.push(Object.assign({}, job, { pipeline: pipeline }));
      });
    });
    const latestEffective = runs.find(function (run) { return ["success", "failed"].includes(run.status); });
    const latestSuccess = runs.find(function (run) { return run.status === "success"; });
    const effective = runs.filter(function (run) { return ["success", "failed"].includes(run.status); });
    const notRun = runs.filter(function (run) {
      return ["skipped", "manual", "canceled"].includes(run.status);
    }).length;
    const successes = effective.filter(function (run) { return run.status === "success"; }).length;
    allSuccess += successes;
    allEffective += effective.length;

    const tr = document.createElement("tr");
    tr.append(testNameCell(test));
    tr.append(cell(statusBadge(latestEffective ? latestEffective.status : "none")));
    tr.append(cell(formatDate(latestSuccess ? (latestSuccess.finished_at || latestSuccess.started_at) : null)));
    tr.append(cell(formatDuration(Number(latestSuccess ? latestSuccess.duration : NaN))));
    tr.append(cell(successes + " / " + effective.length));
    tr.append(cell(String(notRun)));
    tr.append(cell(effective.length ? Math.round((successes / effective.length) * 100) + "%" : "—"));
    tbody.append(tr);
  });

  if (!tests.length) {
    const tr = document.createElement("tr");
    const empty = cell("当前统计窗口没有 GitLab 创建的云真机 job");
    empty.colSpan = 7;
    empty.className = "loading-cell";
    tr.append(empty);
    tbody.append(tr);
  }

  const rate = allEffective ? Math.round((allSuccess / allEffective) * 100) : null;
  setStatus("ci-live", allEffective && allSuccess === allEffective ? "success" : allEffective ? "failed" : "none");
  text("ci-live-detail", rate == null ? "窗口内没有已结束运行" : allSuccess + " / " + allEffective + " 通过 · " + rate + "%");
}

function renderPipelines(pipelines) {
  const tbody = document.getElementById("pipeline-rows");
  tbody.textContent = "";

  pipelines.forEach(function (pipeline) {
    const core = summarizeJobs(pipeline.jobs, function (job) { return CORE_JOBS.has(job.name); });
    const live = summarizeJobs(pipeline.jobs, isLiveJob);
    const tr = document.createElement("tr");
    tr.append(linkCell("#" + pipeline.id, pipeline.web_url));
    const sha = document.createElement("code");
    sha.textContent = shortSha(pipeline.sha);
    tr.append(cell(sha));
    tr.append(cell(formatDate(pipeline.started_at || pipeline.created_at)));
    tr.append(cell(formatDuration(Number(pipeline.duration))));
    tr.append(cell(statusBadge(core)));
    tr.append(cell(statusBadge(live)));
    tr.append(cell(statusBadge(pipeline.status)));
    tbody.append(tr);
  });

  text("pipeline-window", "最近 " + pipelines.length + " 条");
}

function renderCISummary(pipelines, release) {
  const latest = pipelines[0];
  if (!latest) throw new Error("empty pipeline history");
  const core = summarizeJobs(latest.jobs, function (job) { return CORE_JOBS.has(job.name); });
  setStatus("ci-overall", latest.status);
  text("ci-overall-detail", "#" + latest.id + " · " + shortSha(latest.sha) + " · " + formatDuration(Number(latest.duration)));
  setStatus("ci-core", core);
  const coreJobs = (latest.jobs || []).filter(function (job) { return CORE_JOBS.has(job.name); });
  const corePassed = coreJobs.filter(function (job) { return job.status === "success"; }).length;
  text("ci-core-detail", corePassed + " / " + CORE_JOBS.size + " 个门禁通过");

  if (release) {
    setStatus("ci-release", "success");
    text("ci-release-detail", shortSha(release.commit) + " · " + formatDate(release.build_at));
  } else {
    setStatus("ci-release", "none");
  }
}

async function loadCI(release) {
  const response = await fetch("/data/ci.json", { cache: "no-store" });
  if (!response.ok) throw new Error("ci data: " + response.status);
  const data = await response.json();
  const pipelines = Array.isArray(data.pipelines) ? data.pipelines : [];
  text("ci-updated", "GitLab 数据刷新于 " + formatDate(data.generated_at) + "；页面每分钟自动重读。");
  renderLiveTests(pipelines);
  renderPipelines(pipelines);
  renderCISummary(pipelines, release);
}

function setupCopyButtons() {
  document.querySelectorAll("[data-copy]").forEach(function (button) {
    button.addEventListener("click", async function () {
      const target = document.getElementById(button.dataset.copy);
      if (!target) return;
      try {
        await navigator.clipboard.writeText(target.textContent);
        button.textContent = "已复制";
        window.setTimeout(function () { button.textContent = "复制"; }, 1400);
      } catch (error) {
        button.textContent = "复制失败";
      }
    });
  });
}

async function refresh() {
  let release = null;
  try {
    release = await loadRelease();
  } catch (error) {
    console.warn(error);
    text("release-id", "发布元数据暂不可用");
    text("release-detail", "请稍后刷新");
  }
  try {
    await loadCI(release);
    document.getElementById("ci-error").hidden = true;
  } catch (error) {
    console.warn(error);
    document.getElementById("ci-error").hidden = false;
    ["ci-overall", "ci-core", "ci-live"].forEach(function (id) { setStatus(id, "none"); });
  }
}

setupCopyButtons();
setupInstallTabs();
refresh();
window.setInterval(refresh, 60000);
