# REAL Video Enhancer

REAL Video Enhancer のローカル実行用リポジトリです。GUI 実行ファイル、Python backend、CLI 補助スクリプト、Google Colab 用ノートブックを含みます。

## できること

- 付属の `REAL-Video-Enhancer` から GUI を起動
- `backend/rve-backend.py` で動画のアップスケール、フレーム補間、動画情報確認を実行
- `scripts/rve-upscale.sh` でよく使う backend オプションを簡単に実行
- `rve_colab_upscale.ipynb` で Colab 上の GPU を使って 2x アップスケール

## ディレクトリ構成

```text
.
├── REAL-Video-Enhancer              # macOS arm64 向け GUI 実行ファイル
├── _internal/                       # GUI 実行に必要な同梱ランタイム
├── backend/
│   ├── rve-backend.py               # backend CLI
│   ├── requirements.txt             # Python 依存関係
│   ├── test_rve_backend.py          # backend テスト
│   └── src/                         # RVE backend 実装
├── input/                           # 入力動画置き場
├── models/                          # モデル置き場
├── output/                          # 出力動画置き場
├── scripts/
│   └── rve-upscale.sh               # CLI 補助スクリプト
└── rve_colab_upscale.ipynb          # Google Colab 用ノートブック
```

`input/`、`models/`、`output/` の中身と実行ログは `.gitignore` 対象です。

## GUI を起動する

```bash
scripts/rve-upscale.sh --gui
```

または、直接実行します。

```bash
./REAL-Video-Enhancer
```

## CLI でアップスケールする

入力動画とモデルを用意してから実行します。

```bash
scripts/rve-upscale.sh \
  -i input/video.mp4 \
  -o output/video_2x.mp4 \
  -m models/up2x-latest-conservative.pth \
  --backend pytorch \
  --device mps \
  --crf 18 \
  --overwrite
```

主なオプション:

- `--device auto|mps|cuda|cpu|xpu`: 推論デバイス
- `--backend pytorch|ncnn|tensorrt|directml`: backend 種別
- `--crf`: 小さいほど高品質、大きいほど軽量
- `--tilesize`: VRAM 不足時にタイルサイズを指定
- `--start` / `--end`: 指定秒数の範囲だけ処理
- `--scale-factor`: 4x モデルで 2x 出力したい場合などに指定

利用可能な backend は次で確認できます。

```bash
scripts/rve-upscale.sh --list-backends
```

動画情報だけ確認する場合:

```bash
scripts/rve-upscale.sh --info input/video.mp4
```

## Python backend を直接使う

```bash
python3 backend/rve-backend.py \
  -i input/video.mp4 \
  -o output/video_2x.mp4 \
  --ffmpeg_path /path/to/ffmpeg \
  -b pytorch \
  --device mps \
  --upscale_model models/up2x-latest-conservative.pth \
  --crf 18 \
  --video_encoder_preset libx264 \
  --video_pixel_format yuv420p \
  --overwrite
```

ヘルプ:

```bash
python3 backend/rve-backend.py --help
```

## 依存関係

Python 3.10 以上と ffmpeg が必要です。`scripts/rve-upscale.sh` は次の順で Python を探します。

1. `PYTHON_BIN` 環境変数
2. `.venv/bin/python`
3. `uv` 管理下の Python
4. `python3.12`、`python3.11`、`python3.10`、`python3`

CUDA/TensorRT/NCNN を含む backend 依存関係をまとめて入れる場合:

```bash
python3 -m pip install --pre -r backend/requirements.txt \
  --extra-index-url https://download.pytorch.org/whl/test/cu126
```

macOS で MPS を使う場合は、CUDA 専用依存関係が環境に合わないことがあります。その場合は GUI 実行ファイルを使うか、PyTorch、OpenCV、scenedetect など必要な依存関係だけを環境に合わせて入れてください。

ffmpeg は `FFMPEG_PATH` または `--ffmpeg` で明示できます。

```bash
FFMPEG_PATH=/opt/homebrew/bin/ffmpeg scripts/rve-upscale.sh --info input/video.mp4
```

## Colab で使う

`rve_colab_upscale.ipynb` を Google Colab で開き、GPU ランタイムを選んで上から順に実行します。

ノートブック内の `REPO_URL` は、自分の GitHub リポジトリ URL に変更してください。動画は Colab に直接アップロードするか、Google Drive 上のファイルを指定できます。

## テスト

backend テストは次で実行します。

```bash
python3 -m unittest backend/test_rve_backend.py
```

## 注意点

- 大きい動画や高解像度モデルは VRAM を多く使います。失敗する場合は `--tilesize`、`--device cpu`、短い `--start` / `--end` を試してください。
- `--overwrite` を付けない場合、出力ファイルが既にあると backend はエラーになります。
- `output/` の生成物、`input/` の動画、`models/` のモデルは Git 管理されません。
