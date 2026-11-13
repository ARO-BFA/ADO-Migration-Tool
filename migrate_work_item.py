#!/usr/bin/env python3
"""Copy an Azure DevOps work item and its descendants without changing the source."""

import argparse
import base64
import hashlib
import html
import json
import os
import re
import sys
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, unquote, urlencode, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

API_VERSION = "7.1"
COMMENTS_VERSION = "7.1-preview.4"
MAX_ATTACHMENT_BYTES = 130 * 1024 * 1024
CHILD = "System.LinkTypes.Hierarchy-Forward"
GENERATED_FIELDS = {
    "System.Id", "System.Rev", "System.WorkItemType", "System.TeamProject",
    "System.CreatedBy", "System.CreatedDate", "System.ChangedBy",
    "System.ChangedDate", "System.AuthorizedAs", "System.AuthorizedDate",
    "System.RevisedDate", "System.Watermark", "System.History", "System.Reason",
    "System.BoardColumn", "System.BoardColumnDone", "System.BoardLane",
}
ATTACHMENT_PATTERN = re.compile(
    r"https://dev\.azure\.com/[^\s<>\"')]+/_apis/wit/attachments/"
    r"[0-9a-fA-F-]{36}(?:\?[^\s<>\"')]+)?", re.IGNORECASE
)
Json = dict[str, Any]


class MigrationError(Exception):
    """An actionable migration failure."""


def notice(message: str) -> None:
    print(message, file=sys.stderr)


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Never forward a PAT to a redirect target.
        return None


class Client:
    def __init__(self, project_url: str, pat: str, timeout: float = 60):
        parts = urlsplit(project_url)
        segments = [unquote(p) for p in parts.path.strip("/").split("/")]
        if (
            parts.scheme != "https" or parts.netloc.lower() != "dev.azure.com"
            or parts.query or parts.fragment or len(segments) != 2
            or any(not p or "/" in p or p in {".", ".."} for p in segments)
        ):
            raise MigrationError("Use a project URL: https://dev.azure.com/<org>/<project>")
        self.org, self.project = segments
        self.base = "https://dev.azure.com/" + "/".join(quote(p, safe="") for p in segments)
        self.authorization = "Basic " + base64.b64encode((":" + pat).encode()).decode()
        self.timeout = timeout
        self.opener = build_opener(NoRedirects())

    def api(self, path: str) -> str:
        return self.base + "/_apis/wit/" + path

    def check_url(self, url: str) -> None:
        parts = urlsplit(url)
        org = unquote(parts.path.strip("/").split("/")[0])
        if (
            parts.scheme != "https" or parts.netloc.lower() != "dev.azure.com"
            or org.casefold() != self.org.casefold() or parts.fragment
        ):
            raise MigrationError(f"Refusing to send credentials outside organization {self.org}")

    def request(
        self, method: str, url: str, *, payload: Any = None,
        query: Json | None = None, patch: bool = False,
        binary: bytes | None = None, download: bool = False,
    ) -> Any:
        self.check_url(url)
        parts = urlsplit(url)
        params = parse_qs(parts.query)
        params.setdefault("api-version", [API_VERSION])
        for key, value in (query or {}).items():
            params[key] = [str(value)]
        url = urlunsplit(parts._replace(query=urlencode(params, doseq=True)))
        headers = {"Authorization": self.authorization, "Accept": "application/json"}
        data = binary
        if binary is not None:
            headers["Content-Type"] = "application/octet-stream"
        elif payload is not None:
            data = json.dumps(payload).encode()
            headers["Content-Type"] = (
                "application/json-patch+json" if patch else "application/json"
            )
        request = Request(url, data=data, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                body = response.read(MAX_ATTACHMENT_BYTES + 1) if download else response.read()
                if download:
                    if len(body) > MAX_ATTACHMENT_BYTES:
                        raise MigrationError("Attachment exceeds the 130 MiB simple-upload limit")
                    return body
                return json.loads(body) if body else {}
        except HTTPError as exc:
            detail = exc.read(8192).decode("utf-8", errors="replace")
            raise MigrationError(f"{method} failed (HTTP {exc.code}): {detail}") from exc
        except (URLError, TimeoutError, OSError) as exc:
            raise MigrationError(f"{method} request failed: {exc}") from exc
        except (ValueError, UnicodeError) as exc:
            raise MigrationError(f"{method} returned invalid JSON: {exc}") from exc

    def get(self, path: str, **query: Any) -> Any:
        return self.request("GET", self.api(path), query=query)

    def comments(self, item_id: int) -> list[Json]:
        result: list[Json] = []
        token = None
        seen: set[str] = set()
        while True:
            query = {
                "api-version": COMMENTS_VERSION, "$top": 200,
                "order": "asc", "includeDeleted": "false", "$expand": "renderedText",
            }
            if token is not None:
                query["continuationToken"] = token
            page = self.get(f"workitems/{item_id}/comments", **query)
            result.extend(c for c in page.get("comments", []) if not c.get("isDeleted"))
            token = page.get("continuationToken")
            if not token:
                return result
            if str(token) in seen:
                raise MigrationError("Comments API returned a repeated continuation token")
            seen.add(str(token))


def load_mapping(path: Path | None) -> Json:
    mapping = json.loads(path.read_text(encoding="utf-8")) if path else {}
    sections = {
        "work_item_types", "fields", "values", "states", "identities",
        "area_paths", "iteration_paths", "defaults", "type_defaults",
    }
    if not isinstance(mapping, dict) or set(mapping) - sections:
        raise MigrationError("Mapping must be an object containing only documented sections")
    for section, entries in mapping.items():
        if not isinstance(entries, dict):
            raise MigrationError(f"Mapping section {section} must be an object")
        if section in {"values", "states", "type_defaults"}:
            if any(not isinstance(value, dict) for value in entries.values()):
                raise MigrationError(f"Mapping section {section} must contain objects")
        elif section != "defaults":
            for value in entries.values():
                nullable = section in {"fields", "identities"}
                if not (isinstance(value, str) and value) and not (nullable and value is None):
                    raise MigrationError(f"Invalid value in mapping section {section}")
    return mapping


def field_patch(fields: Json) -> list[Json]:
    return [
        {"op": "add", "path": "/fields/" + name.replace("~", "~0").replace("/", "~1"),
         "value": value}
        for name, value in fields.items()
    ]


def mapped_fields(
    item: Json, mapping: Json, definitions: Json, allowed: set[str], target_project: str,
) -> tuple[str, Json]:
    source_type = item["fields"]["System.WorkItemType"]
    target_type = mapping.get("work_item_types", {}).get(source_type, source_type)
    renames = mapping.get("fields", {})
    fields: Json = {}
    for source_name, value in item["fields"].items():
        name = renames.get(source_name, source_name)
        if name is None or value is None:
            continue
        if source_name in GENERATED_FIELDS and source_name not in renames:
            continue
        definition = definitions.get(name)
        if definition and definition.get("readOnly") and source_name not in renames:
            notice(f"Item {item['id']}: skipping read-only field {source_name}")
            continue
        if name not in allowed or not definition:
            raise MigrationError(
                f"Item {item['id']}: {source_name} -> {name} is not in {target_type}; "
                'map it to a destination field or explicitly set its fields mapping to null'
            )
        if definition.get("readOnly") or name in GENERATED_FIELDS:
            raise MigrationError(f"Cannot write generated/read-only destination field {name}")
        if name in fields:
            raise MigrationError(f"Multiple source fields map to {name}")
        if definition.get("isIdentity"):
            if isinstance(value, dict):
                value = value.get("uniqueName")
                if not value:
                    raise MigrationError(f"Identity in {source_name} has no uniqueName")
            value = mapping.get("identities", {}).get(str(value), value)
            if value is None:
                continue
        if name in {"System.AreaPath", "System.IterationPath"}:
            section = "area_paths" if name == "System.AreaPath" else "iteration_paths"
            mapped = mapping.get(section, {}).get(str(value), target_project)
            if mapped != value:
                notice(f"Item {item['id']}: {name}: {value} -> {mapped}")
            value = mapped
        if name == "System.State":
            value = mapping.get("states", {}).get(source_type, {}).get(str(value), value)
        value = mapping.get("values", {}).get(name, {}).get(str(value), value)
        if value is not None:
            fields[name] = value
    overrides = dict(mapping.get("defaults", {}))
    overrides.update(mapping.get("type_defaults", {}).get(target_type, {}))
    for name, value in overrides.items():
        if (
            name not in allowed or name not in definitions
            or definitions[name].get("readOnly") or name in GENERATED_FIELDS
        ):
            raise MigrationError(f"Invalid default destination field {name} for {target_type}")
        if value is None:
            fields.pop(name, None)
        else:
            fields[name] = value
    return target_type, fields


def attachment_key(client: Client, url: str) -> str:
    url = html.unescape(url)
    client.check_url(url)
    parts = urlsplit(url)
    if not re.search(r"/_apis/wit/attachments/[0-9a-fA-F-]{36}$", parts.path, re.I):
        raise MigrationError(f"Not an Azure DevOps attachment URL: {url}")
    return parts.path.rsplit("/", 1)[-1].lower()


def collect(source: Client, root_id: int) -> list[Json]:
    items: list[Json] = []
    pending = [root_id]
    seen: set[int] = set()
    while pending:
        item_id = pending.pop()
        if item_id in seen:
            raise MigrationError(f"Repeated child {item_id}: source hierarchy is not a tree")
        seen.add(item_id)
        item = source.get(f"workitems/{item_id}", **{"$expand": "relations"})
        if item["fields"]["System.TeamProject"].casefold() != source.project.casefold():
            raise MigrationError(f"Child {item_id} is outside source project {source.project}")
        item["migration_comments"] = source.comments(item_id)
        children = []
        for relation in item.get("relations", []):
            if relation["rel"] == CHILD:
                source.check_url(relation["url"])
                match = re.search(r"/_apis/wit/workitems/([0-9]+)$",
                                  urlsplit(relation["url"]).path, re.I)
                if not match:
                    raise MigrationError(f"Invalid child URL: {relation['url']}")
                children.append(int(match[1]))
            elif relation["rel"] != "AttachedFile":
                notice(f"Item {item_id}: not copying relation {relation['rel']}")
        item["migration_children"] = children
        items.append(item)
        pending.extend(reversed(children))
    return items


def attachments_for(source: Client, item: Json, fields: Json) -> Json:
    attachments: Json = {}
    for relation in item.get("relations", []):
        if relation["rel"] == "AttachedFile":
            url = relation["url"]
            key = attachment_key(source, url)
            attrs = relation.get("attributes", {})
            attachments[key] = {
                "url": url, "name": attrs.get("name", key),
                "comment": attrs.get("comment", ""),
            }
    texts = [value for value in fields.values() if isinstance(value, str)]
    for comment in item["migration_comments"]:
        texts.extend([comment.get("text", ""), comment.get("renderedText", "")])
    for text in texts:
        for match in ATTACHMENT_PATTERN.finditer(text):
            url = html.unescape(match[0])
            # External organization links remain links; they are not downloaded.
            if unquote(urlsplit(url).path.split("/")[1]).casefold() != source.org.casefold():
                notice(f"Item {item['id']}: leaving external attachment URL unchanged")
                continue
            key = attachment_key(source, url)
            name = parse_qs(urlsplit(url).query).get("fileName", [key])[0]
            attachments.setdefault(key, {"url": url, "name": name, "comment": ""})
    return attachments


def rewrite_attachments(text: str, replacements: Json) -> str:
    def replace(match: re.Match[str]) -> str:
        original = html.unescape(match[0])
        key = urlsplit(original).path.rsplit("/", 1)[-1].lower()
        replacement = replacements.get(key)
        if not replacement:
            return match[0]
        return replacement.replace("&", "&amp;") if "&amp;" in match[0] else replacement
    return ATTACHMENT_PATTERN.sub(replace, text)


def rendered_comment(comment: Json) -> str:
    rendered = comment.get("renderedText")
    if rendered is not None:
        return rendered
    if str(comment.get("format", "")).lower() in {"markdown", "0"}:
        raise MigrationError("Source Markdown comment has no renderedText")
    return comment["text"]


class Checkpoint:
    def __init__(self, path: Path, binding: Json):
        self.path = path
        self.data: Json = {
            "version": 1, "binding": binding, "items": {}, "attachments": {},
            "comments": {}, "links": [], "pending": None,
        }
        if path.exists():
            self.data = json.loads(path.read_text(encoding="utf-8"))
            if self.data.get("version") != 1 or self.data.get("binding") != binding:
                raise MigrationError("Checkpoint does not match these URLs, root, mapping, or source snapshot")
            if self.data.get("pending"):
                raise MigrationError(
                    f"Uncertain write in checkpoint: {self.data['pending']}. "
                    "Inspect the destination and reconcile the checkpoint before resuming; see README."
                )
        self.save()

    def save(self) -> None:
        temporary = self.path.with_name(self.path.name + ".tmp")
        try:
            with temporary.open("x", encoding="utf-8") as handle:
                os.chmod(temporary, 0o600)
                json.dump(self.data, handle, indent=2, ensure_ascii=True)
                handle.flush()
                os.fsync(handle.fileno())
            temporary.replace(self.path)
        except OSError as exc:
            raise MigrationError(f"Cannot save checkpoint {self.path}: {exc}") from exc

    def write(self, destination: Client, section: str, key: str, method: str,
              url: str, result_field: str | None = None, **kwargs: Any) -> Any:
        self.data["pending"] = {"section": section, "key": key, "method": method, "url": url}
        self.save()
        result = destination.request(method, url, **kwargs)
        value = result[result_field] if result_field else True
        if section == "links":
            self.data[section].append(key)
        else:
            self.data[section][key] = value
        self.data["pending"] = None
        self.save()
        return value


def migrate(source: Client, destination: Client, root_id: int, mapping: Json,
            checkpoint_path: Path, dry_run: bool = False) -> Json:
    if source.base.casefold() == destination.base.casefold():
        raise MigrationError("Source and destination projects must differ")
    items = collect(source, root_id)
    definitions = {f["referenceName"]: f for f in destination.get("fields")["value"]}
    type_fields: dict[str, set[str]] = {}
    plan = []
    for item in items:
        source_type = item["fields"]["System.WorkItemType"]
        target_type = mapping.get("work_item_types", {}).get(source_type, source_type)
        if target_type not in type_fields:
            result = destination.get(f"workitemtypes/{quote(target_type, safe='')}/fields")
            type_fields[target_type] = {f["referenceName"] for f in result["value"]}
        target_type, fields = mapped_fields(
            item, mapping, definitions, type_fields[target_type], destination.project,
        )
        for comment in item["migration_comments"]:
            if comment.get("id", comment.get("commentId")) is None:
                raise MigrationError(f"Source {item['id']} has a comment without an ID")
            rendered_comment(comment)
        attachments = attachments_for(source, item, fields)
        # Validate all items before the first persistent destination write.
        destination.request(
            "POST", destination.api("workitems/$" + quote(target_type, safe="")),
            payload=field_patch(fields), patch=True, query={"validateOnly": "true"},
        )
        plan.append({"item": item, "type": target_type, "fields": fields, "attachments": attachments})
        notice(
            f"Validated source {item['id']} -> {target_type}: "
            f"{len(item['migration_comments'])} comments, {len(attachments)} attachments"
        )
    if dry_run:
        return {"dry_run": True, "work_items": [entry["item"]["id"] for entry in plan]}
    fingerprint = hashlib.sha256(
        json.dumps({"mapping": mapping, "plan": plan}, sort_keys=True).encode()
    ).hexdigest()
    checkpoint = Checkpoint(checkpoint_path, {
        "source": source.base, "destination": destination.base,
        "root_id": root_id, "fingerprint": fingerprint,
    })
    state = checkpoint.data
    for entry in plan:
        item, fields = entry["item"], entry["fields"]
        source_id = str(item["id"])
        replacements: Json = {}
        for key, attachment in entry["attachments"].items():
            if key not in state["attachments"]:
                content = source.request("GET", attachment["url"], download=True)
                checkpoint.write(
                    destination, "attachments", key, "POST", destination.api("attachments"),
                    result_field="url", binary=content,
                    query={"fileName": attachment["name"], "uploadType": "Simple"},
                )
            replacements[key] = state["attachments"][key]
        rewritten = {
            name: rewrite_attachments(value, replacements) if isinstance(value, str) else value
            for name, value in fields.items()
        }
        if source_id not in state["items"]:
            patch = field_patch(rewritten)
            for key, attachment in entry["attachments"].items():
                patch.append({
                    "op": "add", "path": "/relations/-",
                    "value": {
                        "rel": "AttachedFile", "url": replacements[key],
                        "attributes": {"comment": attachment["comment"]},
                    },
                })
            checkpoint.write(
                destination, "items", source_id, "POST",
                destination.api("workitems/$" + quote(entry["type"], safe="")),
                result_field="id", payload=patch, patch=True,
            )
        destination_id = state["items"][source_id]
        for comment in item["migration_comments"]:
            comment_id = comment.get("id", comment.get("commentId"))
            if comment_id is None:
                raise MigrationError(f"Source {source_id} has a comment without an ID")
            key = f"{source_id}:{comment_id}"
            if key in state["comments"]:
                continue
            author = comment.get("createdBy", {})
            attribution = (
                f"Copied from {source.base}/_workitems/edit/{source_id}; "
                f"author: {author.get('displayName', author.get('uniqueName', 'unknown'))}; "
                f"created: {comment.get('createdDate', 'unknown')}"
            )
            rendered = rendered_comment(comment)
            text = "<p>" + html.escape(attribution) + "</p>\n" + rewrite_attachments(rendered, replacements)
            checkpoint.write(
                destination, "comments", key, "POST",
                destination.api(f"workitems/{destination_id}/comments"),
                payload={"text": text},
                query={"api-version": COMMENTS_VERSION, "format": "html"},
            )
        notice(f"Copied {source_id} -> {destination_id}")
    for entry in plan:
        parent = str(entry["item"]["id"])
        for child_id in entry["item"]["migration_children"]:
            child = str(child_id)
            key = f"{parent}:{child}"
            if key not in state["links"]:
                checkpoint.write(
                    destination, "links", key, "PATCH",
                    destination.api(f"workitems/{state['items'][parent]}"),
                    payload=[{
                        "op": "add", "path": "/relations/-",
                        "value": {
                            "rel": CHILD,
                            "url": destination.api(f"workitems/{state['items'][child]}"),
                        },
                    }], patch=True,
                )
    return {"dry_run": False, "items": state["items"], "checkpoint": str(checkpoint_path)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, help="https://dev.azure.com/OrgA/ProjA")
    parser.add_argument("--destination", required=True, help="https://dev.azure.com/OrgB/ProjB")
    parser.add_argument("--id", type=int, required=True, help="Source root work item ID")
    parser.add_argument("--mapping", type=Path, help="JSON template mapping")
    parser.add_argument("--checkpoint", type=Path, default=Path("migration-state.json"))
    parser.add_argument("--dry-run", action="store_true", help="Validate without persisting ADO changes")
    parser.add_argument("--timeout", type=float, default=60, help="Per-request timeout in seconds")
    args = parser.parse_args(argv)
    if args.id <= 0 or not 0 < args.timeout < float("inf"):
        parser.error("--id and --timeout must be positive finite values")
    try:
        source_pat = os.environ.get("ADO_SOURCE_PAT", "")
        destination_pat = os.environ.get("ADO_DEST_PAT", "")
        if not source_pat or not destination_pat:
            raise MigrationError("Set ADO_SOURCE_PAT and ADO_DEST_PAT environment variables")
        result = migrate(
            Client(args.source, source_pat, args.timeout),
            Client(args.destination, destination_pat, args.timeout),
            args.id, load_mapping(args.mapping), args.checkpoint, args.dry_run,
        )
        print(json.dumps(result, indent=2))
        return 0
    except (MigrationError, OSError, ValueError, KeyError, TypeError) as exc:
        notice(f"Migration failed: {exc}")
        notice("Any completed destination writes remain. Check the checkpoint before retrying.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
