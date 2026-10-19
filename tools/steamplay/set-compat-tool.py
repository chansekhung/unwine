#!/usr/bin/env python3
"""Map Steam apps to a compatibility tool in Mac Steam's config.vdf (Steam must be closed).

usage: set-compat-tool.py <tool-name> <appid> [<appid> ...]
       set-compat-tool.py --remove <appid> [...]
Writes a backup next to config.vdf first. Only touches the CompatToolMapping block.
"""
import os
import re
import shutil
import sys
import time

CONFIG = os.environ.get("DECANT_STEAM_CONFIG") or os.path.expanduser("~/Library/Application Support/Steam/config/config.vdf")


def find_block(text, key, start=0, end=None):
    """Return (open_brace, close_brace) of the block named `key` between start and end."""
    end = len(text) if end is None else end
    m = re.compile(r'"%s"\s*\{' % re.escape(key), re.I).search(text, start, end)
    if not m:
        return None
    depth, i = 0, m.end() - 1
    in_str = False
    while i < end:
        c = text[i]
        if c == '"' and text[i - 1] != '\\':
            in_str = not in_str
        elif not in_str:
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    return m.end() - 1, i
        i += 1
    raise SystemExit(f"unbalanced braces after {key}")


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        raise SystemExit(__doc__)
    remove = args[0] == "--remove"
    tool = None if remove else args[0]
    appids = args[1:]
    if not all(a.isdigit() and a != "0" for a in appids):
        raise SystemExit("appids must be numbers and never 0 (0 would switch every game)")

    text = open(CONFIG, encoding="utf-8").read()
    backup = f"{CONFIG}.decant-{time.strftime('%Y%m%d-%H%M%S')}.bak"
    shutil.copy2(CONFIG, backup)

    steam = None
    for path in (["InstallConfigStore", "Software", "Valve", "Steam"],
                 ["InstallConfigStore", "Software", "valve", "Steam"]):
        s, e = 0, len(text)
        ok = True
        for key in path:
            blk = find_block(text, key, s, e)
            if not blk:
                ok = False
                break
            s, e = blk[0] + 1, blk[1]
        if ok:
            steam = (s, e)
            break
    if not steam:
        raise SystemExit("could not find InstallConfigStore/Software/Valve/Steam in config.vdf")

    mapping = find_block(text, "CompatToolMapping", *steam)
    if not mapping:
        insert = '\n\t\t\t\t"CompatToolMapping"\n\t\t\t\t{\n\t\t\t\t}'
        text = text[:steam[0]] + insert + text[steam[0]:]
        steam = (steam[0], steam[1] + len(insert))
        mapping = find_block(text, "CompatToolMapping", *steam)

    for appid in appids:
        existing = find_block(text, appid, mapping[0] + 1, mapping[1])
        if existing:
            # Drop the old entry including its key line.
            key_start = text.rfind('"%s"' % appid, mapping[0], existing[0])
            line_start = text.rfind("\n", 0, key_start)
            text = text[:line_start] + text[existing[1] + 1:]
            mapping = find_block(text, "CompatToolMapping", steam[0], len(text))
        if not remove:
            entry = ('\n\t\t\t\t\t"%s"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"%s"\n'
                     '\t\t\t\t\t\t"config"\t\t""\n\t\t\t\t\t\t"priority"\t\t"250"\n\t\t\t\t\t}') % (appid, tool)
            text = text[:mapping[0] + 1] + entry + text[mapping[0] + 1:]
            mapping = find_block(text, "CompatToolMapping", steam[0], len(text))

    with open(CONFIG + ".decant-tmp", "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(CONFIG + ".decant-tmp", CONFIG)
    print(f"{'removed' if remove else 'mapped'} {', '.join(appids)}{'' if remove else ' -> ' + tool} (backup: {os.path.basename(backup)})")


if __name__ == "__main__":
    main()
