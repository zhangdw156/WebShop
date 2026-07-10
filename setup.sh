#!/usr/bin/env bash
set -euo pipefail

DATA_MODE="small"
HF_DATASET_REPO="${HF_DATASET_REPO:-zhangdw/webshop}"
HF_SMALL_ARCHIVE_PATH="${HF_SMALL_ARCHIVE_PATH:-raw/webshop-small.tar.gz}"
HF_OFFICIAL_ENDPOINT="${HF_OFFICIAL_ENDPOINT:-https://huggingface.co}"
HF_MIRROR_ENDPOINT="${HF_MIRROR_ENDPOINT:-https://hf-mirror.com}"
HF_ENDPOINT="${HF_ENDPOINT:-}"
HF_DOWNLOAD_TIMEOUT="${HF_DOWNLOAD_TIMEOUT:-20}"
HF_OFFICIAL_ENDPOINT="${HF_OFFICIAL_ENDPOINT%/}"
HF_MIRROR_ENDPOINT="${HF_MIRROR_ENDPOINT%/}"
HF_ENDPOINT="${HF_ENDPOINT%/}"
HF_SMALL_ARCHIVE_URL="${HF_SMALL_ARCHIVE_URL:-}"
HF_SPACY_MODEL_PATH="${HF_SPACY_MODEL_PATH:-models/spacy/en_core_web_sm-3.3.0-py3-none-any.whl}"
HF_SPACY_MODEL_URL="${HF_SPACY_MODEL_URL:-}"

helpFunction()
{
  local exit_code="${1:-1}"
  cat <<EOF
Usage: $0 [-d small]

Sets up WebShop with the small dataset. This fork defaults to small mode and
only supports small mode; '-d all' is intentionally unsupported.

Environment overrides:
  HF_ENDPOINT            Force a single Hugging Face endpoint
                         (unset: try official, then mirror automatically)
  HF_OFFICIAL_ENDPOINT   Official endpoint (default: https://huggingface.co)
  HF_MIRROR_ENDPOINT     Automatic fallback endpoint (default: https://hf-mirror.com)
  HF_DOWNLOAD_TIMEOUT    Per-endpoint timeout in seconds (default: 20)
  HF_DATASET_REPO        Dataset repo to download from (default: zhangdw/webshop)
  HF_SMALL_ARCHIVE_PATH  Archive path in the dataset repo (default: raw/webshop-small.tar.gz)
  HF_SMALL_ARCHIVE_URL   Full archive URL override (disables endpoint fallback)
  HF_SPACY_MODEL_PATH    spaCy wheel path in the dataset repo
  HF_SPACY_MODEL_URL     Full spaCy wheel URL override (disables endpoint fallback)
  WEBSHOP_FORCE_DATA_DOWNLOAD=1  Re-download even if data files already exist
EOF
  exit "${exit_code}"
}

while getopts ":d:h" flag
do
  case "${flag}" in
    d) DATA_MODE=${OPTARG};;
    h) helpFunction 0;;
    :) echo "[ERROR]: Missing argument for -${OPTARG}"; helpFunction;;
    \?) echo "[ERROR]: Unknown option -${OPTARG}"; helpFunction;;
  esac
done

if [[ "${DATA_MODE}" != "small" ]]; then
  echo "[ERROR]: Only small mode is supported in this fork; received '-d ${DATA_MODE}'."
  helpFunction
fi

choose_conda_tool() {
  if command -v conda >/dev/null 2>&1; then
    echo "conda"
  elif command -v mamba >/dev/null 2>&1; then
    echo "mamba"
  else
    cat >&2 <<'EOF'
[ERROR]: setup requires conda or mamba to install environment packages.
Please install one of: conda, Miniconda, mamba, or micromamba.
EOF
    return 1
  fi
}

download_url() {
  local url="$1"
  local output="$2"
  python - "${url}" "${output}" "${HF_DOWNLOAD_TIMEOUT}" <<'PY'
import sys
import urllib.request

url, output, timeout = sys.argv[1], sys.argv[2], float(sys.argv[3])
try:
    with urllib.request.urlopen(url, timeout=timeout) as response, open(output, "wb") as handle:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            handle.write(chunk)
except Exception as exc:
    print(f"[ERROR]: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}

download_hf_file() {
  local repo_path="$1"
  local output="$2"
  local override_url="${3:-}"
  local -a urls=()

  if [[ -n "${override_url}" ]]; then
    urls=("${override_url}")
  elif [[ -n "${HF_ENDPOINT}" ]]; then
    urls=("${HF_ENDPOINT}/datasets/${HF_DATASET_REPO}/resolve/main/${repo_path}")
  else
    urls=(
      "${HF_OFFICIAL_ENDPOINT}/datasets/${HF_DATASET_REPO}/resolve/main/${repo_path}"
      "${HF_MIRROR_ENDPOINT}/datasets/${HF_DATASET_REPO}/resolve/main/${repo_path}"
    )
  fi

  local url
  local attempt=0
  local total="${#urls[@]}"
  for url in "${urls[@]}"; do
    attempt=$((attempt + 1))
    echo "Downloading ${repo_path} from ${url}"
    if download_url "${url}" "${output}"; then
      return 0
    fi
    rm -f "${output}"
    if (( attempt < total )); then
      echo "[WARN]: Download failed; trying the fallback Hugging Face endpoint." >&2
    fi
  done

  echo "[ERROR]: Unable to download ${repo_path} from the configured Hugging Face endpoint(s)." >&2
  return 1
}

required_data_present() {
  [[ -s data/items_shuffle_1000.json ]] && \
  [[ -s data/items_ins_v2_1000.json ]] && \
  [[ -s data/items_human_ins.json ]]
}

download_small_data() {
  if [[ "${WEBSHOP_FORCE_DATA_DOWNLOAD:-0}" != "1" ]] && required_data_present; then
    echo "Small WebShop data already present under data/; skipping download."
    return 0
  fi

  mkdir -p data
  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "${tmpdir}"' RETURN
  local archive="${tmpdir}/webshop-small.tar.gz"

  download_hf_file "${HF_SMALL_ARCHIVE_PATH}" "${archive}" "${HF_SMALL_ARCHIVE_URL}"

  python - "${archive}" "$(pwd)" <<'PY'
import os
import sys
import tarfile
from pathlib import Path

archive = Path(sys.argv[1])
destination = Path(sys.argv[2]).resolve()
required = {
    "data/items_shuffle_1000.json",
    "data/items_ins_v2_1000.json",
    "data/items_human_ins.json",
}
with tarfile.open(archive, "r:gz") as tar:
    names = {member.name for member in tar.getmembers() if member.isfile()}
    missing = required - names
    if missing:
        raise SystemExit(f"Archive missing required files: {sorted(missing)}")
    for member in tar.getmembers():
        target = (destination / member.name).resolve()
        if target != destination and not str(target).startswith(str(destination) + os.sep):
            raise SystemExit(f"Unsafe tar entry outside destination: {member.name}")
    tar.extractall(destination)
PY

  if ! required_data_present; then
    echo "[ERROR]: WebShop small data download/extract did not produce required files." >&2
    return 1
  fi
  echo "WebShop small data is ready under data/."
}

install_spacy_model() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "${tmpdir}"' RETURN
  local wheel="${tmpdir}/$(basename "${HF_SPACY_MODEL_PATH}")"

  download_hf_file "${HF_SPACY_MODEL_PATH}" "${wheel}" "${HF_SPACY_MODEL_URL}"

  python -m pip install --no-deps "${wheel}"
  python - <<'PY'
import spacy

spacy.load("en_core_web_sm")
PY
  echo "spaCy model en_core_web_sm is ready."
}

CONDA_TOOL=$(choose_conda_tool)
echo "Using ${CONDA_TOOL} for environment packages."

# Install Python Dependencies
pip install -r requirements.txt

# Install Environment Dependencies via conda/mamba
"${CONDA_TOOL}" install -y -c pytorch faiss-cpu
"${CONDA_TOOL}" install -y -c conda-forge openjdk=11

# Download the small dataset from Hugging Face into data/.
download_small_data

# Install the spaCy English model used by web_agent_site/engine/goal.py.
install_spacy_model

# Build search engine index
cd search_engine
mkdir -p resources resources_100 resources_1k resources_100k
python convert_product_file_format.py # convert items.json => required doc format
mkdir -p indexes
./run_indexing.sh
cd ..

# Create logging folder. Optional MTurk examples are no longer downloaded from Google Drive.
mkdir -p user_session_logs/mturk
