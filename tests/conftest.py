import importlib.util
import pathlib
import sys

import pytest

REPO = pathlib.Path(__file__).resolve().parents[1]


def load_module(name):
    spec = importlib.util.spec_from_file_location(f"{name}_under_test", REPO / "scripts" / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def distribute():
    mod = load_module("distribute_data_access_docs")
    yield mod
    sys.modules.pop("distribute_data_access_docs_under_test", None)
