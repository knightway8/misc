
Read CODEX-UBUNTU-README.txt completely. Inspect the repository, create a phased plan, and implement it through the
  definition of done. Preserve existing changes and use a disposable development database for testing.




CHESSCHAN UBUNTU CODEX IMPLEMENTATION HANDOFF
=============================================

Purpose
-------

This file is a self-contained implementation brief for Codex working on the
Rust Chesschan repository on Ubuntu. Read this entire file before changing any
code. Treat the architectural decision below as accepted unless inspection of
the repository reveals a concrete safety or correctness conflict.

The goal is to make Chesschan exceptionally fast for readers while retaining
durable posting, straightforward crash recovery, and a documented path for
moving the site to a replacement VPS.

This is an implementation project, not another language/database comparison.
The production direction is:

  * Rust remains the application language.
  * PostgreSQL remains the authoritative source of truth.
  * Public read pages become generated static HTML.
  * Posting, CAPTCHA, reporting, and moderation remain dynamic Rust routes.
  * Nginx serves generated HTML and static assets.
  * A CDN may cache public HTML, thumbnails, uploads, CSS, and JavaScript.
  * PostgreSQL backups/PITR, off-site uploads, and restore drills provide
    disaster recovery.

Do not replace PostgreSQL with a homemade flat-file database. Generated HTML
is intentionally flat-file output, but it is disposable and rebuildable from
PostgreSQL.


How to use this handoff
-----------------------

1. Put this file in the root of the Rust Chesschan repository.
2. Ask Codex to read it completely and implement the plan in reviewable phases.
3. Keep this file as a decision record until the work and recovery drill are
   complete.
4. If the working tree already has changes, preserve them. Do not reset,
   discard, or overwrite unrelated user work.


Required first actions
----------------------

Before editing:

  1. Read any AGENTS.md files that apply to the repository.
  2. Inspect git status and identify existing user changes.
  3. Read at least:

       Cargo.toml
       README.md
       AI-README.md
       PRODUCTION.md
       HARDENING.md
       LINUX-OPERATIONS.md
       config.toml
       src/main.rs
       src/app_router.rs
       src/archive.rs
       src/http_security.rs
       src/upload_reconcile.rs
       src/handlers/public_board.rs
       src/handlers/moderator.rs
       src/db/core.rs
       src/db/posts.rs
       src/db/moderation.rs
       src/db/archive.rs
       src/db/schema.rs
       templates/home.html
       templates/board.html
       templates/thread.html
       backup-db.sh
       backup-site.sh
       restore-db.sh
       restore-site.sh

  4. Find every route that creates, edits, approves, deletes, pins, locks,
     archives, restores, renames, opens, closes, or otherwise changes public
     content.
  5. Find every place that reads or writes uploads and every template that
     displays an upload.
  6. Run the existing test suite and record the baseline result.
  7. Create a concise implementation plan before editing. At most one plan
     step should be in progress at a time.

Never run development reset commands against an uncertain database. Confirm
that DATABASE_URL points to a disposable development/test database before any
test that mutates or resets data.


Known current architecture
--------------------------

Verify these facts instead of assuming they are still current:

  * The application uses Axum, Tokio, SQLx, Askama, and PostgreSQL.
  * AppState has a PostgreSQL pool and an installation/database instance lock.
  * One Chesschan application instance is intentionally allowed per database.
  * Public active boards and threads are currently rendered dynamically.
  * Archived threads are already rendered as static HTML.
  * src/archive.rs already contains a strong atomic publication implementation:
    temporary creation, write, flush, file sync, rename, and directory sync.
  * Full archive rebuilds use staging/replacement directories.
  * Board templates currently use the original upload URL as both the preview
    image and original link. This can make a visually small image download the
    full multi-megabyte original.
  * backup-site.sh safely packages PostgreSQL, uploads, and site content while
    the app is stopped so they represent one consistent state.
  * Existing production documentation and safety invariants must be preserved.


Non-negotiable properties
-------------------------

The completed design must satisfy all of these:

  * PostgreSQL is authoritative. Static HTML is never the only copy of a post.
  * Anonymous reads of a successfully generated page do not start Rust and do
    not query PostgreSQL.
  * Static pages never contain CSRF tokens, CAPTCHA state, session identifiers,
    moderator-only controls, private board data, pending posts, or secrets.
  * A committed post cannot be permanently omitted merely because publishing
    or CDN invalidation failed.
  * Publication is idempotent and safe to retry after a crash at any step.
  * No request can observe a partially written HTML page.
  * Existing public URLs remain compatible. Do not casually introduce .html
    suffixes into canonical active-board URLs.
  * Existing posts and uploads remain valid through migrations.
  * Originals are preserved. Thumbnails are generated derivatives.
  * Moderator and compose responses are private/no-store and can never be
    placed in a public CDN cache.
  * Upload directories cannot execute scripts and generated paths cannot escape
    their configured roots.
  * A full static rebuild can be run after a restore or template change.
  * Failure of a cache purge must never roll back or lose an accepted post.
  * The site must degrade to readable static pages when Rust or PostgreSQL is
    temporarily unavailable.


Target request architecture
---------------------------

Read path:

  Browser -> CDN cache -> Nginx -> generated HTML/thumbnail/static asset

On a CDN hit, the request does not reach the VPS. On an Nginx static hit, the
request does not reach Rust. A generated-file miss may fall back to a safe
read-only Rust handler while a repair/rebuild is scheduled.

Write path:

  Static page Reply/New Thread link
      -> dynamic Rust compose page
      -> CSRF/CAPTCHA/session validation
      -> PostgreSQL transaction
           - insert/update authoritative state
           - enqueue/coalesce publication work in the same transaction
      -> commit
      -> render affected public pages from committed PostgreSQL state
      -> atomic file publication
      -> best-effort exact CDN purge
      -> 303 redirect to static thread and post anchor

Expected public/dynamic split:

  Public/generated:
    home
    visible board indexes and pagination
    active threads
    all-board view if it currently exists
    archives
    public CSS/JavaScript
    public thumbnails and original uploads

  Dynamic and never publicly cached:
    new-thread compose page
    reply compose page
    form submissions
    CAPTCHA creation/validation
    report page and submission
    moderator login and all moderator routes
    health checks
    publishing/maintenance diagnostics

Preserve current route semantics where possible. The public static page may
contain New Thread and Reply links, but the actual form must live on a dynamic
compose route. A no-JavaScript workflow is required. JavaScript may later load
the same compose page into a modal, but the standalone form remains canonical.


Implementation phase 0: establish safety and measurements
---------------------------------------------------------

Before changing behavior:

  * Run cargo fmt --check.
  * Run cargo check.
  * Run cargo clippy for all relevant targets/features with warnings denied if
    the existing project is clean under that policy.
  * Run cargo test.
  * Run any documented integration checks against a disposable PostgreSQL DB.
  * Record representative response size and origin latency for home, a board,
    a thread, an image, and a post operation.
  * Record total transferred bytes for a board containing several uploads.
  * Confirm the existing backup and restore documentation matches the scripts.

Do not claim performance improvements without measuring the completed paths.
Keep load tests away from production.


Implementation phase 1: real thumbnails and page-weight control
---------------------------------------------------------------

This is the highest-priority visible performance improvement.

Requirements:

  * Generate a bounded preview image when an upload is accepted.
  * Preserve the validated original under its generated immutable name.
  * Strip unnecessary metadata from generated previews.
  * Respect existing maximum dimensions and pixel-count protections before
    expensive decoding.
  * Set decoder memory/dimension limits. Treat image decoding as hostile input.
  * Decide and document behavior for animated GIF/WebP files. A still preview
    is acceptable if the original remains accessible.
  * Use a deterministic, non-user-controlled thumbnail path.
  * Store dimensions needed to emit width and height attributes, either in
    PostgreSQL or in a safely derived metadata record.
  * Board, thread, and archive templates must load the thumbnail in img src and
    link to the original.
  * Use loading=lazy where appropriate, but do not rely on lazy loading as a
    substitute for thumbnails.
  * Existing uploads need an idempotent backfill/reconciliation command.
  * If a thumbnail is temporarily missing, degrade safely to a placeholder or
    carefully chosen fallback and enqueue regeneration. Do not break the page.
  * Moderator image replacement and deletion must handle both original and
    derivative files.
  * Backup/restore/reconciliation documentation must account for thumbnails.

Choose the image implementation only after reviewing existing upload
validation. Prefer a maintained library and the smallest safe operational
surface. Do not shell out using user-controlled filenames or arguments.

Cache policy:

  * UUID/content-versioned uploads and thumbnails can receive long public cache
    lifetimes because replacements receive new names.
  * Only use the immutable directive for URLs that truly cannot change.
  * Existing non-fingerprinted CSS/JavaScript must not receive a one-year
    immutable policy until URLs are fingerprinted or versioned.

Required tests:

  * Valid JPEG, PNG, GIF, and WebP behavior supported by the existing app.
  * Extreme dimension and pixel-count rejection.
  * Malformed/truncated data rejection.
  * Existing upload backfill.
  * Thumbnail/original deletion and moderator replacement.
  * Templates use the thumbnail URL and retain an original link.
  * Generated width/height are correct and cannot cause HTML injection.


Implementation phase 2: separate dynamic compose routes
-------------------------------------------------------

Refactor public rendering so read pages are universal and cache-safe.

Requirements:

  * Add clear routes for new-thread and reply compose pages.
  * Move CAPTCHA creation, CSRF fields, board passwords, and any per-session
    values into those dynamic pages.
  * Static board/thread pages contain only links or buttons to compose pages.
  * Keep existing POST endpoints compatible unless a carefully documented
    migration is required.
  * Validate the board/thread relationship again on POST. Never trust URL/form
    identifiers solely because the compose page generated them.
  * Use Post/Redirect/Get with HTTP 303 after a successful publication.
  * Redirect to the thread plus #p<post-id> anchor.
  * Dynamic compose, report, login, and moderator responses must send private,
    no-store caching headers.
  * Anonymous static GETs must not create sessions or Set-Cookie headers.
  * Moderator controls should live in the moderator interface. Do not make
    public cache contents vary by moderator cookies.

CSRF and CAPTCHA solve different problems. Keep both protections where the
existing security model requires them. Rate limiting must remain based on a
trustworthy client-IP path and server state; do not replace it with a
client-controlled cookie.

Required tests:

  * Static read output contains no CSRF/CAPTCHA/session values.
  * Compose GET produces valid fresh protection state.
  * Replayed/invalid tokens are rejected as required by the existing design.
  * Posting to the wrong board/thread is rejected.
  * Locked, archived, closed, approval, and password board behavior remains
    correct.
  * Moderator authentication never alters a cached public representation.


Implementation phase 3: active public-page publisher
----------------------------------------------------

Generalize or extend the proven archive publisher instead of writing a weaker
second atomic-write implementation.

Recommended generated layout:

  Use one dedicated generated-public root that cannot overlap source, uploads,
  archive input, backups, secrets, or arbitrary configured paths. Preserve
  friendly canonical URLs through Nginx mapping. The exact on-disk layout may
  be selected after inspecting existing routes, but it must support:

    /
    /<board>
    /<board>?page=N or an equivalent existing pagination URL
    /<board>/thread/<id>
    /all if currently supported

Do not expose temporary or staging files through Nginx.

Publisher requirements:

  * Reuse temporary create-new files, write_all, flush, sync_all, atomic rename,
    and parent-directory sync on Unix.
  * A whole-site rebuild uses an isolated staging tree and atomic/safe swap with
    rollback to the previous tree if publication fails.
  * Rendering always queries committed PostgreSQL state.
  * Filesystem work does not occur while holding a long PostgreSQL transaction.
  * Rendering is idempotent.
  * Every generated path is derived from validated database identifiers, never
    raw request paths.
  * Removed/renamed/closed boards and deleted/archived/restored threads clean up
    or replace obsolete public files safely.
  * Hidden, closed, pending, rejected, and deleted material cannot leak.
  * Template failures leave the previous complete public file in place.
  * A CLI/admin command can rebuild all public output after restore or template
    changes.
  * Startup detects missing output and schedules repair without exposing partial
    state.

Build and document an invalidation dependency map. At minimum inspect these
events:

  * new approved thread
  * new approved reply
  * pending-post approval/rejection
  * post/thread deletion
  * post edit and image replacement/removal
  * pin/unpin
  * lock/unlock
  * archive/restore and automatic archive-depth enforcement
  * board creation, ordering, visibility, name/description, slug alias, posting
    mode, closure, and deletion where allowed
  * template/theme/navigation changes

For each event define exactly which of these must be regenerated or removed:

  * thread page
  * current and affected board-index pages
  * home page
  * all-board page if present
  * archive index/thread page
  * old slug path and permanent redirect/alias behavior

Required tests:

  * Static output matches dynamic public content for representative fixtures.
  * HTML escaping and URL encoding prevent stored XSS.
  * A killed/failed render never exposes a partial file.
  * Concurrent writes cannot let an older render replace a newer render.
  * Full rebuild failure retains the last good public tree.
  * Board rename/archive/restore/delete operations update all affected paths.
  * Hidden/pending/moderator data is absent from generated output.


Implementation phase 4: transactional publication jobs and retry
----------------------------------------------------------------

The database commit and filesystem publication cannot be one atomic operation.
Use a transactional outbox/publication-job design to bridge them.

Requirements:

  * The PostgreSQL transaction that changes public state also inserts or
    coalesces the required publication job(s).
  * Jobs have enough information to determine the affected resources without
    storing trusted rendered HTML in PostgreSQL.
  * Coalesce repeated work by resource so a posting burst renders the latest
    state rather than every intermediate state.
  * Claim jobs safely so two workers cannot publish the same resource out of
    order. PostgreSQL row locking/advisory locking may be used deliberately.
  * Record attempts, timestamps, and a bounded diagnostic message.
  * Retry transient failures with bounded backoff.
  * Persistent failure is visible through logs/health/diagnostics and does not
    silently discard work.
  * Startup drains outstanding jobs.
  * A crash after commit but before render is recovered by the queued job.
  * A crash after render but before marking completion causes a harmless retry.
  * Job completion occurs only after durable atomic file publication.
  * CDN purge is best effort and separately retryable; it is not a condition for
    database durability.

Initially, one in-process publisher is acceptable because Chesschan already
enforces one application instance. Do not remove the global instance lock merely
to claim horizontal scaling. Multiple app instances require shared rate limits,
shared sessions where applicable, shared/object upload storage, and coordinated
publication. Document that as a later measured scaling step.

User-visible failure behavior:

  * The common path may publish synchronously after commit and then redirect.
  * If committed publication fails or exceeds a short bound, do not return an
    error implying the post was rejected. Return a clear accepted/publishing
    response or redirect to a safe receipt page while the job retries.
  * Never ask the user to resubmit a post that has already committed.

Required tests should deliberately inject failure at each boundary:

  * before DB commit
  * after DB commit/before job processing
  * during template rendering
  * during temporary-file writing
  * after temporary-file sync/before rename
  * after rename/before job completion
  * during CDN purge


Implementation phase 5: Nginx and CDN integration
-------------------------------------------------

Add production examples and documentation, not hidden assumptions.

Nginx requirements:

  * Serve the dedicated generated-public root before proxying to Rust.
  * Preserve existing friendly public URLs.
  * Never serve dotfiles, temporary files, staging trees, backups, .env,
    database files, source, or internal manifests.
  * Serve uploads only from the validated upload roots and never execute them.
  * Route compose/report/moderator/health/POST requests to Rust.
  * Set correct content types, security headers, compression, and cache headers.
  * Add a safe Rust fallback for missing generated pages if the design retains
    one; the fallback must be cache-safe and must schedule repair.
  * Keep Rust bound to loopback as required by existing production policy.

CDN requirements:

  * Provider integration is optional and disabled by default.
  * Do not hard-code provider credentials or commit tokens.
  * Cache public HTML only under explicit route rules.
  * Bypass compose, report, moderator, health, and all non-GET/HEAD routes.
  * Never cache responses containing Set-Cookie or private/no-store directives.
  * Purge exact affected public URLs after successful publication.
  * Purge failures are logged and retried without losing posts.
  * Use short HTML edge freshness plus purge until production behavior is
    proven. Long-lived stale HTML is not an acceptable substitute for correct
    invalidation.
  * Consider stale-if-error/read-only continuity for public pages, with a clear
    maximum stale policy.
  * Document cache-deception and cache-poisoning protections.

If implementing a Cloudflare purger, put it behind a small interface with a
no-op implementation. Read API token and zone configuration only from protected
environment variables. Unit-test URL selection without making network calls.


Implementation phase 6: backup, restore, and replacement-VPS recovery
---------------------------------------------------------------------

PostgreSQL alone does not back up uploads, secrets, source, or configuration.
The recovery design owns all of them explicitly.

Authoritative recovery set:

  1. PostgreSQL data.
  2. Original uploads. Thumbnails are rebuildable but may also be backed up.
  3. TRIPCODE_SECRET and required production environment/configuration.
  4. Pinned source/release artifact, templates, static assets, systemd unit, and
     Nginx configuration.

Generated public HTML is rebuildable output. It may be retained for immediate
read-only continuity, but it must never be the only backup of content.

Keep the existing safe stopped full-site backup. Add or document an online
strategy appropriate to the deployment:

  * Continuous PostgreSQL WAL archiving or managed PostgreSQL point-in-time
    recovery for a low recovery-point objective.
  * A daily portable custom-format pg_dump copied off the VPS.
  * Versioned object storage for uploads, or immediate verified off-site upload
    replication.
  * A separate encrypted backup of secrets. Never place production secrets in
    ordinary site archives or source control.
  * Multiple daily, weekly, and monthly generations.
  * Checksums and non-empty backup verification.
  * Monitoring/alerting for backup, WAL archive, disk, and upload-sync failures.

Be precise about cross-resource consistency. One safe object lifecycle is:

  1. Validate and durably store an upload under a unique immutable key.
  2. Commit the PostgreSQL row referencing that key.
  3. Reconcile/delete unreferenced objects after a conservative grace period.

This permits database and versioned object storage recovery without pretending
they share one filesystem transaction.

Restore/replacement-VPS procedure must be executable and tested:

  1. Provision clean Ubuntu.
  2. Install Nginx and PostgreSQL or configure the managed DB client/network.
  3. Deploy the pinned Chesschan release and production service files.
  4. Restore PostgreSQL using PITR or the newest verified pg_dump.
  5. Restore protected configuration and TRIPCODE_SECRET.
  6. Restore/reconnect uploads and run upload reconciliation.
  7. Rebuild thumbnails if needed.
  8. Rebuild the entire generated public tree in staging.
  9. Atomically publish generated output.
 10. Start the service and verify /healthz, a representative read, a controlled
     test post, logs, and publication queue health.
 11. Switch CDN origin or DNS only after validation.

Add an automated restore-verification script where practical. It must restore
into a disposable database/directory, run integrity/application checks, verify
representative rows/uploads, and clean up only its explicitly created targets.
It must never point at production by default.

A backup is not considered working until a restore test succeeds.


Implementation phase 7: observability, load tests, and failure tests
-------------------------------------------------------------------

Add enough visibility to distinguish a fast static site from a silently stale
one.

Track/log at minimum:

  * request errors with existing reference-ID behavior
  * dynamic request latency by route category
  * PostgreSQL pool acquisition failures/timeouts
  * queued publication job count and oldest age
  * render duration and failure count
  * last successful full rebuild
  * CDN purge attempts/failures if enabled
  * upload thumbnail/backfill/reconciliation failures
  * backup age and restore-verification result through operational monitoring
  * available disk space for PostgreSQL, uploads, generated trees, logs, and
    backup staging

Load-test separately:

  * CDN/static GET throughput and latency
  * Nginx-origin static GET throughput and latency
  * dynamic compose GETs
  * successful and rejected posting
  * simultaneous replies to one thread
  * simultaneous new threads and archive-depth enforcement
  * moderation during posting
  * publisher coalescing under a burst

Do not benchmark with durability disabled and call the result production
performance. Keep PostgreSQL fsync/durability semantics representative of the
real deployment.

Test degraded modes:

  * Rust stopped: generated reads still work.
  * PostgreSQL stopped: generated reads still work; dynamic writes fail with a
    controlled maintenance response.
  * Publisher unwritable/full disk: old complete pages remain, jobs stay queued,
    and operators see a clear alert.
  * CDN purge unavailable: origin is correct, purge retries, and bounded TTL
    limits stale content.
  * VPS loss: documented restore onto a clean system succeeds.

Measure browser experience with PageSpeed/Lighthouse and real-user Web Vitals
after deployment. Optimize total page weight and image bytes before chasing
microseconds in Rust or PostgreSQL.


Security requirements that must survive the refactor
----------------------------------------------------

  * Preserve all existing authentication, CSRF, CAPTCHA, tripcode, upload,
    board-mode, moderation-audit, approval, and rate-limit protections.
  * Continue prepared/parameterized SQL and transactional invariants.
  * Escape all user content during every static render.
  * Do not render raw HTML from posts.
  * Reject path traversal, symlinks where unsafe, and output-root overlap.
  * Do not trust forwarding headers unless requests can only arrive through the
    configured trusted proxy that overwrites them.
  * Keep moderator cookies secure, HttpOnly, and appropriately SameSite.
  * Do not expose detailed internal errors to public users.
  * Avoid cache variation based on attacker-controlled headers unless the cache
    key is deliberately configured and tested.
  * Make it impossible for cached public pages to contain moderator or private
    response content.
  * Keep health endpoints minimal and non-sensitive.


Compatibility and migration rules
---------------------------------

  * Use recorded, transactional PostgreSQL schema migrations consistent with
    the repository's current migration system.
  * Never edit an applied migration in a way that silently changes its meaning.
  * Backfill existing data idempotently.
  * Preserve existing board aliases and canonical links.
  * Preserve archived content and current moderation semantics.
  * Avoid breaking CSS themes, reading preferences, image visibility controls,
    long posts, tripcodes, reports, approval boards, password boards, and closed
    boards.
  * Keep a dynamic/read-only fallback until generated-page behavior and Nginx
    routing have been verified in staging.
  * Provide rollback instructions for each deployment phase. A rollback must not
    require deleting authoritative posts created after deployment.


Expected deliverables
---------------------

Code:

  * Secure thumbnail generation, use, reconciliation, and tests.
  * Dynamic compose routes with cache-safe public read templates.
  * Active-page publisher built on the proven atomic publication primitives.
  * Transactional publication jobs with coalescing, retry, and diagnostics.
  * Full public rebuild command.
  * Safe cleanup/invalidation for every public mutation.
  * Optional provider-neutral CDN purge interface.

Operations:

  * Example hardened Nginx configuration for generated-first routing.
  * systemd/service documentation if changes are required.
  * Cache policy and optional CDN configuration guide.
  * Updated production, backup, restore, and Linux operations documentation.
  * Replacement-VPS runbook.
  * Restore-verification procedure/script.
  * Load-test and failure-test instructions that cannot target production by
    accident.

Verification evidence:

  * Formatting, checks, Clippy, tests, and integration test results.
  * Representative generated-file inspection.
  * Proof that static GETs do not hit Rust/PostgreSQL.
  * Before/after board-page transferred bytes using several images.
  * Origin static-read load-test result.
  * Posting/concurrency test result.
  * Injected publisher-failure/retry result.
  * Successful clean restore drill result or an explicit, bounded reason why a
    real infrastructure restore requires operator credentials.


Definition of done
------------------

The project is complete only when all of the following are true:

  [ ] Public home/board/thread/archive reads are generated and served statically.
  [ ] Posting and moderation remain correct under the existing board modes.
  [ ] Compose pages provide CSRF/CAPTCHA/session protection dynamically.
  [ ] Static HTML contains no visitor-specific or moderator-specific data.
  [ ] Board/thread pages use optimized thumbnails, not full originals.
  [ ] Every public mutation has a tested invalidation/publication path.
  [ ] Publication jobs recover from crashes and are observable.
  [ ] Partial HTML cannot become public.
  [ ] Nginx routing and cache headers are documented and tested.
  [ ] CDN caching, if enabled, bypasses every private route and can be purged.
  [ ] PostgreSQL, uploads, secrets, and deployment artifacts are backed up
      off-site according to the documented policy.
  [ ] A clean replacement-VPS restore has been tested.
  [ ] cargo fmt/check/clippy/test and integration checks pass.
  [ ] Existing unrelated user changes remain intact.


Final architectural reminder
----------------------------

Do not optimize the wrong boundary.

  * CDN and Nginx make anonymous reads fast.
  * Thumbnails make pages fast on real mobile connections.
  * Rust makes the dynamic origin efficient and predictable.
  * PostgreSQL makes concurrent authoritative state durable and recoverable.
  * Publication jobs make database-to-filesystem updates eventually reliable.
  * Off-site backups and tested restores make server failure survivable.

PostgreSQL alone does not create a fast website, and static HTML alone does not
create a recoverable website. The accepted design deliberately uses both.

