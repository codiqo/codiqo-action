#!/usr/bin/env python3
"""Merge a snapshot repository into an existing Maven settings.xml.

A text-level insert would corrupt a caller's file, so this does a real XML merge: it keeps
the default namespace, preserves any profiles already present, and is a no-op when the URL
is already reachable. Exits non-zero on a parse failure so the caller can print the manual
recipe instead of silently continuing.

Usage: inject-plugin-repository.py <settings.xml> <repository-url>
"""

import sys
import xml.etree.ElementTree as ET

PROFILE_ID = "codiqo-managed-repos"
REPO_ID = "central-snapshots"
MAVEN_NS = "http://maven.apache.org/SETTINGS/1.0.0"


def qname(tag: str, ns: str) -> str:
    return f"{{{ns}}}{tag}" if ns else tag


def find(parent, tag: str, ns: str):
    return parent.find(qname(tag, ns))


def findall(parent, tag: str, ns: str):
    return parent.findall(qname(tag, ns))


def sub(parent, tag: str, ns: str, text: str | None = None):
    element = ET.SubElement(parent, qname(tag, ns))
    if text is not None:
        element.text = text
    return element


def already_present(root, ns: str, url: str) -> bool:
    """True when some profile already offers this URL, or our profile exists."""
    for profile in root.iter(qname("profile", ns)):
        pid = find(profile, "id", ns)
        if pid is not None and (pid.text or "").strip() == PROFILE_ID:
            return True
    for element in root.iter():
        if element.tag == qname("url", ns) and (element.text or "").strip().rstrip("/") == url.rstrip("/"):
            return True
    return False


def build_repository_block(parent, ns: str, tag: str, url: str) -> None:
    repository = sub(parent, tag, ns)
    sub(repository, "id", ns, REPO_ID)
    sub(repository, "url", ns, url)
    sub(sub(repository, "releases", ns), "enabled", ns, "false")
    snapshots = sub(repository, "snapshots", ns)
    sub(snapshots, "enabled", ns, "true")
    sub(snapshots, "updatePolicy", ns, "always")


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    path, url = sys.argv[1], sys.argv[2]

    try:
        tree = ET.parse(path)
    except ET.ParseError as err:
        print(f"settings.xml is not parseable XML: {err}", file=sys.stderr)
        return 1

    root = tree.getroot()
    ns = ""
    if root.tag.startswith("{"):
        ns = root.tag[1:].split("}", 1)[0]
    #
    # Register the namespace as the default so the output has no ns0: prefixes, which Maven
    # tolerates but which would make the file unrecognisable to a human reviewing a diff.
    #
    if ns:
        ET.register_namespace("", ns)

    if already_present(root, ns, url):
        print(f"a repository for {url} (or profile {PROFILE_ID}) is already present; leaving settings.xml unchanged")
        return 0

    profiles = find(root, "profiles", ns)
    if profiles is None:
        profiles = sub(root, "profiles", ns)

    profile = sub(profiles, "profile", ns)
    sub(profile, "id", ns, PROFILE_ID)
    build_repository_block(sub(profile, "repositories", ns), ns, "repository", url)
    build_repository_block(sub(profile, "pluginRepositories", ns), ns, "pluginRepository", url)

    active = find(root, "activeProfiles", ns)
    if active is None:
        active = sub(root, "activeProfiles", ns)
    if not any((element.text or "").strip() == PROFILE_ID for element in findall(active, "activeProfile", ns)):
        sub(active, "activeProfile", ns, PROFILE_ID)

    if hasattr(ET, "indent"):
        ET.indent(tree, space="  ")
    tree.write(path, encoding="UTF-8", xml_declaration=True)
    print(f"merged profile {PROFILE_ID} ({url}) into {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
