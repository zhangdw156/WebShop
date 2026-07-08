#!/usr/bin/env bash
set -euo pipefail

DATA_MODE="small"
HF_DATASET_REPO="${HF_DATASET_REPO:-zhangdw/webshop}"
HF_SMALL_ARCHIVE_PATH="${HF_SMALL_ARCHIVE_PATH:-raw/webshop-small.tar.gz}"
HF_SMALL_ARCHIVE_URL="${HF_SMALL_ARCHIVE_URL:-https://huggingface.co/datasets/${HF_DATASET_REPO}/resolve/main/${HF_SMALL_ARCHIVE_PATH}}"

helpFunction()
{
  local exit_code="${1:-1}"
  cat <<EOF
Usage: $0 [-d small]

Sets up WebShop with the small dataset. This fork defaults to small mode and
only supports small mode; '-d all' is intentionally unsupported.

Environment overrides:
  HF_DATASET_REPO        Dataset repo to download from (default: zhangdw/webshop)
  HF_SMALL_ARCHIVE_PATH  Archive path in the dataset repo (default: raw/webshop-small.tar.gz)
  HF_SMALL_ARCHIVE_URL   Full archive URL override
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

  echo "Downloading WebShop small data from ${HF_SMALL_ARCHIVE_URL}"
  python - "${HF_SMALL_ARCHIVE_URL}" "${archive}" <<'PY'
import sys
import urllib.request

url, output = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(url) as response, open(output, "wb") as handle:
    while True:
        chunk = response.read(1024 * 1024)
        if not chunk:
            break
        handle.write(chunk)
PY

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

CONDA_TOOL=$(choose_conda_tool)
echo "Using ${CONDA_TOOL} for environment packages."

# Install Python Dependencies
pip install -r requirements.txt

# Install Environment Dependencies via conda/mamba
"${CONDA_TOOL}" install -y -c pytorch faiss-cpu
"${CONDA_TOOL}" install -y -c conda-forge openjdk=11

# Download the small dataset from Hugging Face into data/.
download_small_data

# Download spaCy large NLP model
python -m spacy download en_core_web_lg

# Build search engine index
cd search_engine
mkdir -p resources resources_100 resources_1k resources_100k
python convert_product_file_format.py # convert items.json => required doc format
mkdir -p indexes
./run_indexing.sh
cd ..

# Create logging folder. Optional MTurk examples are no longer downloaded from Google Drive.
mkdir -p user_session_logs/mturk
