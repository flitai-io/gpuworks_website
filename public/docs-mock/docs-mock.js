(function () {
  var menu = document.querySelector(".menu-button");
  var mobileNav = document.querySelector("#mobile-nav");
  if (menu && mobileNav) {
    menu.addEventListener("click", function () {
      var open = mobileNav.classList.toggle("open");
      menu.setAttribute("aria-expanded", String(open));
    });
  }

  var input = document.querySelector("#doc-search");
  var hint = document.querySelector("#search-hint");
  var links = Array.prototype.slice.call(document.querySelectorAll(".side-link, .task-card, .update-row a, .role-card"));
  if (input && hint) {
    input.addEventListener("input", function () {
      var query = input.value.trim().toLowerCase();
      if (!query) {
        links.forEach(function (link) { link.hidden = false; });
        hint.textContent = "试试搜索 “模型部署” 或 “nvidia-smi”";
        return;
      }
      var count = 0;
      links.forEach(function (link) {
        var matched = link.textContent.toLowerCase().indexOf(query) >= 0;
        link.hidden = !matched;
        if (matched) count += 1;
      });
      hint.textContent = count ? "找到 " + count + " 个相关入口，点击即可继续" : "没有匹配项，试试“节点”“镜像”或“API”";
    });
  }
  document.addEventListener("keydown", function (event) {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
      event.preventDefault();
      if (input) input.focus();
    }
  });
}());
