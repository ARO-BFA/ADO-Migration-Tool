import copy
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, unquote, urlsplit

import migrate_work_item as migration


SOURCE = "https://dev.azure.com/OrgA/ProjA"
DESTINATION = "https://dev.azure.com/OrgB/ProjB"
ATTACHMENT_ID = "00000000-0000-0000-0000-000000000001"
ATTACHMENT = f"https://dev.azure.com/OrgA/_apis/wit/attachments/{ATTACHMENT_ID}"
UPLOADED = f"https://dev.azure.com/OrgB/_apis/wit/attachments/{ATTACHMENT_ID}?fileName=a.png"


def source_item(item_id, children=()):
    return {
        "id": item_id, "rev": 1,
        "fields": {
            "System.Id": item_id, "System.TeamProject": "ProjA",
            "System.WorkItemType": "User Story", "System.Title": f"Item {item_id}",
            "System.State": "Active", "System.AreaPath": "ProjA\\Old",
            "System.IterationPath": "ProjA\\Sprint",
            "System.AssignedTo": {"uniqueName": "alice@a.example"},
            "Microsoft.VSTS.Scheduling.StoryPoints": 5,
        },
        "relations": [
            {"rel": migration.CHILD, "url": f"{SOURCE}/_apis/wit/workItems/{child}"}
            for child in children
        ],
    }


class FakeADO:
    def __init__(self):
        self.source = migration.Client(SOURCE, "source-secret")
        self.destination = migration.Client(DESTINATION, "destination-secret")
        self.items = {1: source_item(1, [2]), 2: source_item(2, [3]), 3: source_item(3)}
        self.items[1]["fields"]["System.Description"] = f'<img src="{ATTACHMENT}?fileName=a.png">'
        self.items[1]["relations"].append({
            "rel": "AttachedFile", "url": ATTACHMENT,
            "attributes": {"name": "a.png", "comment": "screenshot"},
        })
        self.mapping = {
            "work_item_types": {"User Story": "Product Backlog Item"},
            "fields": {"Microsoft.VSTS.Scheduling.StoryPoints": "Microsoft.VSTS.Scheduling.Effort"},
            "states": {"User Story": {"Active": "Approved"}},
            "identities": {"alice@a.example": "alice@b.example"},
            "area_paths": {"ProjA\\Old": "ProjB\\New"},
        }
        names = {
            "System.Title", "System.State", "System.AreaPath", "System.IterationPath",
            "System.Description", "System.AssignedTo", "Microsoft.VSTS.Scheduling.Effort",
        }
        self.definitions = {
            name: {"referenceName": name, "isIdentity": name == "System.AssignedTo"}
            for name in names
        }
        self.created = []
        self.comments = []
        self.links = []
        self.uploads = []
        self.downloads = []
        self.validations = []
        self.fail_comment = False
        self.source.request = Mock(side_effect=self.source_request)
        self.destination.request = Mock(side_effect=self.destination_request)

    def source_request(self, method, url, **kwargs):
        if method != "GET":
            raise AssertionError("Source must never be modified")
        if "/attachments/" in url:
            self.downloads.append(url)
            return b"image bytes"
        item_id = int(url.split("/workitems/")[1].split("/")[0])
        if url.endswith("/comments"):
            query = kwargs["query"]
            if item_id != 1:
                return {"comments": []}
            if "continuationToken" not in query:
                return {
                    "comments": [{
                        "id": 8, "format": "markdown", "text": "**Hello**",
                        "renderedText": "<p><strong>Hello</strong></p>",
                        "createdBy": {"displayName": "Alice <Admin>"},
                        "createdDate": "2026-01-01T00:00:00Z",
                    }],
                    "continuationToken": "next & page",
                }
            return {"comments": [{
                "commentId": 9, "text": f'<p><img src="{ATTACHMENT}"></p>',
                "createdBy": {"displayName": "Bob"}, "createdDate": "2026-01-02T00:00:00Z",
            }, {"id": 10, "text": "deleted", "isDeleted": True}]}
        return copy.deepcopy(self.items[item_id])

    def destination_request(self, method, url, **kwargs):
        path = unquote(urlsplit(url).path)
        if method == "GET" and path.endswith("/fields"):
            return {"value": list(self.definitions.values())}
        if kwargs.get("query", {}).get("validateOnly") == "true":
            self.validations.append(kwargs["payload"])
            return {}
        if path.endswith("/attachments"):
            self.uploads.append(kwargs)
            return {"url": UPLOADED}
        if method == "POST" and "/workitems/$" in path:
            self.created.append(kwargs["payload"])
            return {"id": 1000 + len(self.created)}
        if method == "POST" and path.endswith("/comments"):
            if self.fail_comment:
                raise migration.MigrationError("Connection lost after comment POST")
            self.comments.append(kwargs["payload"]["text"])
            return {"commentId": 80 + len(self.comments)}
        if method == "PATCH":
            self.links.append((url, kwargs["payload"]))
            return {}
        raise AssertionError((method, url, kwargs))


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.checkpoint = Path(self.temp.name) / "checkpoint.json"
        self.ado = FakeADO()
        self.quiet = patch("migrate_work_item.notice")
        self.quiet.start()
        self.addCleanup(self.quiet.stop)

    def run_migration(self, dry_run=False):
        return migration.migrate(
            self.ado.source, self.ado.destination, 1, self.ado.mapping,
            self.checkpoint, dry_run,
        )

    def test_recursive_copy_and_completed_resume(self):
        original = copy.deepcopy(self.ado.items)
        result = self.run_migration()
        self.assertEqual(result["items"], {"1": 1001, "2": 1002, "3": 1003})
        self.assertEqual(len(self.ado.validations), 3)
        self.assertEqual(len(self.ado.created), 3)
        self.assertEqual(len(self.ado.uploads), 1)
        self.assertEqual(self.ado.uploads[0]["binary"], b"image bytes")
        self.assertEqual(len(self.ado.downloads), 1)
        self.assertEqual(len(self.ado.comments), 2)
        self.assertIn("Alice &lt;Admin&gt;", self.ado.comments[0])
        self.assertIn("<strong>Hello</strong>", self.ado.comments[0])
        self.assertIn(UPLOADED, self.ado.comments[1])
        first = self.ado.created[0]
        fields = {op["path"]: op["value"] for op in first if op["path"].startswith("/fields/")}
        self.assertEqual(fields["/fields/System.State"], "Approved")
        self.assertEqual(fields["/fields/System.AreaPath"], "ProjB\\New")
        self.assertEqual(fields["/fields/System.IterationPath"], "ProjB")
        self.assertEqual(fields["/fields/System.AssignedTo"], "alice@b.example")
        self.assertEqual(fields["/fields/Microsoft.VSTS.Scheduling.Effort"], 5)
        self.assertIn(UPLOADED, fields["/fields/System.Description"])
        self.assertEqual(first[-1]["value"]["rel"], "AttachedFile")
        self.assertEqual(first[-1]["value"]["attributes"]["comment"], "screenshot")
        self.assertEqual(len(self.ado.links), 2)
        self.assertTrue(self.ado.links[0][0].endswith("/workitems/1001"))
        self.assertTrue(self.ado.links[0][1][0]["value"]["url"].endswith("/workitems/1002"))
        self.assertTrue(self.ado.links[1][1][0]["value"]["url"].endswith("/workitems/1003"))
        self.assertEqual(original, self.ado.items)
        state = json.loads(self.checkpoint.read_text())
        self.assertIsNone(state["pending"])
        self.assertNotIn("secret", self.checkpoint.read_text())
        self.assertEqual(self.checkpoint.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.run_migration()["items"], result["items"])
        self.assertEqual(len(self.ado.created), 3)
        self.assertEqual(len(self.ado.uploads), 1)
        self.assertEqual(len(self.ado.comments), 2)
        self.assertEqual(len(self.ado.links), 2)

    def test_dry_run_does_not_persist_anything(self):
        result = self.run_migration(dry_run=True)
        self.assertEqual(result, {"dry_run": True, "work_items": [1, 2, 3]})
        self.assertEqual(len(self.ado.validations), 3)
        self.assertFalse(self.checkpoint.exists())
        self.assertFalse(self.ado.created or self.ado.uploads or self.ado.comments or self.ado.links)
        self.assertFalse(self.ado.downloads)

    def test_unknown_field_on_descendant_prevents_all_writes(self):
        self.ado.items[3]["fields"]["Custom.Unknown"] = "important"
        with self.assertRaisesRegex(migration.MigrationError, "Custom.Unknown"):
            self.run_migration()
        self.assertFalse(self.ado.created or self.ado.uploads)
        self.ado.mapping["fields"]["Custom.Unknown"] = None
        self.run_migration(dry_run=True)

    def test_interrupted_write_blocks_unsafe_retries(self):
        self.ado.fail_comment = True
        with self.assertRaisesRegex(migration.MigrationError, "Connection lost"):
            self.run_migration()
        state = json.loads(self.checkpoint.read_text())
        self.assertEqual(state["items"], {"1": 1001})
        self.assertEqual(state["pending"]["section"], "comments")
        self.assertEqual(state["pending"]["key"], "1:8")
        self.ado.fail_comment = False
        with self.assertRaisesRegex(migration.MigrationError, "Uncertain write"):
            self.run_migration()
        self.assertEqual(len(self.ado.created), 1)
        # Operator confirmed that the uncertain comment was NOT created.
        state["pending"] = None
        self.checkpoint.write_text(json.dumps(state))
        self.run_migration()
        self.assertEqual(len(self.ado.created), 3)
        self.assertEqual(len(self.ado.uploads), 1)
        self.assertEqual(len(self.ado.comments), 2)

    def test_changed_source_refuses_checkpoint(self):
        self.run_migration()
        self.ado.items[1]["rev"] = 2
        with self.assertRaisesRegex(migration.MigrationError, "snapshot"):
            self.run_migration()
        self.assertEqual(len(self.ado.created), 3)

    def test_invalid_comment_fails_before_writes(self):
        self.ado.source.comments = Mock(return_value=[{"id": 1, "format": "markdown", "text": "**Hi**"}])
        with self.assertRaisesRegex(migration.MigrationError, "renderedText"):
            self.run_migration()
        self.assertFalse(self.ado.created or self.ado.uploads)

    def test_cycle_and_cross_project_child_are_rejected(self):
        self.ado.items[3]["relations"] = [{"rel": migration.CHILD, "url": f"{SOURCE}/_apis/wit/workitems/1"}]
        with self.assertRaisesRegex(migration.MigrationError, "not a tree"):
            self.run_migration()
        self.ado.items[3]["relations"] = []
        self.ado.items[3]["fields"]["System.TeamProject"] = "AnotherProject"
        with self.assertRaisesRegex(migration.MigrationError, "outside source project"):
            self.run_migration()
        self.assertFalse(self.ado.created)

    def test_inline_only_attachment_is_uploaded(self):
        self.ado.items[1]["relations"] = self.ado.items[1]["relations"][:1]
        self.run_migration()
        self.assertEqual(len(self.ado.uploads), 1)
        self.assertEqual(self.ado.uploads[0]["query"]["fileName"], "a.png")

    def test_defaults_values_and_identity_drop(self):
        self.ado.mapping["identities"]["alice@a.example"] = None
        self.ado.mapping["values"] = {"Microsoft.VSTS.Scheduling.Effort": {"5": 8}}
        self.ado.mapping["defaults"] = {"System.State": "New"}
        self.ado.mapping["type_defaults"] = {"Product Backlog Item": {"System.State": "Done"}}
        self.run_migration()
        fields = {op["path"]: op["value"] for op in self.ado.created[0]}
        self.assertNotIn("/fields/System.AssignedTo", fields)
        self.assertEqual(fields["/fields/System.State"], "Done")
        self.assertEqual(fields["/fields/Microsoft.VSTS.Scheduling.Effort"], 8)

    def test_duplicate_and_readonly_field_mappings_fail(self):
        self.ado.mapping["fields"]["Microsoft.VSTS.Scheduling.StoryPoints"] = "System.Title"
        with self.assertRaisesRegex(migration.MigrationError, "Multiple source"):
            self.run_migration()
        self.ado.mapping["fields"]["Microsoft.VSTS.Scheduling.StoryPoints"] = "Microsoft.VSTS.Scheduling.Effort"
        self.ado.definitions["System.Title"]["readOnly"] = True
        self.ado.mapping["defaults"] = {"System.Title": "Cannot override"}
        with self.assertRaisesRegex(migration.MigrationError, "Invalid default"):
            self.run_migration()

    def test_comments_repeated_continuation_token_fails(self):
        self.ado.source.get = Mock(return_value={"comments": [], "continuationToken": "same"})
        with self.assertRaisesRegex(migration.MigrationError, "repeated"):
            self.ado.source.comments(1)


class TransportTests(unittest.TestCase):
    def test_project_url_validation_and_encoding(self):
        client = migration.Client("https://dev.azure.com/org/My%20Project", "secret")
        self.assertEqual(client.project, "My Project")
        self.assertEqual(client.base, "https://dev.azure.com/org/My%20Project")
        for bad in ["http://dev.azure.com/org/project", "https://evil.example/org/project",
                    SOURCE + "?query=x", "https://dev.azure.com/org/project/extra"]:
            with self.subTest(bad=bad), self.assertRaises(migration.MigrationError):
                migration.Client(bad, "secret")
        for bad in ["https://dev.azure.com/OtherOrg/_apis/wit/workitems/1",
                    "https://evil.example/OrgA/_apis/wit/attachments/1"]:
            with self.subTest(bad=bad), self.assertRaises(migration.MigrationError):
                migration.Client(SOURCE, "secret").check_url(bad)

    def test_request_headers_query_and_json_patch(self):
        client = migration.Client(SOURCE, "secret")
        client.opener.open = Mock(return_value=io.BytesIO(b'{"id": 99}'))
        result = client.request(
            "POST", client.api("workitems/$Task"), payload=[], patch=True,
            query={"validateOnly": "true", "continuationToken": "a & b"},
        )
        self.assertEqual(result["id"], 99)
        request = client.opener.open.call_args.args[0]
        self.assertEqual(request.get_header("Authorization"), "Basic OnNlY3JldA==")
        self.assertEqual(request.get_header("Content-type"), "application/json-patch+json")
        self.assertEqual(parse_qs(urlsplit(request.full_url).query)["continuationToken"], ["a & b"])
        self.assertEqual(json.loads(request.data), [])

    def test_http_and_connection_errors_are_explicit_and_not_retried(self):
        client = migration.Client(SOURCE, "secret")
        for error, expected in [
            (HTTPError(SOURCE, 400, "bad", {}, io.BytesIO(b'{"message":"Invalid state"}')), "Invalid state"),
            (URLError("connection lost"), "connection lost"),
        ]:
            with self.subTest(expected=expected):
                client.opener.open = Mock(side_effect=error)
                with self.assertRaisesRegex(migration.MigrationError, expected):
                    client.request("POST", client.api("workitems/$Task"), payload=[])
                self.assertEqual(client.opener.open.call_count, 1)

    def test_download_size_limit(self):
        client = migration.Client(SOURCE, "secret")
        client.opener.open = Mock(return_value=io.BytesIO(b"1234"))
        with patch.object(migration, "MAX_ATTACHMENT_BYTES", 3):
            with self.assertRaisesRegex(migration.MigrationError, "simple-upload limit"):
                client.request("GET", ATTACHMENT, download=True)

    def test_redirect_is_never_followed(self):
        self.assertIsNone(migration.NoRedirects().redirect_request(
            None, None, 302, "", {}, "https://evil.example",
        ))

    def test_html_attachment_url_rewrite(self):
        original = ATTACHMENT + "?fileName=a.png&amp;download=true"
        result = migration.rewrite_attachments(f'<img src="{original}">', {ATTACHMENT_ID: UPLOADED + "&x=1"})
        self.assertEqual(result, f'<img src="{UPLOADED}&amp;x=1">')

    def test_mapping_schema_and_patch_escaping(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mapping.json"
            for value in [[], {"typo": {}}, {"fields": []}, {"values": {"x": []}}, {"fields": {"x": 4}}]:
                path.write_text(json.dumps(value))
                with self.subTest(value=value), self.assertRaises(migration.MigrationError):
                    migration.load_mapping(path)
        self.assertEqual(migration.field_patch({"a/b~c": 1})[0]["path"], "/fields/a~1b~0c")

    def test_missing_pat_fails_without_network(self):
        with patch.dict("os.environ", {}, clear=True), patch("migrate_work_item.notice"):
            self.assertEqual(migration.main([
                "--source", SOURCE, "--destination", DESTINATION, "--id", "1",
            ]), 1)


if __name__ == "__main__":
    unittest.main()
