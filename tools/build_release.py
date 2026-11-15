"""Package the committed runtime/docs only, with revision and SHA-256 source manifest."""

import hashlib
import io
import json
import pathlib
import subprocess
import tarfile


def main():
    root = pathlib.Path(__file__).resolve().parent.parent
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    paths = ["app", "assets", "bin", "config", "documentation", "lib", "templates", "Gemfile", "init.rb", "README.md", "LICENSE"]
    archive = subprocess.check_output(["git", "archive", "--format=tar", revision, *paths], cwd=root)
    destination = root / "tmp" / "deployment" / "redmine-backup-plugin.tar.gz"
    destination.parent.mkdir(parents=True, exist_ok=True)
    manifest = {}
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as source:
        with tarfile.open(destination, "w:gz") as output:
            for member in source.getmembers():
                content = source.extractfile(member) if member.isfile() else None
                output.addfile(member, content)
                if member.isfile() and (member.name.startswith(("app/", "assets/", "config/", "lib/")) or member.name == "init.rb"):
                    manifest[member.name] = hashlib.sha256(source.extractfile(member).read()).hexdigest()
            payload = (revision + "\n").encode()
            entry = tarfile.TarInfo("REVISION")
            entry.size = len(payload)
            entry.mode = 0o644
            output.addfile(entry, io.BytesIO(payload))
    (destination.parent / "runtime-source.json").write_text(json.dumps(manifest), encoding="utf-8")
    print(json.dumps({"revision": revision, "runtime_files": len(manifest),
                      "archive": str(destination), "sha256": hashlib.sha256(destination.read_bytes()).hexdigest()}))


if __name__ == "__main__":
    main()
