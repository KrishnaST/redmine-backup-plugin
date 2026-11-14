"""Maintainer SSH transport. Password via stdin only; never a backup runtime dependency."""

import argparse
import getpass
import json
import pathlib
import shlex
import sys

bundled = pathlib.Path(__file__).resolve().parent / "runtime" / "python-libs"
if bundled.is_dir():
    sys.path.insert(0, str(bundled))

import paramiko


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--user", required=True)
    parser.add_argument("--port", type=int, default=22)
    arguments = parser.parse_args()
    password = getpass.getpass("SSH password (not stored): ")
    if not password:
        parser.error("A password is required")
    client = paramiko.SSHClient()
    client.load_system_host_keys(str(pathlib.Path.home() / ".ssh" / "known_hosts"))
    client.set_missing_host_key_policy(paramiko.RejectPolicy())
    client.connect(arguments.host, port=arguments.port, username=arguments.user,
                   password=password, look_for_keys=False, allow_agent=False, timeout=20)
    print(json.dumps({"connected": True}), flush=True)
    try:
        for line in sys.stdin:
            request = json.loads(line)
            if request.get("operation") == "close":
                break
            if request.get("operation") == "put":
                with client.open_sftp() as transfer:
                    transfer.put(request["local"], request["remote"])
                print(json.dumps({"uploaded": True}), flush=True)
                continue
            script = "exec </dev/null\nset -e\n" + request["script"]
            command = "bash -c " + shlex.quote(script)
            if request.get("sudo"):
                command = "sudo -S -p '' -- " + command
            channel_input, output, errors = client.exec_command(command, timeout=request.get("timeout", 300))
            if request.get("sudo"):
                channel_input.write(password + "\n")
                channel_input.flush()
            channel_input.channel.shutdown_write()
            result = output.read().decode("utf-8", errors="replace")
            failure = errors.read().decode("utf-8", errors="replace")
            code = output.channel.recv_exit_status()
            print(json.dumps({"exit": code, "stdout": result.replace(password, "[REDACTED]"),
                              "stderr": failure.replace(password, "[REDACTED]")}), flush=True)
    finally:
        client.close()


if __name__ == "__main__":
    main()
