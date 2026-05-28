from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

project = "Pandemic Exercise Simulator"
author = "TACC"
copyright = "2026, TACC"

extensions = [
    "myst_parser",
    "sphinx.ext.mathjax",
    "sphinx.ext.autosectionlabel",
]

source_suffix = {
    ".md": "markdown",
    ".rst": "restructuredtext",
}

master_doc = "index"
html_theme = "sphinx_rtd_theme"
html_static_path = ["_static"]

myst_enable_extensions = [
    "dollarmath",
    "amsmath",
    "colon_fence",
]

autosectionlabel_prefix_document = True
nitpicky = False
exclude_patterns = ["_build", "Thumbs.db", ".DS_Store"]
