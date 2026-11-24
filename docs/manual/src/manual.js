// Adapted from the Prindex guide script: search, current-section highlight, print helpers.
(function () {
  var q = document.getElementById("q");
  var qn = document.getElementById("qn");
  var items = Array.prototype.slice.call(document.querySelectorAll(".faq-item, .gloss-item, .legend > li, table.t tbody tr, .steps > li"));
  var sections = Array.prototype.slice.call(document.querySelectorAll("main > section.block"));
  function norm(s) { return s.toLowerCase().replace(/\u0451/g, "\u0435"); }
  var texts = items.map(function (el) { return norm(el.textContent); });
  function run() {
    var v = norm(q.value.trim());
    var n = 0;
    items.forEach(function (el, i) {
      var hit = !v || texts[i].indexOf(v) !== -1;
      el.classList.toggle("is-hidden", !hit);
      if (hit && v) { n++; if (el.tagName === "DETAILS") el.open = true; }
    });
    sections.forEach(function (s) {
      if (!v) { s.classList.remove("is-hidden"); return; }
      s.classList.toggle("is-hidden", norm(s.textContent).indexOf(v) === -1);
    });
    document.querySelector(".cover").classList.toggle("is-hidden", !!v);
    qn.textContent = v ? (n ? "найдено: " + n : "ничего не найдено") : "";
  }
  q.addEventListener("input", run);

  // Highlight the current section in the table of contents.
  var links = {};
  Array.prototype.forEach.call(document.querySelectorAll(".toc a"), function (a) { links[a.getAttribute("href").slice(1)] = a; });
  if ("IntersectionObserver" in window) {
    var io = new IntersectionObserver(function (es) {
      es.forEach(function (e) {
        if (e.isIntersecting && links[e.target.id]) {
          Object.keys(links).forEach(function (k) { links[k].classList.remove("on"); });
          links[e.target.id].classList.add("on");
        }
      });
    }, { rootMargin: "-20% 0px -70% 0px" });
    sections.forEach(function (s) { io.observe(s); });
  }

  // Collapse the table of contents on narrow screens, keep it open on wide ones.
  var tocd = document.getElementById("tocd");
  if (window.matchMedia && window.matchMedia("(max-width: 980px)").matches) tocd.open = false;

  // Open every collapsed block when printing, and clear a search so nothing is hidden.
  var opened = [];
  window.addEventListener("beforeprint", function () {
    if (q.value) { q.value = ""; run(); }
    opened = Array.prototype.filter.call(document.querySelectorAll("details"), function (d) { return !d.open; });
    opened.forEach(function (d) { d.open = true; });
  });
  window.addEventListener("afterprint", function () { opened.forEach(function (d) { d.open = false; }); });
})();
