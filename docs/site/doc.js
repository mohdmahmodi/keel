// Highlights the section being read in the table of contents.
const links = [...document.querySelectorAll('.toc a')];
const ids = links.map(a => a.getAttribute('href').slice(1));
const visible = new Set();
const update = () => {
  const current = ids.find(id => visible.has(id));
  links.forEach((a, i) => a.classList.toggle('active', ids[i] === current));
};
const observer = new IntersectionObserver(entries => {
  for (const e of entries) e.isIntersecting ? visible.add(e.target.id) : visible.delete(e.target.id);
  update();
}, { rootMargin: '-80px 0px -55% 0px' });
ids.forEach(id => { const el = document.getElementById(id); if (el) observer.observe(el); });
