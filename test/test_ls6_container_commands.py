"""Offline checks for container invocation and automatic LS6 image selection."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
class ContainerCommandsTest(unittest.TestCase):
    def test_runtime_wrapper_cleans_injected_host_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            image = directory / "image with spaces.sif"
            image.touch()
            apptainer = directory / "apptainer"
            apptainer.write_text('#!/usr/bin/env python3\nimport json, os, sys\nprint(json.dumps({"args": sys.argv[1:], "injected": os.environ.get("APPTAINERENV_LD_LIBRARY_PATH")}))\n')
            apptainer.chmod(0o755)
            env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ["PATH"],
                       APPTAINERENV_LD_LIBRARY_PATH="/host/intel", APPTAINERENV_PATH="/host/bin")
            result = subprocess.run(["bash", str(REPO / "scripts/ls6_container_exec.sh"),
                                     "--image", str(image), "Rscript", "script with spaces.R"],
                                    env=env, check=True, capture_output=True, text=True)
            invocation = json.loads(result.stdout)
            self.assertIsNone(invocation["injected"])
            self.assertIn("--cleanenv", invocation["args"])
            self.assertIn("R_PROFILE_USER=" + str(REPO / "containers/ls6-runtime.Rprofile"), invocation["args"])
            self.assertEqual(invocation["args"][-3:], [str(image), "Rscript", "script with spaces.R"])
            # Ordinary LS6 generation needs no image override: resolve $WORK
            # on the compute node, not on the machine generating commands.
            default_image = directory / "pes_pipeline_r442_py312.sif"
            default_image.touch()
            env.pop("PES_CONTAINER_IMAGE", None)
            env["WORK"] = str(directory)
            default_args = ["bash", str(REPO / "scripts/ls6_container_exec.sh"),
                            "poetry", "run", "python3", "--version"]
            result = subprocess.run(default_args, env=env, check=True,
                                    capture_output=True, text=True)
            self.assertEqual(json.loads(result.stdout)["args"][-5:],
                             [str(default_image), "poetry", "run", "python3", "--version"])
            env["PES_CONTAINER_IMAGE"] = str(image)
            result = subprocess.run(default_args, env=env, check=True,
                                    capture_output=True, text=True)
            self.assertEqual(json.loads(result.stdout)["args"][-5:],
                             [str(image), "poetry", "run", "python3", "--version"])


if __name__ == "__main__":
    unittest.main()
