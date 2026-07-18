// Maxi 80 — landing page interactions (progressive enhancement)
(function () {
  "use strict";

  // Sticky nav: add a border once the page scrolls.
  const nav = document.getElementById("nav");
  const onScroll = () => nav.classList.toggle("is-stuck", window.scrollY > 8);
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });

  // Scroll reveal — respect reduced-motion.
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Hero phone: cycle iOS <-> Android every few seconds.
  const shots = Array.from(document.querySelectorAll(".phone__shot"));
  const badge = document.getElementById("heroBadge");
  if (shots.length > 1 && !reduce) {
    let i = 0;
    const advance = () => {
      shots[i].classList.remove("is-active");
      i = (i + 1) % shots.length;
      shots[i].classList.add("is-active");
      if (badge) badge.textContent = shots[i].dataset.platform || "";
    };
    let timer = setInterval(advance, 3500);
    // Pause the cycle while the tab is in the background.
    document.addEventListener("visibilitychange", () => {
      clearInterval(timer);
      if (!document.hidden) timer = setInterval(advance, 3500);
    });
  }
  const targets = document.querySelectorAll(
    ".section-head, .screen-card, .feature__copy, .feature__media, .tv-frame, .road__inner, .extras__grid li, .cta > *"
  );

  if (reduce || !("IntersectionObserver" in window)) {
    targets.forEach((el) => el.classList.add("is-in"));
    return;
  }

  targets.forEach((el, i) => {
    el.classList.add("reveal");
    el.style.transitionDelay = (i % 4) * 60 + "ms";
  });

  const io = new IntersectionObserver(
    (entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) {
          e.target.classList.add("is-in");
          io.unobserve(e.target);
        }
      });
    },
    { threshold: 0.12, rootMargin: "0px 0px -8% 0px" }
  );
  targets.forEach((el) => io.observe(el));
})();
