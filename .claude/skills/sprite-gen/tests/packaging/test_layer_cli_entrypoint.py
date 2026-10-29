# SPDX-License-Identifier: Apache-2.0
"""`sprite-gen compose-layers` is the same program as its two other launch forms.

Three entry forms reach one declaration — the console subcommand, `-m
sprite_gen.compose.compose_layers`, and the `scripts/` wrapper the SKILL.md script map
lists. A copied flag list would pass on the day it was written and drift on the
next option, so the wiring itself is pinned (same rule as
`test_recolor_cli_entrypoint.py`).
"""

from __future__ import annotations

from pathlib import Path

import pytest

from conftest import help_options as _help_options
from sprite_gen import cli
from sprite_gen.compose import compose_layers

ROOT = Path(__file__).resolve().parents[2]

EXPECTED_FLAGS = {"--run-dir", "--names", "--help"}

def test_compose_layers_subcommand_reuses_module_declaration() -> None:
    _description, add_args, run_fn = cli.COMMANDS["compose-layers"]

    assert add_args is compose_layers.add_arguments
    assert run_fn is compose_layers.run


def test_compose_layers_launch_forms_expose_the_same_flags() -> None:
    subcommand = _help_options("-m", "sprite_gen.cli", "compose-layers")
    module = _help_options("-m", "sprite_gen.compose.compose_layers")
    wrapper = _help_options(str(ROOT / "scripts" / "compose_layers.py"))

    assert subcommand == EXPECTED_FLAGS
    assert module == EXPECTED_FLAGS
    assert wrapper == EXPECTED_FLAGS


@pytest.mark.parametrize("value,expected", [
    (None, None),
    ("one", ["one"]),
    ("one,two", ["one", "two"]),
    (" one , two ", ["one", "two"]),
])
def test_parse_names_reads_a_subset_selection(value, expected) -> None:
    assert compose_layers.parse_names(value) == expected


@pytest.mark.parametrize("value", ["", ",", "one,", ",one", "one,,two", "  "])
def test_parse_names_rejects_an_empty_entry(value: str) -> None:
    """An empty entry is a typo, not a request to bake everything."""
    with pytest.raises(SystemExit):
        compose_layers.parse_names(value)
