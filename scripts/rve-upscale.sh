#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RVE_APP="${RVE_APP:-${APP_ROOT}/REAL-Video-Enhancer}"
BACKEND_SCRIPT="${BACKEND_SCRIPT:-${APP_ROOT}/backend/rve-backend.py}"
PYTHON_BIN="${PYTHON_BIN:-}"
FFMPEG_PATH="${FFMPEG_PATH:-}"

mode="upscale"
input=""
output=""
model=""
backend="pytorch"
device="auto"
crf="18"
encoder="libx264"
pixel_format="yuv420p"
tilesize=""
start_time=""
end_time=""
scale_override=""
overwrite="false"
extra_args=()

usage() {
  cat <<'USAGE'
REAL Video Enhancer helper

使い方:
  scripts/rve-upscale.sh --gui
  scripts/rve-upscale.sh --list-backends
  scripts/rve-upscale.sh --info input.mp4
  scripts/rve-upscale.sh -i input.mp4 -o output.mp4 -m model.pth [options]

アップスケール例:
  scripts/rve-upscale.sh \
    -i input.mp4 \
    -o output_2x.mp4 \
    -m /path/to/2x_model.pth \
    --backend pytorch \
    --device mps \
    --crf 18 \
    --overwrite

主なオプション:
  --gui                       GUI を起動
  --list-backends             利用可能な backend を表示
  --info FILE                 動画情報を表示
  -i, --input FILE            入力動画
  -o, --output FILE           出力動画
  -m, --model FILE            アップスケールモデル
  -b, --backend NAME          pytorch/ncnn/tensorrt/directml など。既定: pytorch
  --device NAME               auto/mps/cuda/cpu/xpu。既定: auto
  --ffmpeg PATH               ffmpeg のパス
  --crf VALUE                 小さいほど高品質。既定: 18
  --encoder NAME              libx264/libx265/prores など。既定: libx264
  --pixel-format FORMAT       yuv420p など。既定: yuv420p
  --tilesize N                VRAM 不足時に指定
  --start SECONDS             開始秒
  --end SECONDS               終了秒
  --scale-factor N            4x モデルを 2x 出力にしたい場合などに指定
  --overwrite                 出力ファイルを上書き
  --                          以降を rve-backend.py にそのまま渡す

環境変数:
  PYTHON_BIN=/path/to/python3
  FFMPEG_PATH=/path/to/ffmpeg
  RVE_APP=/path/to/REAL-Video-Enhancer
  BACKEND_SCRIPT=/path/to/rve-backend.py
USAGE
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

resolve_python() {
  local candidates=()
  local candidate

  if [[ -n "${PYTHON_BIN}" ]]; then
    candidates+=("${PYTHON_BIN}")
  else
    candidates+=("${APP_ROOT}/.venv/bin/python")

    for candidate in \
      "${HOME}/Library/Application Support/uv/python"/cpython-3.12*/bin/python3.12 \
      "${HOME}/Library/Application Support/uv/python"/cpython-3.11*/bin/python3.11 \
      "${HOME}/Library/Application Support/uv/python"/cpython-3.10*/bin/python3.10 \
      "${HOME}/.local/share/uv/python"/cpython-3.12*/bin/python3.12 \
      "${HOME}/.local/share/uv/python"/cpython-3.11*/bin/python3.11 \
      "${HOME}/.local/share/uv/python"/cpython-3.10*/bin/python3.10; do
      [[ -x "${candidate}" ]] && candidates+=("${candidate}")
    done

    if command -v uv >/dev/null 2>&1; then
      while IFS= read -r candidate; do
        [[ -n "${candidate}" ]] && candidates+=("${candidate}")
      done < <(
        for version in 3.12 3.11 3.10; do
          uv python find "${version}" 2>/dev/null || true
        done
      )
    fi

    candidates+=(
      python3.12
      python3.11
      python3.10
      /opt/homebrew/bin/python3.12
      /opt/homebrew/bin/python3.11
      /opt/homebrew/bin/python3.10
      python3
    )
  fi

  for candidate in "${candidates[@]}"; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      if "${candidate}" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then
        PYTHON_BIN="$(command -v "${candidate}")"
        return
      fi
    elif [[ -x "${candidate}" ]]; then
      if "${candidate}" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then
        PYTHON_BIN="${candidate}"
        return
      fi
    fi
  done

  fail "Python 3.10 以上が必要です。uv を使う場合は uv python install 3.11 を実行してください。必要なら PYTHON_BIN=/path/to/python3.11 で明示できます。"
}

resolve_ffmpeg() {
  if [[ -n "${FFMPEG_PATH}" ]]; then
    return
  fi

  if [[ -x "${APP_ROOT}/bin/ffmpeg" ]]; then
    FFMPEG_PATH="${APP_ROOT}/bin/ffmpeg"
    return
  fi

  if command -v ffmpeg >/dev/null 2>&1; then
    FFMPEG_PATH="$(command -v ffmpeg)"
    return
  fi

  fail "ffmpeg が見つかりません。--ffmpeg PATH か FFMPEG_PATH を指定してください。"
}

validate_device() {
  case "${device}" in
    mps)
      if ! "${PYTHON_BIN}" -c 'import torch; raise SystemExit(0 if torch.backends.mps.is_available() else 1)' >/dev/null 2>&1; then
        fail "この Python 環境では PyTorch MPS が利用できません。--device cpu または --device auto を指定してください。"
      fi
      ;;
  esac
}

require_backend_script() {
  [[ -f "${BACKEND_SCRIPT}" ]] || fail "backend script が見つかりません: ${BACKEND_SCRIPT}"
}

run_gui() {
  [[ -x "${RVE_APP}" ]] || fail "GUI 実行ファイルが見つからないか実行権限がありません: ${RVE_APP}"
  "${RVE_APP}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --gui)
        mode="gui"
        shift
        ;;
      --list-backends)
        mode="list-backends"
        shift
        ;;
      --info)
        mode="info"
        input="${2:-}"
        [[ -n "${input}" ]] || fail "--info には動画ファイルを指定してください。"
        shift 2
        ;;
      -i|--input)
        input="${2:-}"
        [[ -n "${input}" ]] || fail "$1 には値が必要です。"
        shift 2
        ;;
      -o|--output)
        output="${2:-}"
        [[ -n "${output}" ]] || fail "$1 には値が必要です。"
        shift 2
        ;;
      -m|--model|--upscale-model)
        model="${2:-}"
        [[ -n "${model}" ]] || fail "$1 には値が必要です。"
        shift 2
        ;;
      -b|--backend)
        backend="${2:-}"
        [[ -n "${backend}" ]] || fail "$1 には値が必要です。"
        shift 2
        ;;
      --device)
        device="${2:-}"
        [[ -n "${device}" ]] || fail "$1 には値が必要です。"
        shift 2
        ;;
      --ffmpeg)
        FFMPEG_PATH="${2:-}"
        [[ -n "${FFMPEG_PATH}" ]] || fail "$1 には値が必要です。"
        shift 2
        ;;
      --crf)
        crf="${2:-}"
        [[ -n "${crf}" ]] || fail "$1 には値が必要です。"
        shift 2
        ;;
      --encoder)
        encoder="${2:-}"
        [[ -n "${encoder}" ]] || fail "$1 には値が必要です。"
        shift 2
        ;;
      --pixel-format)
        pixel_format="${2:-}"
        [[ -n "${pixel_format}" ]] || fail "$1 には値が必要です。"
        shift 2
        ;;
      --tilesize)
        tilesize="${2:-}"
        [[ -n "${tilesize}" ]] || fail "$1 には値が必要です。"
        shift 2
        ;;
      --start)
        start_time="${2:-}"
        [[ -n "${start_time}" ]] || fail "$1 には値が必要です。"
        shift 2
        ;;
      --end)
        end_time="${2:-}"
        [[ -n "${end_time}" ]] || fail "$1 には値が必要です。"
        shift 2
        ;;
      --scale-factor)
        scale_override="${2:-}"
        [[ -n "${scale_override}" ]] || fail "$1 には値が必要です。"
        shift 2
        ;;
      --overwrite)
        overwrite="true"
        shift
        ;;
      --)
        shift
        extra_args+=("$@")
        break
        ;;
      *)
        fail "不明なオプションです: $1"
        ;;
    esac
  done
}

run_backend() {
  require_backend_script
  resolve_python
  resolve_ffmpeg
  (cd "${APP_ROOT}" && "${PYTHON_BIN}" "${BACKEND_SCRIPT}" "$@")
}

run_info() {
  [[ -n "${input}" ]] || fail "動画ファイルを指定してください。"
  [[ "${input}" == http* || -f "${input}" ]] || fail "入力動画が見つかりません: ${input}"
  resolve_ffmpeg
  run_backend --ffmpeg_path "${FFMPEG_PATH}" --print_video_info "${input}"
}

run_list_backends() {
  require_backend_script
  resolve_python
  (cd "${APP_ROOT}" && "${PYTHON_BIN}" "${BACKEND_SCRIPT}" --list_backends)
}

run_upscale() {
  [[ -n "${input}" ]] || fail "-i/--input を指定してください。"
  [[ -n "${output}" ]] || fail "-o/--output を指定してください。"
  [[ -n "${model}" ]] || fail "-m/--model を指定してください。"
  [[ "${input}" == http* || -f "${input}" ]] || fail "入力動画が見つかりません: ${input}"
  [[ -f "${model}" ]] || fail "モデルファイルが見つかりません: ${model}"
  resolve_python
  resolve_ffmpeg
  validate_device

  args=(
    -i "${input}"
    -o "${output}"
    --ffmpeg_path "${FFMPEG_PATH}"
    -b "${backend}"
    --device "${device}"
    --upscale_model "${model}"
    --crf "${crf}"
    --video_encoder_preset "${encoder}"
    --video_pixel_format "${pixel_format}"
  )

  [[ "${overwrite}" == "true" ]] && args+=(--overwrite)
  [[ -n "${tilesize}" ]] && args+=(--tilesize "${tilesize}")
  [[ -n "${start_time}" ]] && args+=(--start_time "${start_time}")
  [[ -n "${end_time}" ]] && args+=(--end_time "${end_time}")
  [[ -n "${scale_override}" ]] && args+=(--override_upscale_scale "${scale_override}")
  [[ ${#extra_args[@]} -gt 0 ]] && args+=("${extra_args[@]}")

  run_backend "${args[@]}"
}

parse_args "$@"

case "${mode}" in
  gui)
    run_gui
    ;;
  list-backends)
    run_list_backends
    ;;
  info)
    run_info
    ;;
  upscale)
    run_upscale
    ;;
  *)
    fail "内部エラー: unknown mode ${mode}"
    ;;
esac
