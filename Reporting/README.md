# Goby error reports

A small Vercel project that receives redacted error reports from `goby` on
machines whose owners agreed to send them, and a private page to read them.

- `POST /api/report` takes up to 50 events. It checks the `X-Goby-Key` build
  key, accepts only the documented fields with size limits, rate-limits each
  anonymous installation to 100 reports an hour, and keeps the newest 5,000.
- `GET /api/reports` lists them. It needs `Authorization: Bearer <admin token>`.
- `/` is a page that groups repeated errors. Enter the admin token once; the
  browser remembers it.

Reports never contain prompts, code, file paths or keys: the CLI redacts them
before sending, and the endpoint stores only the fields below.

`installationID, timestamp, version, macOS, architecture, kind, command,
provider, message, exitCode`

## Deploy

1. Create a Vercel project with this folder as its root:

   ```sh
   cd Reporting && npx vercel@latest link
   ```

2. In the Vercel dashboard, add **Upstash for Redis** from the Marketplace to
   the project. It sets `KV_REST_API_URL` and `KV_REST_API_TOKEN`.
3. Add two environment variables:
   - `GOBY_INGEST_KEY` = `goby-cli-ingest-v1` (must match
     `GobyReportingConfiguration.ingestKey` in the CLI)
   - `GOBY_ADMIN_TOKEN` = a long random value, for example from
     `openssl rand -hex 24`. Keep it private.
4. Deploy:

   ```sh
   npx vercel@latest deploy --prod
   ```

5. Put `https://<your-project>.vercel.app/api/report` in
   `GobyReportingConfiguration.endpoint` (Sources/GobyCLIKit/Reporting.swift)
   and release a new build. Until then, reports stay queued locally.

The current deployment is `https://goby-reports.vercel.app` (Vercel project
`goby-reports`); the dashboard is its root page. After adding or changing
storage or environment variables, redeploy so they take effect.

To try a deployment before releasing, run any goby build with
`GOBY_REPORT_URL=https://<your-project>.vercel.app/api/report`.
