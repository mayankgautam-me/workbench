#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# The reusable GitHub workflows in ci-templates/.github/workflows/ (v1.7). Parsed with PyYAML and checked on the raw
# text, so the comments count too. Nothing here runs a workflow: a real run needs the repo, the secrets and the runners.

WF="$BATS_TEST_DIRNAME/../ci-templates/.github/workflows"

setup() {
  command -v python3 >/dev/null 2>&1 || skip "python3 is not installed"
  python3 -c "import yaml" 2>/dev/null || skip "PyYAML is not installed (python3 -m pip install pyyaml)"
}

# check <name>: runs one named check of the workflows in $WF, printing each failure; exit 1 when there is one.
check() {
  python3 - "$WF" "$1" <<'PY'
import glob, os, re, sys, yaml

wf_dir, name = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(wf_dir, "*.yml")))
fails = []

KINDS = {"app-android", "app-flutter", "app-tauri", "app-xcode", "arm-gcc", "circuitpython", "cloud-worker",
         "docker", "espidf", "go", "hardware", "pio", "python", "web-pages", "zephyr"}
PINS = {
    "actions/checkout": "3d3c42e5aac5ba805825da76410c181273ba90b1",
    "actions/upload-artifact": "cf430e030ddbb5b0abf93d22962f4752f3646cd9",
    "actions/download-artifact": "9000827ccba6bdab643e8b6fd33ac0654aef8333",
    "actions/cache": "55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
    # the restore and save halves of actions/cache, same repo and pin (zephyr: save right after setup)
    "actions/cache/restore": "55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
    "actions/cache/save": "55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
}
VARS = {"SECRETS_REPO", "KICAD_LIBRARY_REPO", "KICAD_LIB_PREFIX", "STD_APT_PACKAGES", "STD_IBOM_COMMIT", "MACOS_CI", "STD_RUNNER", "STD_RUNNER_WINDOWS", "STD_RUNNER_MACOS", "STD_RUNNER_LINUX_ARM"}
SETUP_STEP = re.compile(r"^(Install|Check out|Git setting|Get |Keep |Log in|Export)")
FORBIDDEN = re.compile(r"gitlab|glab|CI_|GITLAB|packages/generic|\brules:|\bextends:", re.IGNORECASE)


def load(f):
    return yaml.safe_load(open(f))


def on_of(d):
    return d.get("on", d.get(True))


def jobs_of(d):
    return d.get("jobs", {})


def runs(job):
    for st in job.get("steps", []):
        if "run" in st:
            yield st.get("name", ""), st["run"]


def needs_list(job):
    n = job.get("needs", [])
    return [n] if isinstance(n, str) else n


def check_yaml():
    for f in files:
        d = load(f)
        if not isinstance(d, dict) or "jobs" not in d:
            fails.append(f"{os.path.basename(f)}: no jobs")
        on = on_of(d)
        if not isinstance(on, dict) or list(on.keys()) != ["workflow_call"]:
            fails.append(f"{os.path.basename(f)}: on: must be workflow_call only")


def check_names():
    kinds = {os.path.basename(f)[:-4] for f in files}
    if kinds != KINDS:
        fails.append(f"kinds are {sorted(kinds)}, expected {sorted(KINDS)}")
    for f in files:
        first = open(f).readline()
        kind = os.path.basename(f)[:-4]
        if f"project-standard ci-templates v1.7: {kind}" not in first:
            fails.append(f"{kind}.yml: header line does not name v1.7 and the kind")
        if f"workflows/{kind}.yml@v1.7" not in open(f).read():
            fails.append(f"{kind}.yml: header has no uses: line with @v1.7")


def check_uses():
    for f in files:
        for n, line in enumerate(open(f), 1):
            m = re.match(r"^\s*(?:- )?uses:\s*(\S+)(.*)$", line)
            if not m:
                continue
            ref, rest = m.group(1), m.group(2)
            action, _, sha = ref.partition("@")
            if action not in PINS:
                fails.append(f"{os.path.basename(f)}:{n}: {action} is not an allowed action")
                continue
            if not re.fullmatch(r"[0-9a-f]{40}", sha) or sha != PINS[action]:
                fails.append(f"{os.path.basename(f)}:{n}: {action} is not pinned to the expected full SHA")
            if not re.match(r"^\s*#\s*v\d+\.\d+\.\d+", rest):
                fails.append(f"{os.path.basename(f)}:{n}: {action} has no version comment")


def check_forbidden():
    for f in files:
        for n, line in enumerate(open(f), 1):
            if FORBIDDEN.search(line):
                fails.append(f"{os.path.basename(f)}:{n}: GitLab text: {line.strip()[:80]}")
            if "secrets: inherit" in line:
                fails.append(f"{os.path.basename(f)}:{n}: secrets: inherit")


def check_run_lines():
    for f in files:
        for jid, job in jobs_of(load(f)).items():
            for sname, body in runs(job):
                lines = [l.strip() for l in body.split("\n") if l.strip()]
                if any(l.startswith(("make ", 'env -u SOPS_AGE_KEY make ')) for l in lines):
                    for l in lines:
                        if l.startswith("make ") and "$PART-" not in l and "make -" not in l:
                            fails.append(f"{os.path.basename(f)} {jid}: make without $PART: {l}")
                    continue
                if not SETUP_STEP.match(sname):
                    fails.append(f"{os.path.basename(f)} {jid}: non-make run in step {sname!r}")


def check_setup_key():
    count = 0
    for f in files:
        text = open(f).read()
        for m in re.finditer(r'make "\$PART-setup"', text):
            line = text[text.rfind("\n", 0, m.start()) + 1: text.find("\n", m.start())]
            count += 1
            if "env -u SOPS_AGE_KEY make" not in line:
                fails.append(f"{os.path.basename(f)}: setup without env -u SOPS_AGE_KEY: {line.strip()}")
    if count < 20:
        fails.append(f"only {count} setup lines found")


def check_job_env_keys():
    for f in files:
        for jid, job in jobs_of(load(f)).items():
            for k, v in (job.get("env") or {}).items():
                if "secrets." in str(v):
                    fails.append(f"{os.path.basename(f)} {jid}: job env {k} reads a secret (put it on the step)")


def check_refs():
    for f in files:
        d = load(f)
        inputs = on_of(d)["workflow_call"].get("inputs", {}) or {}
        declared = set((on_of(d)["workflow_call"].get("secrets") or {}).keys())
        text = open(f).read()
        for used in set(re.findall(r"inputs\.([a-z_]+)", text)):
            if used not in inputs:
                fails.append(f"{os.path.basename(f)}: inputs.{used} is not a declared input")
        for used in set(re.findall(r"secrets\.([A-Z_]+)", text)):
            if used not in declared:
                fails.append(f"{os.path.basename(f)}: secrets.{used} is not declared in workflow_call")
        for used in set(re.findall(r"vars\.([A-Z_]+)", text)):
            if used not in VARS:
                fails.append(f"{os.path.basename(f)}: vars.{used} is not a documented variable")
        jobs = jobs_of(d)
        for jid, job in jobs.items():
            for n in needs_list(job):
                if n not in jobs:
                    fails.append(f"{os.path.basename(f)} {jid}: needs {n}, which is not a job")


def check_gates():
    for f in files:
        for jid, job in jobs_of(load(f)).items():
            cond = str(job.get("if", ""))
            ran_prod = any("CONFIRM=production" in body for _, body in runs(job))
            if ran_prod and "inputs.confirm == 'production'" not in cond:
                fails.append(f"{os.path.basename(f)} {jid}: production job is not gated by inputs.confirm")
            if ran_prod and "failure()" not in cond:
                fails.append(f"{os.path.basename(f)} {jid}: production job does not check the needed jobs")
            if any("github-release" in body for _, body in runs(job)):
                if "inputs.run_release" not in cond:
                    fails.append(f"{os.path.basename(f)} {jid}: release job is not gated by inputs.run_release")
                if (job.get("permissions") or {}).get("contents") != "write":
                    fails.append(f"{os.path.basename(f)} {jid}: release job lacks contents: write")
                if not {"check", "build"} <= set(needs_list(job)):
                    fails.append(f"{os.path.basename(f)} {jid}: release job does not need check and build")
            if str(job.get("runs-on", "")).startswith("macos") and "vars.MACOS_CI == 'true'" not in cond:
                fails.append(f"{os.path.basename(f)} {jid}: macOS job is not gated by MACOS_CI")


def check_secrets_steps():
    for f in files:
        for jid, job in jobs_of(load(f)).items():
            for st in job.get("steps", []):
                if "secrets" in str(st.get("uses", "")):
                    fails.append(f"{os.path.basename(f)} {jid}: unexpected uses")
            decrypts = any("SECRETS_DIR" in str(job.get("env", {})) for _ in [0])
            has_checkout = any("secrets repo" in st.get("name", "") for st in job.get("steps", []))
            if decrypts and not has_checkout and jid not in ("check",):
                # a job that sets SECRETS_DIR must check the secrets repo out itself
                fails.append(f"{os.path.basename(f)} {jid}: SECRETS_DIR without a secrets checkout")


def check_mise():
    sets = set()
    for f in files:
        text = open(f).read()
        if "mise_sha=" not in text:
            continue  # hardware has no mise step (v8 had none either)
        if "mise_v=v2026.11.3" not in text:
            fails.append(f"{os.path.basename(f)}: mise version is not v2026.11.3")
        shas = set(re.findall(r"mise_sha=([0-9a-f]{64})", text))
        if len(shas) != 4:
            fails.append(f"{os.path.basename(f)}: {len(shas)} distinct mise digests, expected 4")
        sets.add(frozenset(shas))
    if len(sets) != 1:
        fails.append("the mise digests differ between files")
    linux = {"837acae6defb8c9ad74823f6e38856633bacb04c65c1ac67d952749847543bd9",
             "13547a80d1dc2d5f81bb183023732f4981486e894d060e30993cc4364b4af51d"}
    if sets and not linux <= set(next(iter(sets))):
        fails.append("the Linux mise digests are not the v8 pins")


def check_images():
    for f in files:
        for jid, job in jobs_of(load(f)).items():
            c = job.get("container")
            img = c if isinstance(c, str) else (c or {}).get("image", "")
            if not img:
                continue
            if img.endswith(":latest") or (":" not in img and "@" not in img):
                fails.append(f"{os.path.basename(f)} {jid}: image {img} is not pinned")


CHECKS = {
    "yaml": check_yaml, "names": check_names, "uses": check_uses, "forbidden": check_forbidden,
    "run": check_run_lines, "setup": check_setup_key, "jobenv": check_job_env_keys, "refs": check_refs,
    "gates": check_gates, "secrets": check_secrets_steps, "mise": check_mise, "images": check_images,
}
CHECKS[name]()
for f in fails:
    print(f)
sys.exit(1 if fails else 0)
PY
}

@test "every reusable workflow parses as YAML and is workflow_call only" {
  run check yaml
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "there is one workflow per kind, named for the kind, with the v1.7 header and the uses: line" {
  run check names
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "the GitLab template files are gone from ci-templates and from the project scaffold" {
  [ -z "$(ls "$BATS_TEST_DIRNAME/../ci-templates/"*.yml 2>/dev/null)" ]
  [ ! -e "$BATS_TEST_DIRNAME/../templates/project/.gitlab-ci.yml" ]
}

@test "every uses: is one of the five actions/* pinned by a full SHA with a version comment" {
  run check uses
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "no GitLab or glab text, no CI_ variables, no rules:, extends:, packages/generic, no secrets: inherit" {
  run check forbidden
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "every script line calls make, except the explicit setup steps (Install, Check out, Git setting, Get, Keep, Log in, Export)" {
  run check run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "every dependency install runs with the CI key unset" {
  run check setup
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "no job-level env reads a secret: keys reach the steps that decrypt, never a whole job" {
  run check jobenv
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "every needs, inputs., secrets. and vars. reference names that exist and are declared" {
  run check refs
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "production jobs need confirm=production; release jobs need run_release, contents: write and check and build; macOS jobs need MACOS_CI" {
  run check gates
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "a job that sets SECRETS_DIR checks the secrets repo out itself" {
  run check secrets
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "mise is installed from the pinned v2026.11.3 tarballs with four sha256 digests, the same in every file" {
  run check mise
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "every container image is pinned by tag or digest, never latest" {
  run check images
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "zephyr check and build keep the NCS workspace in the Actions cache per NCS version, saved right after setup" {
  python3 - "$WF/zephyr.yml" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
for jid in ("check", "build"):
    names = [s.get("name", "") for s in jobs[jid]["steps"]]
    steps = {s.get("name", ""): s for s in jobs[jid]["steps"]}
    i = names.index("Install dependencies (no CI key)")
    get, restore, save = names[i - 2], names[i - 1], names[i + 1]
    assert "--eval" in steps[get]["run"] and "_NCS_DIR" in steps[get]["run"], (jid, get)
    r, s = steps[restore], steps[save]
    assert r["uses"].startswith("actions/cache/restore@") and s["uses"].startswith("actions/cache/save@"), jid
    for st in (r, s):
        assert st["with"]["path"] == "${{ steps.ncs.outputs.dir }}", jid
        assert st["with"]["key"].startswith("zephyr-ncs-${{ steps.ncs.outputs.version }}"), jid
    assert r["with"]["key"] == s["with"]["key"], jid
    assert "steps.ncs-cache.outputs.cache-hit != 'true'" in s["if"], jid
PY
  grep -q '/opt/toolchain-env.sh' "$WF/zephyr.yml"
}

@test "cloud-worker and web-pages: the tag deploys production (deploy, not promote), then the notes-only Release" {
  python3 - "$WF/cloud-worker.yml" "$WF/web-pages.yml" <<'PY'
import sys, yaml
for f in sys.argv[1:]:
    jobs = yaml.safe_load(open(f))["jobs"]
    assert "deploy-production-only" not in jobs, f
    # production: the part's tag (release.yml passes confirm) or a dispatch by hand, never a branch push; one job
    # for a part with staging and a production-only one
    p = jobs["deploy-production"]
    cond = p["if"]
    for want in ("inputs.confirm == 'production'", "github.ref_type == 'tag'", "github.event_name == 'workflow_dispatch'"):
        assert want in cond, (f, want, cond)
    assert "production_only" not in cond, (f, cond)
    runs = [s.get("run", "") for s in p["steps"]]
    assert any('make "$PART-deploy" ENV=production CONFIRM=production' in r for r in runs), f
    assert not any("promote" in r for r in runs), f
    assert not any("download-artifact" in str(s.get("uses", "")) for s in p["steps"]), f
    assert p["permissions"] == {"contents": "read"}, (f, p["permissions"])
    assert p["concurrency"]["cancel-in-progress"] is False and "inputs.part" in p["concurrency"]["group"], f
    # staging: a push to main, not for a production-only part; no staging record kept for CI
    s = jobs["deploy-staging"]
    assert "inputs.deploy_staging" in s["if"] and "!inputs.production_only" in s["if"], f
    assert "staging-record" not in str(s["steps"]), f
    # the Release only after a successful production deploy, with the notes only (no LFS, no packages)
    r = jobs["release"]
    assert "deploy-production" in r["needs"], f
    assert "needs.deploy-production.result == 'success'" in r["if"], (f, r["if"])
    names = [st.get("name", "") for st in r["steps"]]
    assert not any("LFS" in n or n.startswith("Install dependencies") for n in names), (f, names)
    assert any('make "$PART-github-release"' in st.get("run", "") for st in r["steps"]), f
PY
}

@test "the KiCad image pin and the InteractiveHtmlBom pin are kept from v8" {
  grep -q 'kicad/kicad:10.0.8@sha256:3f4a01786dfbe803a65f345c3342b765db9add913f5e9448f8356793714ddc34' "$WF/hardware.yml"
  grep -q '5c192e794cd66fde04bab11810601b711bf8581b' "$WF/hardware.yml"
  grep -q 'INTERACTIVE_HTML_BOM_NO_DISPLAY: "1"' "$WF/hardware.yml"
}

@test "the README and the workflows name the public mayankgautam-me/ci-templates, with no Access step for it (1.7)" {
  README="$BATS_TEST_DIRNAME/../ci-templates/README.md"
  grep -q 'uses: mayankgautam-me/ci-templates/.github/workflows/cloud-worker.yml@v1.7' "$README"
  [ "$(grep -c '<owner>/ci-templates' "$README")" -eq 0 ]
  [ "$(grep -c 'Accessible from repositories owned by the same user' "$README")" -eq 0 ]
  grep -q 'This repository is public' "$README"
  for f in "$WF"/*.yml; do
    grep -q "uses: mayankgautam-me/ci-templates/.github/workflows/$(basename "$f")@v1.7" "$f" ||
      { echo "$f does not name mayankgautam-me/ci-templates"; false; }
  done
}

@test "the README documents the v1.7 call shape, the inputs, the secrets and the four variables" {
  README="$BATS_TEST_DIRNAME/../ci-templates/README.md"
  grep -q 'workflows/cloud-worker.yml@v1.7' "$README"
  for v in SECRETS_REPO KICAD_LIBRARY_REPO STD_APT_PACKAGES MACOS_CI SECRETS_DEPLOY_KEY SOPS_AGE_KEY KICAD_LIBRARY_DEPLOY_KEY; do
    grep -q "$v" "$README" || { echo "README does not mention $v"; false; }
  done
  [ "$(wc -l <"$README")" -lt 240 ]
}
