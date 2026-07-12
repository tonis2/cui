"""Strip everything but cui's own modules out of a docgen-generated docs.html.

Usage:  python3 scripts/trim_docs.py docs.html [module-prefix ...]

c3c docgen embeds every module it compiled -- the whole standard library plus
every dependency -- into the page as JSON. For cui that means `vk` alone is
~5.3 MB of a ~7.3 MB page, and std another ~2 MB, while cui's own modules are
~120 KB.

There is no docgen flag to exclude dependencies, so this rewrites the embedded
data in place, keeping only the modules whose name is (or is nested under) one
of the given prefixes. The page's JS reads the data through a single call --
`for (const item of EMBEDDED_JSON_LIST) mergeTargetData(item.data, item.target)`
-- so dropping entries from the `modules` map is all that is needed. References
from kept symbols into dropped modules (e.g. a `List{Element*}` return type)
simply stop being clickable.
"""

import json
import re
import sys

START = "/*DATA_START*/"
END = "/*DATA_END*/"
PUSH = re.compile(r'EMBEDDED_JSON_LIST\.push\(\{\s*target:\s*"([^"]+)",\s*data:\s*')


def keep(module: str, prefixes: list[str]) -> bool:
    return any(module == p or module.startswith(p + "::") for p in prefixes)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    path = sys.argv[1]
    prefixes = sys.argv[2:] or ["cui"]

    with open(path, encoding="utf-8") as f:
        html = f.read()

    try:
        head_end = html.index(START)
        tail_start = html.index(END)
    except ValueError:
        print(f"{path}: no {START}/{END} markers -- not a docgen page?")
        return 1

    decoder = json.JSONDecoder()
    pushes, kept_total, dropped_total = [], 0, 0

    pos = head_end
    while (m := PUSH.search(html, pos, tail_start)) is not None:
        data, end = decoder.raw_decode(html, m.end())
        modules = data.get("modules", {})

        kept = {name: body for name, body in modules.items() if keep(name, prefixes)}
        kept_total += len(kept)
        dropped_total += len(modules) - len(kept)
        data["modules"] = kept

        pushes.append(
            "\t\tEMBEDDED_JSON_LIST.push({ target: %s, data: %s});"
            % (json.dumps(m.group(1)), json.dumps(data, separators=(",", ":")))
        )
        pos = end

    if not pushes:
        print(f"{path}: found no EMBEDDED_JSON_LIST.push(...) blocks")
        return 1

    trimmed = html[:head_end] + START + "\n" + "\n".join(pushes) + "\n\t\t" + html[tail_start:]

    with open(path, "w", encoding="utf-8") as f:
        f.write(trimmed)

    before, after = len(html), len(trimmed)
    print(
        f"{path}: kept {kept_total} module(s) matching {prefixes}, dropped {dropped_total}\n"
        f"  {before / 1024 / 1024:.1f} MB -> {after / 1024:.0f} KB "
        f"({100 * (before - after) / before:.1f}% smaller)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
