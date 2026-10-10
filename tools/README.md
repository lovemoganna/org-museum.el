# Chat knowledge pipeline

`museum_pipeline.py` is the shared entry for source validation, local preview,
Actions export and source-only save synchronization. Python 3.10+ and Emacs
27.1+ are required. The publisher checkout is pinned to a commit in the source
repository's workflow. Notes are data: batch export disables Babel evaluation.

```sh
python tools/museum_pipeline.py validate --root /path/to/org-notes
python tools/museum_pipeline.py build --root /path/to/org-notes --engine . --output /path/to/new-preview
python tools/museum_pipeline.py sync --root /path/to/org-notes
```

Build requires an absent output directory and preserves legacy HTML bytes.
Only pages/resources/assets and selected public site files enter its artifact;
source notes, credentials, configuration and private skills do not. New pages
live under `pages/collected/<kind>/<topic>/<stable-id>.html`. The generated
`museum-release.json` records source commit, note paths and content hashes;
each new page contains matching source-commit and note-hash metadata. A deploy
success alone is insufficient to claim that a specific note is visible.
The `verify --commit <source-sha>` command fetches the live receipt and pages,
checks those metadata values, and prints MUSEUM-PUBLISHED-RECEIPT only after
actual HTTP verification. Actions deploy logs expose this attestation to Chat
when its web tools cannot access Pages directly; failures never print success.

Source notes live in `notes/{programming,knowledge,reading,ideas}/<topic>/<id>.org`.
Required headers: TITLE, WIKI_ID (same as filename), CATEGORY, FILETAGS, DATE
(ISO date), SOURCE and INGEST_ID. Missing sources are stated explicitly. Never
put private material in a public draft. Raw active HTML and external export
directives are rejected. Code samples are retained and are not executed.

The private personal plugin in Org-Skills owns Chat routing and GitHub receipts.
It pins the two existing content skills; those skills are not in this public
repository. Chat must have GitHub read and write tools. This batch entry cannot
make unavailable Chat tools appear or replace real Chat acceptance testing.

Optional Emacs setup (after loading org-museum):

```elisp
(require 'org-museum-source-sync)
(setq org-museum-source-sync-root "/path/to/org-notes/"
      org-museum-source-sync-python "python")
(org-museum-source-sync-mode 1)
```

Only saves under notes/ and note-assets/ trigger the ten-second debounce.
The root must be main with an empty staging area and an Actions museum.json.
Synchronization uses an OS lock, fetches remote first, commits in an isolated
worktree, and pushes without force. Disjoint changes are merged; same-file
conflicts preserve local bytes. Saves during a push remain pending. Network
failures retry with backoff; permissions, invalid notes and conflicts halt
until `M-x org-museum-source-sync-now` is explicitly invoked. Pending saved
changes are recovered from Git when the mode starts again.

Loading the adapter blocks legacy HTML deployment to an Actions-owned target.
Existing org-roam/pages remains an independent source workspace. Do not use
its legacy HTML push to publish the new notes/ repository.

Validation:

```sh
python -m unittest discover -s test -p 'test_museum_pipeline*.py' -v
MUSEUM_TEST_LEGACY=/path/to/org-notes MUSEUM_TEST_EMACS=emacs python -m unittest discover -s test -p test_museum_pipeline_build.py -v
```

Git integration tests use actual temporary bare repositories, including
concurrent/disjoint writes, same-file conflict, repeated sync, offline recovery
and preservation of staged changes. A real pre-push hook advances the remote
after negotiation to verify that a rejected update preserves source changes
and succeeds after refetching. Local HTTP tests reject stale releases, missing
pages and mismatched content hashes instead of returning a published receipt.
These deterministic and Git/HTTP integration checks currently total 19 tests.
The optional real-site export regression
checks Chinese titles, attachments, legacy bytes and a Babel execution probe.

## Updating a published URL

Each newly built page now exposes its exact Git source through a `text/org`
alternate link, `museum-wiki-id` and `museum-source-path`. The release manifest
also includes the pinned raw source URL. Query strings and fragments describe
presentation state and never select a different note.

`museum_update.py resolve --root /path/to/org-notes --url <page> --output context.json`
checks the real page, release version and original tracked Org file, and returns
`operation: update`, its stable identity/path, the full Git source, and the
filtered published Org body separately. Run the existing private note-reforge
skill on the full source and save its candidate outside the source repository.
Neither existing content skill needs to change.

`museum_update.py update --root /path/to/org-notes --context context.json --candidate candidate.org --output submitted.json --wait 300`
preserves metadata spelling, references, anchors, existing heading names and
literal code, checks the latest target blob, and commits only the existing file.
Unrelated remote changes can be rebased safely; a same-file change stops the
update. A repeat with unchanged content reuses the source revision.

`museum_update.py status --root /path/to/org-notes --context submitted.json`
reports commit, Actions and verified Pages status separately. Success requires
the deployed HTTP attestation to match this note's ID, path and committed hash.
Declared Museum-Update commits can be checked in CI with `check-commit --base
<parent> --commit <head>`; creating a file or changing identity is rejected.

Clients without a working Pages TLS route can use `resolve --cloud` to execute
the same resolver in the read-only resolve-url.yml workflow. Chat clients can
read its `MUSEUM-URL-RESOLVED` evidence through connected GitHub tools. The normal
publish workflow also records these bindings after real HTTP verification.
Historical HTML with no verified Git source binding stops without creating or
renaming a note. Its filtered Org body is not a complete editable source.

The URL workflow adds 16 tests covering identity, historical metadata, missing
sources, literal code, references, stale pages, in-place/idempotent updates and
real same-file Git conflicts. A live regression updated python-sum-function at
its original path and verified the deployed note hash against the source blob.
Existing note-reforge and programming skill files were not modified.
Resolution failures emit MUSEUM-URL-FAILED with their exact stage and cause;
missing bindings and network failures never cause a replacement note to be made.
