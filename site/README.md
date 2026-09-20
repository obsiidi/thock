# thock website

Static HTML/CSS/JS, no build step, no third-party requests. Design made in
Claude Design and ported to plain files: `index.html`, `style.css`, `site.js`
(dot-matrix graphics + key-force demo), self-hosted fonts in `fonts/` (OFL).
The CSP in `vercel.json` allows only same-origin styles, scripts and fonts —
no inline `style=""` or `<script>` blocks.

## Deploy on Vercel (free Hobby plan — fine as long as nothing is sold)

1. Push the repository to GitHub.
2. On vercel.com: **Add New › Project › Import** the `thock` repository.
3. Set **Root Directory** to `site`. Framework preset: **Other**. No build
   command, output directory `.` (leave empty).
4. Deploy. The site is live at `<project>.vercel.app`.

Every push to `main` redeploys.

## Local preview

```bash
python3 -m http.server 8080 --directory site
```
