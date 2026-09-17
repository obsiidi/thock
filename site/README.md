# thock website

Static HTML/CSS, no build step, no third-party requests.

## Deploy on Vercel (free Hobby plan — fine as long as nothing is sold)

1. Push the repository to GitHub.
2. On vercel.com: **Add New › Project › Import** the `thock` repository.
3. Set **Root Directory** to `site`. Framework preset: **Other**. No build
   command, output directory `.` (leave empty).
4. Deploy. The site is live at `<project>.vercel.app`.

Every push to `main` redeploys. Before sharing publicly, fill in
`imprint.html` (address, e-mail) — it is legally required in Germany once
the site is public.

## Local preview

```bash
python3 -m http.server 8080 --directory site
```
