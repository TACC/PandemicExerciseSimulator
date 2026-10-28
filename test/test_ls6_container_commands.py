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
            apptainer.write_text('#!/usr/bin/env python3\nimport json, os, sys\nprint(json.dumps({"args": sys.argv[1:], "injected": os.environ.get("APPTAINERENV_LD_LIBRARY_PATH"), "library": os.environ.get("APPTAINERENV_PES_R_LIBRARY")}))\n')
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
            env.pop("APPTAINERENV_PES_R_LIBRARY", None)
            default_args = ["bash", str(REPO / "scripts/ls6_container_exec.sh"),
                            "poetry", "run", "python3", "--version"]
            result = subprocess.run(default_args, env=env, check=True,
                                    capture_output=True, text=True)
            self.assertEqual(json.loads(result.stdout)["args"][-5:],
                             [str(default_image), "poetry", "run", "python3", "--version"])
            self.assertEqual(json.loads(result.stdout)["library"], str(directory / "pes-r-library"))
            env["APPTAINERENV_PES_R_LIBRARY"] = str(directory / "custom library")
            env["PES_CONTAINER_IMAGE"] = str(image)
            result = subprocess.run(default_args, env=env, check=True,
                                    capture_output=True, text=True)
            self.assertEqual(json.loads(result.stdout)["args"][-5:],
                             [str(image), "poetry", "run", "python3", "--version"])
            self.assertEqual(json.loads(result.stdout)["library"], str(directory / "custom library"))
            # A fresh login exposes the module function but has not loaded Apptainer.
            module_bin = directory / "module-bin"
            module_bin.mkdir()
            apptainer.rename(module_bin / "apptainer")
            env["TEST_MODULE_BIN"] = str(module_bin)
            module_init = directory / "module-init.sh"
            module_init.write_text(
                'module() { test "$1" = load && test "$2" = tacc-apptainer || return 1; '
                'export PATH="$TEST_MODULE_BIN:$PATH"; echo module-loaded >&2; }\n')
            env["BASH_ENV"] = str(module_init)
            result = subprocess.run(default_args, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("module-loaded", result.stderr)
            self.assertEqual(json.loads(result.stdout)["library"], str(directory / "custom library"))


if __name__ == "__main__":
    unittest.main()
