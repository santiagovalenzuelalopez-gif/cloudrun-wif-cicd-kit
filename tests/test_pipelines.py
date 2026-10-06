"""Las lecciones del kit, convertidas en comprobaciones: si una plantilla se edita y rompe alguna,
el CI falla (cada regla corresponde a un fallo real documentado en docs/TROUBLESHOOTING.md)."""

import re
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parent.parent
PIPELINES = sorted((ROOT / "pipelines").rglob("*.yml"))
BUILD_PIPELINES = [p for p in PIPELINES if "gcloud builds submit" in p.read_text(encoding="utf-8")]
CLOUDBUILD = ROOT / "examples" / "cloudbuild.yaml"


def load(path: Path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def walk(node):
    """Todos los diccionarios del documento (pasos, jobs, etapas...)."""
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for item in node:
            yield from walk(item)


def ids(paths):
    return [p.relative_to(ROOT).as_posix() for p in paths]


@pytest.mark.parametrize("path", [*PIPELINES, CLOUDBUILD], ids=ids([*PIPELINES, CLOUDBUILD]))
def test_every_yaml_parses(path):
    assert load(path) is not None


@pytest.mark.parametrize("path", PIPELINES, ids=ids(PIPELINES))
def test_federated_auth_step_never_ignores_failures(path):
    """Con continueOnError, un canje de token fallido deja seguir los pasos siguientes SIN autenticar."""
    auth_steps = [n for n in walk(load(path)) if str(n.get("task", "")).startswith("GcpWifAuth@")]
    for step in auth_steps:
        assert "continueOnError" not in step, f"{path.name}: GcpWifAuth no debe llevar continueOnError"


@pytest.mark.parametrize("path", BUILD_PIPELINES, ids=ids(BUILD_PIPELINES))
class TestBuildSubmit:
    def text(self, path):
        return path.read_text(encoding="utf-8")

    def test_staging_dir_is_explicit(self, path):
        # sin él, gcloud lista buckets del proyecto (storage.buckets.list) y la SA federada no debe tenerlo
        assert "--gcs-source-staging-dir=" in self.text(path)

    def test_commit_sha_is_passed_explicitly(self, path):
        # Cloud Build solo rellena COMMIT_SHA en triggers: con `builds submit` el tag quedaría vacío
        assert "COMMIT_SHA=$(Build.SourceVersion)" in self.text(path)

    def test_build_runs_as_a_separate_service_account(self, path):
        assert "--service-account=" in self.text(path)

    def test_no_static_credentials(self, path):
        text = self.text(path).lower()
        for forbidden in ("gcloud auth activate-service-account", "--key-file", "credentials.json", "private_key"):
            assert forbidden not in text


def test_deploy_template_authenticates_through_the_shared_template():
    doc = load(ROOT / "pipelines" / "templates" / "deploy-via-cloudbuild.yml")
    uses = [s.get("template") for s in doc["steps"] if "template" in s]
    assert uses == ["gcp-auth.yml"]
    params = {p["name"] for p in doc["parameters"]}
    assert {"serviceConnection", "projectId", "serviceName"} <= params


def test_standard_pipeline_does_not_deploy_from_pull_requests():
    # un PR (p. ej. de una rama ajena) no debe poder disparar un despliegue con la identidad federada
    assert load(ROOT / "pipelines" / "azure-pipelines.yml")["pr"] == "none"
    assert load(ROOT / "pipelines" / "azure-pipelines.prod.yml")["pr"] == "none"


def test_prod_pipeline_requires_an_environment_and_only_main():
    doc = load(ROOT / "pipelines" / "azure-pipelines.prod.yml")
    assert doc["trigger"]["branches"]["include"] == ["main"]
    deployments = [n for n in walk(doc) if "deployment" in n]
    assert deployments and all("environment" in d for d in deployments)


# --- cloudbuild.yaml de referencia -------------------------------------------------------------------


def test_cloudbuild_defines_every_substitution_it_uses():
    text = CLOUDBUILD.read_text(encoding="utf-8")
    used = set(re.findall(r"\$\{(_[A-Z0-9_]+)\}", text))
    defined = set(load(CLOUDBUILD)["substitutions"])
    assert used <= defined, f"substitutions sin definir: {used - defined}"


def test_cloudbuild_image_tag_uses_commit_sha_and_is_pushed():
    doc = load(CLOUDBUILD)
    assert all("${COMMIT_SHA}" in image for image in doc["images"])
    assert any(s.get("id") == "push" for s in doc["steps"])


def test_cloudbuild_service_is_private_and_secrets_are_not_plain_env_vars():
    text = CLOUDBUILD.read_text(encoding="utf-8")
    assert "--no-allow-unauthenticated" in text
    assert "--allow-unauthenticated" not in text.replace("--no-allow-unauthenticated", "")
    env_flag = next(line for line in text.splitlines() if line.strip().startswith("- --set-env-vars="))
    assert not re.search(r"(PASSWORD|SECRET|TOKEN|API_KEY|PRIVATE)", env_flag.upper())


def test_cloudbuild_scales_to_zero_by_default_for_non_production():
    assert load(CLOUDBUILD)["substitutions"]["_MIN_INSTANCES"] == "0"
