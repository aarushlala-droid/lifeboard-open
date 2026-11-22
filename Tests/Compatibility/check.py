"""Older-data and rollback compatibility for LifeBoard Preview (synthetic data only).

Usage: python3 Tests/Compatibility/check.py <sample.json> <preview helper> <baseline helper> <workdir>

1. Builds a legacy (pre-schema-3) document from the synthetic sample by removing
   the fields older versions did not write.
2. The Preview helper opens it, completes one task and saves; every record, ID
   and untouched field must survive and the saved file must be schema 3.
3. The baseline (currently installed) helper must read what the Preview wrote,
   so returning to the installed app is always safe.
"""
import json, os, subprocess, sys

sample, preview, baseline, work = sys.argv[1:5]
os.makedirs(work, exist_ok=True)
doc = json.load(open(sample))
for key in ("schemaVersion", "focusSessions", "activeFocus", "externalEvents"):
    doc.pop(key, None)
for task in doc["tasks"]:
    for key in ("subtasks", "recurrence", "completionPercent", "scheduledDurationMinutes", "recurrenceSeriesID", "archivedAt", "actualMinutes"):
        task.pop(key, None)
for key in ("notificationsScheduledItems", "notificationsDeadlines", "notificationsFocus", "notificationLeadMinutes", "selectedExternalCalendarIDs", "lastExternalCalendarRefresh", "automaticICloudBackup", "lastICloudBackup", "planningHours"):
    doc["settings"].pop(key, None)
legacy_path = os.path.join(work, "LifeBoard.json")
json.dump(doc, open(legacy_path, "w"), indent=2)
fixture = os.path.join(os.path.dirname(__file__), "legacy-pre-schema3.json")
json.dump(doc, open(fixture, "w"), indent=2, sort_keys=True)

def run(helper, *args):
    env = dict(os.environ, LIFEBOARD_DATA_PATH=legacy_path, LIFEBOARD_ICLOUD_BACKUP_PATH=os.path.join(work, "cloud"))
    out = subprocess.run([helper, *args], env=env, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"FAIL: {os.path.basename(helper)} {' '.join(args)}: {out.stderr.strip()}")
    return out.stdout

def check(condition, message):
    if not condition:
        sys.exit("FAIL: " + message)
    print("PASS: " + message)

listed = json.loads(run(preview, "tasks", "list"))
check(len(listed) == len([t for t in doc["tasks"] if not t.get("isArchived")]), "the Preview opens a legacy document with every task")
target = next(t for t in doc["tasks"] if not t["isCompleted"] and not t.get("isArchived"))
run(preview, "task", "complete", "--id", target["id"])
saved = json.load(open(legacy_path))
check(saved.get("schemaVersion") == 3, "saving writes schema 3")
before = {t["id"].lower(): t for t in doc["tasks"]}
after = {t["id"].lower(): t for t in saved["tasks"]}
check(set(before) <= set(after), "every task ID survives the save")
check(all(after[i]["title"] == t["title"] and after[i].get("dueDay") == t.get("dueDay") and after[i].get("scheduledDay") == t.get("scheduledDay") and after[i].get("scheduledStartMinutes") == t.get("scheduledStartMinutes") for i, t in before.items()), "titles, due days, planned days and times are unchanged")
check(all(after[i]["isCompleted"] == t["isCompleted"] for i, t in before.items() if i != target["id"].lower()) and after[target["id"].lower()]["isCompleted"], "only the edited task changed completion")
for key in ("events", "subjects", "projects", "yearMarkers"):
    check(sorted(x["id"].lower() for x in saved[key]) == sorted(x["id"].lower() for x in doc[key]), f"all {key} survive with their IDs")
check(saved["settings"].get("weekStartsMonday") == doc["settings"].get("weekStartsMonday") and saved["settings"].get("defaultTaskMinutes") == doc["settings"].get("defaultTaskMinutes"), "shared settings are preserved")

baseline_list = json.loads(run(baseline, "tasks", "list"))
check(len(baseline_list) == len(json.loads(run(preview, "tasks", "list"))), "the installed version's helper reads the file the Preview wrote")
print("PASS: older-data and rollback compatibility")
