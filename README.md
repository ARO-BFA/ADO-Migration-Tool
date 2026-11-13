# ADO Migration Tool

Copy an Azure DevOps work item **and all its child descendants** between projects,
including projects in different organizations or using different process templates.
The source is never edited or deleted. Destination items receive new IDs.

## Requirements

- Python 3.10+; only the standard library is used.
- Azure DevOps Services project URLs using `https://dev.azure.com/<org>/<project>`.
  Use project **names**, not project GUIDs. Azure DevOps Server and legacy
  `visualstudio.com` URLs are not supported.
- A source PAT with **Work Items: Read** and access to every source item.
- A destination PAT with **Work Items: Read & write**, permission to create/edit
  items and comments, and access to the destination area paths. Normal process
  rules are enforced; administrator/bypass-rules permissions are not required.

## Run

Set `ADO_SOURCE_PAT` and `ADO_DEST_PAT` in your environment using your secret
manager or a non-echoing shell prompt. Do not put PATs in the script, mapping
file, command-line arguments, or source control. The tokens may be the same if
one token has the required access to both projects.

First validate the entire hierarchy:

```sh
python3 migrate_work_item.py \
  --source 'https://dev.azure.com/OrgA/ProjA' \
  --destination 'https://dev.azure.com/OrgB/ProjB' \
  --id 12345 \
  --mapping mapping.example.json \
  --dry-run
```

Edit `mapping.example.json` for your actual templates and accounts first.
For identical templates, `--mapping` is optional.

Remove `--dry-run` to perform the copy:

```sh
python3 migrate_work_item.py \
  --source 'https://dev.azure.com/OrgA/ProjA' \
  --destination 'https://dev.azure.com/OrgB/ProjB' \
  --id 12345 \
  --mapping mapping.example.json \
  --checkpoint migration-state-12345.json
```

Progress and errors go to stderr. The JSON result on stdout maps source IDs to
destination IDs. Failures return a nonzero exit code. `--timeout` controls the
per-request timeout in seconds (default: 60).

Dry run reads all source items/comments and destination field metadata, then uses
Azure DevOps `validateOnly=true` to validate each proposed item. It creates no
work items, comments, attachments, links, or checkpoint files. It does **not**
download attachment content or validate attachment/comment writes or hierarchy
rules; these can still fail during the real run.

## Mapping different templates

All mapping sections are optional. Field names are Azure DevOps **reference
names**, not display labels.

| Section | Meaning |
| --- | --- |
| `work_item_types` | Source type to destination type. Unmapped types retain their names. |
| `fields` | Source field to destination field. Set a source field to `null` to explicitly omit it. |
| `states` | Source work item type to an object mapping source state to destination state. |
| `values` | Destination field to an object mapping stringified source values to replacement JSON values. A replacement of `null` omits the field. |
| `identities` | Source identity `uniqueName` (usually email) to destination identity. `null` omits that assignment. Unmapped identities retain their source names and must be valid in the destination. |
| `area_paths` | Exact source area path to an existing destination area path. |
| `iteration_paths` | Exact source iteration path to an existing destination iteration path. |
| `defaults` | Destination field values that **override** copied/mapped values. `null` removes a copied value so destination defaults/rules apply. |
| `type_defaults` | Destination work item type to an object of overrides, applied after `defaults`. |

Unmapped area and iteration paths use the **destination project root**, with a
progress message; paths are not created. Unmapped states/values are preserved.
Use `type_defaults` to supply required fields or an allowed initial state, for
example `"type_defaults": {"Product Backlog Item": {"System.State": "New"}}`.

Generated fields (IDs, audit identities/dates, history, reason, board fields) and
destination read-only fields are not copied as ordinary fields. An explicit
mapping can copy a generated **source** field into a writable custom destination
field, for example `"System.CreatedDate": "Custom.OriginalCreatedDate"`.
Unknown or unsupported writable fields fail preflight instead of being silently
discarded: rename them or explicitly map them to `null`. Multiple source fields
cannot map to the same destination field.

Mapping order: field rename/omit, identity/path/state mapping, `values`, `defaults`,
then `type_defaults`. Replacement values and overrides must use the destination's
expected field types. Required fields, allowed values, identities, paths, and
workflow rules are ultimately checked by Azure DevOps.

## What is copied

- Writable fields, including matching custom fields, descriptions, tags, and
  mapped assignments.
- Every descendant reached through a **Child** relation, with new parent/child
  links between the copied items. A child in another project or a repeated/cyclic
  hierarchy is rejected before persistent writes.
- Non-deleted comments, oldest first, using their rendered HTML when available.
  Each comment includes its original author, creation time, and source item URL
  as text. New comments are authored by the destination PAT's account at the
  migration time; original audit metadata is not impersonated.
- Attached files, preserving filenames and attachment comments. Absolute
  `https://dev.azure.com/.../_apis/wit/attachments/<uuid>` references in copied
  text fields/comments are also discovered and rewritten to destination uploads,
  including inline-only images. Each source attachment UUID is uploaded once per
  migration and attached to each item that uses it.

## Limitations

- This is a **copy**, not a move, synchronization, or revision-history replay.
  Original work item IDs, revisions, audit dates/authors, comment edit history,
  reactions, and mention semantics are not preserved.
- An external parent, Related links, hyperlinks, repository/build/PR links,
  test-suite membership, and other non-Child/non-attachment relations are not
  copied; skipped relation types are reported. Work item references inside text
  are not rewritten.
- Inline URL rewriting supports absolute `dev.azure.com` attachment API URLs.
  Relative, legacy-host, and other embedded resource URLs are not rewritten.
  Inline attachment links to other organizations remain unchanged and are
  reported. Other external images/resources are not downloaded.
- Attachments use simple upload and are buffered in memory, one at a time, with
  a 130 MiB limit. Destination policies may impose a lower limit. Chunked upload
  is not implemented. Downloads needing HTTP redirects fail explicitly; redirects
  are never followed with a PAT.
- There is no cross-item transaction or rollback. A failed run can leave partial
  items, comments, links, or unattached uploads. Requests are not automatically
  retried, including throttling responses, to avoid duplicating writes.
- Keep the source hierarchy, fields, comments, and mapping unchanged while
  migrating/resuming. The checkpoint binds to a hash of the source snapshot and
  mapping. Destination edits during migration are not reconciled.
- Run only one migration process per checkpoint. Use separate checkpoints for
  independent root items; overlapping roots with different checkpoints create
  separate copies. Protect mapping/checkpoint files as potentially sensitive
  project data.

## Resume and recovery

Rerun the same command with the **same checkpoint**. Completed uploads, item
creations, comments, and hierarchy links are skipped. The checkpoint contains
IDs/URLs, a snapshot hash, and operation status, not PATs or attachment content.
It is atomically replaced and written with owner-only permissions on POSIX.

Before every persistent HTTP write, a `pending` entry is saved. If the connection
fails or the process stops, the server may have applied the write even though
the client never received its response. A subsequent run **refuses to proceed**
with that uncertain operation instead of automatically duplicating it.

To recover, stop any migration process, back up the checkpoint, and inspect the
destination using the pending operation's URL, `section`, and `key`:

- If the operation definitely did **not** apply, set `pending` to `null`.
- If it **did** apply, record its result under the indicated section/key, then
  set `pending` to `null`:
  - `items`: source ID string to new destination ID (JSON integer).
  - `attachments`: source attachment UUID to uploaded destination attachment URL.
  - `comments`: `"sourceItemId:sourceCommentId"` to `true`.
  - `links`: append `"sourceParentId:sourceChildId"` to the list.

Only clear `pending` after verifying the outcome; otherwise duplicates are
possible. An interrupted upload whose URL cannot be recovered may leave an
orphaned blob; resolve/clean it up before retrying. If a local filesystem failure
left `<checkpoint>.tmp`, inspect it along with the main checkpoint before removing
that specific temporary file. Do not delete the main checkpoint to bypass an
error: doing so loses deduplication information.

## Tests

```sh
python3 -m unittest -v
```

Tests use mocked Azure DevOps responses and make no network calls. They cover
recursive copying, mappings, comment pagination, inline attachments, preflight,
dry runs, checkpoints/resume, and HTTP request/error behavior. A live end-to-end
migration requires your project URLs, PATs, and an appropriate test item.

## REST APIs

Uses Azure DevOps Work Item Tracking REST API 7.1 and Comments 7.1-preview.4:
[create/validate work items](https://learn.microsoft.com/en-us/rest/api/azure/devops/wit/work-items/create?view=azure-devops-rest-7.1),
[comments](https://learn.microsoft.com/en-us/rest/api/azure/devops/wit/comments/get-comments?view=azure-devops-rest-7.1),
and [attachments](https://learn.microsoft.com/en-us/rest/api/azure/devops/wit/attachments/create?view=azure-devops-rest-7.1).
