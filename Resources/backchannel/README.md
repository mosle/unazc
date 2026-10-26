# 相槌の音声

「間で相槌を返す」オプションで鳴らす音です。

- 生成: Google Gemini TTS（`gemini-3.8-flash-tts`、声 `Sulafat`）、2026-10-25
- 作り方: `scripts/make-backchannel.py`（指示文と言葉の一覧もそこにあります）
- 人の声の録音ではなく、AI で生成した音声です
- これらの音声はリポジトリの MIT ライセンスの対象外です。作者は権利を主張しません。自由に使ってください

ファイル名の先頭が鳴らす場面を表します。

| 先頭 | 場面 | 例 |
|---|---|---|
| `ack-` | ふつうの区切り | うん / ええ / はい |
| `cont-` | 長く話したあと | うんうん / なるほど / へぇ |
| `q-` | 語尾が上がったとき（ふつうの相槌と混ぜて） | うーん |

## 声を替える

`~/Library/Application Support/Unazc/backchannel` に音声を置くと、同梱の音より優先して使われます（ファイル名の付け方は同じ）。
自分の Gemini API キーで別の声に作り直すこともできます。

```sh
GEMINI_API_KEY=... python3 scripts/make-backchannel.py --voice Achird
```

モデルが別の言葉を言うことがあるので、出来たものは聞いて確かめてください。
