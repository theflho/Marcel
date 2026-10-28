"""Run the real sync script with inert command stubs: never acknowledge an unready gateway."""

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest


@pytest.mark.parametrize("case", ["", "revoke", "prepare", "restart", "health", "verify", "ack", "skills-only"])
def test_context_ack_follows_install_restart_health_and_file_verification(tmp_path, case):
    failure = case if case != "skills-only" else ""
    backend = tmp_path / "backend"
    deploy = backend / "deploy"
    deploy.mkdir(parents=True)
    script = Path(__file__).parents[1] / "deploy" / "auto-update.sh"
    shutil.copy(script, deploy / script.name)
    (backend / "app").mkdir()
    (backend / "app" / "hermes_profiles.py").write_text("# test source identity\n")
    (deploy / "hermes-skills").mkdir()
    home = tmp_path / "hermes"
    home.mkdir()
    (home / "config.yaml").write_text("{}\n")
    (home / ".env").write_text("# no real credentials\n")
    (backend / ".env").write_text(f"MARCEL_TOKEN=test-only\nMARCEL_HERMES_HOME={home}\n")
    trace = tmp_path / "trace"
    binaries = tmp_path / "bin"
    binaries.mkdir()
    stub = binaries / "stub"
    stub.write_text(f"#!{sys.executable}\n" + r'''
import json
import os
import subprocess
import sys
from pathlib import Path

name = Path(sys.argv[0]).name
args = sys.argv[1:]
failure = os.environ["CONTEXT_TEST_FAILURE"]

def record(stage):
    with open(os.environ["CONTEXT_TEST_TRACE"], "a") as out:
        out.write(stage + "\n")
    if failure == stage:
        sys.exit(1)

if name == "sudo":
    if args[0] == "stat":
        print("hermes" if args[2] == "%U" else "1000:1000")
    elif args[0] == "cat":
        sys.exit(subprocess.call(["/bin/cat", *args[1:]]))
    elif args[0] == "systemctl":
        record("restart")
elif name == "docker":
    if "app.hermes_profiles" in args:
        action = args[args.index("app.hermes_profiles") + 1]
        if action == "prepare":
            record("prepare")
            if not os.environ["CONTEXT_TEST_UNCHANGED"]:
                print("changed main")
        elif action == "verify":
            record("verify")
            print(json.dumps({"revisions": {"default": "verified-test-version"}}))
    elif "app.hermes_config" in args:
        record("health")
elif name == "curl":
    if args[-1].endswith("/v1/hermes/profiles"):
        Path(args[args.index("-o") + 1]).write_text('{"prefix":"marcel-","profiles":[]}')
    elif args[-1].endswith("/v1/hermes/profiles/applied"):
        record("ack" if "--data-binary" in args else "revoke")
elif name == "git":
    if args[0] == "rev-parse":
        print("unchanged-main")
elif name == "sha256sum":
    sys.stdin.read()
    print("test-digest  -")
''')
    stub.chmod(0o755)
    for command in ("sudo", "docker", "curl", "git", "sha256sum", "flock"):
        (binaries / command).symlink_to(stub)
    env = os.environ | {"PATH": str(binaries) + os.pathsep + os.environ["PATH"],
                        "CONTEXT_TEST_FAILURE": failure, "CONTEXT_TEST_TRACE": str(trace),
                        "CONTEXT_TEST_UNCHANGED": "1" if case == "skills-only" else "",
                        "HEALTH_TRIES": "1"}
    completed = subprocess.run(["bash", str(deploy / script.name)], env=env, capture_output=True,
                               text=True, timeout=15)
    assert completed.returncode == 0, completed.stdout + completed.stderr
    stages = trace.read_text().splitlines()
    expected = ["revoke", "prepare", "restart", "health", "verify", "ack"]
    expected_stages = expected[:expected.index(failure) + 1] if failure else expected
    assert stages == expected_stages
    assert (backend / ".hermes-profiles-applied").exists() == (not failure)
