#!/usr/bin/env python3
"""Re-apply every Open WebUI setting this box depends on. Idempotent; safe to re-run.

WHY THIS EXISTS: Open WebUI keeps its configuration in `config` (a key/value table)
inside webui.db, NOT in the launcher. config.py builds DEFAULT_CONFIG from the
environment and calls Config.seed_defaults(), which inserts a key only if it is
ABSENT -- so after the very first boot the DB wins and the env vars in
serve-openwebui.sh become inert, silently. Every setting below was therefore
applied to the DB by hand on 2026-09-19, which means a rebuild that only clones
this repo would come up with all of them wrong and no error to explain it.

Run AFTER open-webui has started once (so the DB and its schema exist), with the
service STOPPED, then start it:

    systemctl --user stop open-webui
    ./configure-openwebui.py
    systemctl --user start open-webui

Settings that ARE env vars in serve-openwebui.sh (ENABLE_WEB_SEARCH,
BYPASS_MODEL_ACCESS_CONTROL, WEBUI_AUTH, ...) are not repeated here: those apply
correctly to a fresh install, which is the only case where seeding runs.
"""
import json
import os
import sqlite3
import sys

DB = os.path.expanduser(os.environ.get("OPEN_WEBUI_DB", "~/.local/share/open-webui/webui.db"))

# key -> (value, why). The "why" is the point; without it these are unreviewable.
SETTINGS = {
    # --- web search -------------------------------------------------------
    "web.search.enable": (True,
        "off by default, so the UI has no web capability at all"),
    "web.search.engine": ("duckduckgo",
        "the only engine needing no API key (bundled ddgs)"),
    "web.search.result_count": (5,
        "default 3; 5 is still comfortable inside a 160K context"),

    # --- who can see the model -------------------------------------------
    # NOTE also covered by BYPASS_MODEL_ACCESS_CONTROL in the launcher; harmless
    # to leave consistent here.
    "ui.enable_signup": (True,
        "goes false once the first admin exists, so family phones cannot register"),

    # --- web search ON by default for everyone ----------------------------
    "ui.default_interface_settings": ({"webSearch": "always"},
        "new accounts inherit the web-search toggle already on; existing users "
        "are handled separately below"),

    # --- privacy ----------------------------------------------------------
    "ui.enable_community_sharing": (False,
        "ON by default: a 'Share to Community' button that uploads a whole chat "
        "to openwebui.com on one mis-tap"),

    # --- protect the single GPU ------------------------------------------
    "task.tags.enable": (False,
        "every message fired 3 extra model calls; this is one of them"),
    "task.follow_up.enable": (False,
        "and another; one 5090 is shared between phones and OpenCode"),
    "task.title.enable": (True,
        "kept: auto-titles earn their cost"),

    # --- long chats -------------------------------------------------------
    "chat.context_compaction.enable": (True,
        "off by default, so a long chat hits the 166K wall and ERRORS"),
    "chat.context_compaction.token_threshold": (120000,
        "default 80000 compacts needlessly early for a 166400 window"),

    # --- voice ------------------------------------------------------------
    "audio.stt.whisper_model": ("small",
        "'base' is weak outside English; 'small' is ~3x CPU for a big gain. "
        "Stays on CPU -- see USE_CUDA_DOCKER warning in serve-openwebui.sh"),
}

# Applied to every EXISTING user; ui.default_interface_settings only covers new ones.
PER_USER_UI = {"webSearch": "always"}


def main() -> int:
    if not os.path.exists(DB):
        print(f"ERROR: {DB} not found. Start open-webui once first so it creates the DB.")
        return 1

    con = sqlite3.connect(DB)
    changed = unchanged = 0

    for key, (value, why) in SETTINGS.items():
        want = json.dumps(value)
        row = con.execute("select value from config where key=?", (key,)).fetchone()
        # The `value` column has NUMERIC affinity, so an int written as the JSON
        # text "5" comes back as Python int 5. Comparing raw strings therefore
        # reports every numeric setting as changed on every run. Normalise both
        # sides to Python objects before deciding.
        current = row[0] if row else None
        if isinstance(current, (str, bytes)):
            try:
                current = json.loads(current)
            except (ValueError, TypeError):
                pass
        if row is None:
            con.execute(
                "insert into config (key,value,updated_at) values (?,?,strftime('%s','now'))",
                (key, want),
            )
            print(f"  + {key} = {want}   ({why})")
            changed += 1
        elif current != value:
            con.execute(
                "update config set value=?, updated_at=strftime('%s','now') where key=?",
                (want, key),
            )
            print(f"  ~ {key}: {current!r} -> {value!r}   ({why})")
            changed += 1
        else:
            unchanged += 1

    for uid, name, raw in con.execute("select id,name,settings from user").fetchall():
        settings = json.loads(raw) if raw else {}
        ui = settings.setdefault("ui", {})
        if all(ui.get(k) == v for k, v in PER_USER_UI.items()):
            unchanged += 1
            continue
        ui.update(PER_USER_UI)
        con.execute(
            "update user set settings=?, updated_at=strftime('%s','now') where id=?",
            (json.dumps(settings), uid),
        )
        print(f"  ~ user {name}: ui += {PER_USER_UI}")
        changed += 1

    con.commit()
    print(f"\n{changed} changed, {unchanged} already correct.")
    if changed:
        print("Restart open-webui, then RELOAD the page on every phone -- the client "
              "caches settings at page load and will otherwise keep the old ones.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
