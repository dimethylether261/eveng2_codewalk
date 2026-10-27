# 散歩ログの解析（debug/walk-log ブランチ）

このブランチは、Android アプリで実際に歩いたときの記録（散歩ログ）を集めて、**Claude API の利用料と、無線が鳴るかどうかを改善する**ためのものです。main にはマージしていません。

このファイルには、何を確かめたいのか、ログの取り方と読み方、これまでに分かったことをまとめています。

## 確かめたいこと

1. **鳴らなかった会話は、作るのが遅すぎたのか、そもそも近くに行かなかったのか。**
   10/27 の散歩では、作った会話40件のうち鳴ったのは5件だけで、利用料の84%が鳴らなかった会話に使われていました。原因によって対策が変わります。
   - 遅すぎた → 進む方向の先まで先読みする、通り過ぎたあともしばらく鳴らせるようにする
   - 近くに行かなかった → 先読みする場所の選び方を変える、先読みの数を減らす
2. **格上げ（Sonnet で調べ直す）は、会話を良くしているか。**
   格上げすると費用は約3倍になるのに、レビュー点が基準（3.5）に届いたのは26件中8件だけでした。点数だけでなく、**格上げ前とあとの会話を実際に読み比べて**判断します。
3. **どの工程にお金がかかっていて、どこを削れるか。**
   たとえばプロンプトキャッシュ（今は使っていない）、書き直しの回数、レビュー基準の値などです。
4. **そのほかの問題**
   - 同じ場所の会話を2回作っていないか（重複のまとめ漏れ）
   - 周辺の場所の取得（Overpass、Wikipedia）の遅れや失敗

基準値などを変える判断は、散歩ログが何回分か集まってからにします（今は実データが2回分だけです）。

## 別のPCで始めるとき

### リポジトリにないもの（別にコピーする）

| もの | 置き場所 | 説明 |
| --- | --- | --- |
| 散歩ログ | `private/code_walk_logs/` | 移動経路が入っているので、リポジトリには入れていない |
| 自分の肖像 | `private/portraits/` | なくてもビルドできる（サンプルの肖像になる） |
| debug 用の署名キー | `~/.android/debug.keystore` | スマホに入っている CODEWALK と同じキー（SHA-256 が `1A:AF:3C:33:…:8F:F5`）。違うキーでビルドすると上書きインストールできず、アンインストールが必要になる（無線ログや API キーが消える） |

`private/` は `.gitignore` に入っています。

### ビルドとインストール

Flutter と Android SDK が必要です（README の「Android app」を参照）。

```bash
cd app
dart run tool/build_apk.dart --build-name=0.2.18-walklog   # private/portraits の肖像でビルド
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Linux で `adb devices` が `no permissions` になるときは、udev のルールが必要です（`sudo apt install android-sdk-platform-tools-common`）。

## ログの取り方

1. アプリの「設定 > 開発者向け」で **散歩ログを記録** をオンにする（初期値はオフ。次の散歩から記録される）。
2. 散歩する。散歩1回につき、ファイルが1つできる（`walk_YYYYMMDD-HHMMSS.jsonl`）。
3. 同じ画面の **散歩ログを共有** で PC に送り、`private/code_walk_logs/` に置く。

ログはスマホの中だけに保存され、どこにも送られません。

## ログの読み方

```bash
python3 app/tool/walk_log_report.py summary private/code_walk_logs   # 工程・モデルごとの費用、結果、格上げの効果
python3 app/tool/walk_log_report.py passes  private/code_walk_logs   # 会話ごとに、その場所の近くを通ったか、いつ通ったか（確かめたいこと 1）
python3 app/tool/walk_log_report.py drafts  private/code_walk_logs   # 格上げ前とあとの会話の読み比べ（確かめたいこと 2）
python3 app/tool/walk_log_report.py drafts  private/code_walk_logs 泉岳寺   # 1か所だけ
```

`passes` は、作った会話を次のどれかに分けます。

- `rang`: 鳴った
- `never within 60 m`: 60 m 以内に近づかなかった
- `too late`: 近くを通ったが、会話ができる前に離れた
- `within range after ready, did not ring`: できたあとに近くにいたのに鳴らなかった（ほかの無線と重なった、頻度の制限など）
- `town/chat (no radius)`: 町の雑学と「今日は何の日」（半径で鳴るものではない）

**座標と格上げ前後の会話は、10/28 以降のログにしか入っていません**（`1504d3a` から）。それより前のログでは、`passes` と `drafts` は何も出せません。

## ログの中身

1行に1つのイベント（JSON）が入っています。すべてに `t`（UTC の時刻）と `type` があり、`pos` 以外には `user`（そのときの自分の位置と、その位置の古さ `age_s`）があります。

| type | 中身 |
| --- | --- |
| `walk_start` / `walk_end` | 設定（言語、周波数、頻度、出典の制限、開発モード）／歩いた距離と無線の数 |
| `pos` | 移動経路: 緯度・経度、速さ、精度（約5秒か10 mごと） |
| `spots` / `spots_error` / `area` | 周辺の場所の取得（件数、かかった時間）、失敗、新しい町に入った |
| `generation` | 会話1件の生成。下を参照 |
| `discover` | 町の名所探し。場所、結果、かかった時間、利用料 |
| `ring` / `answer` / `later` | 無線が鳴った／応答した／あとで（`auto` は10秒たって自動で）。会話の `generated_at` と推定の利用料、場所の座標 |
| `unavailable` / `skip` / `ask_error` | 鳴らなかった場所とその理由 |
| `status` / `location_error` / `engine` | 状態の表示、位置の取得エラー、会話エンジン内部のメッセージ |

`generation` の主な項目:

- `spot`（id、名前、種類、緯度・経度）、`theme`、`prefetch`（先読みか、その場か）、`started`、`ms`（かかった時間）
- `outcome`: `ready` / `unavailable` / `error` と `reason`
- `generated_at`: 会話を作った時刻。`ring` などの `generated_at` と同じなら、その会話が鳴った。どの `generation` にも一致しなければ、前から持っていたキャッシュの会話
- `review`: 点数、何回目の書き直しか、格上げしたか
- `usage.steps`: API の呼び出しごとの工程（research / dialogue / check / review / discover）、モデル、トークン数（`cache_write` / `cache_read` を含む）、Web 検索の回数、推定の利用料、かかった時間、`stop_reason`。research には見つかった事実の数（`facts`）もある
- `drafts`: 試した会話。`stage` が `first`（格上げなし）、`before_escalation`、`after_escalation` のどれか。それぞれに調査したモデル、事実、会話の全セリフ、レビュー。実際に使ったものに `chosen`

利用料は [claude.dart](app/lib/engine/claude.dart) の料金表からの推定です。ときどき Claude Console の実際の利用額と照らし合わせてください。

## これまでに分かったこと（10/27 の散歩、約40分・3.5 km、推定 $5.13）

- 鳴った会話は5件で、すべて町の雑学でした。個々の場所の会話は、キャッシュにあったもの（3件）しか鳴っていません。
- その場で作り始めた場所の会話は、できるまで30〜97秒（中央値74秒）かかっていました。歩く速さだと60 m の範囲にいるのは45秒ほどです。
- 格上げしたのは26件（平均 $0.168）、していないのは14件（平均 $0.051）。格上げしても26件中18件は3.5に届きませんでした。点数は3.4〜3.6に集まっています。
- 費用の内訳は、Sonnet の会話づくり 42%、Sonnet の調べ直し 32%、Sonnet のレビュー 15%、Haiku の調査 9% です。プロンプトキャッシュは使われていません。
- 1件の会話につき平均2.8回、会話を書き直していました。
- 同じ場所を2回作っていました（御田八幡神社、高輪大木戸跡）。
- Wikipedia の周辺検索で `NoSuchMethodError: [] on null` が2回起きていました（[wikipedia.dart:166](app/lib/engine/wikipedia.dart#L166)、応答の中身が空のときに確認していない）。
- Overpass が75秒でタイムアウトしたのが9回ありました。
- 無線8件のうち7件は、応答がなく自動で「あとで」になりました。

## 改善の候補（まだ手を付けていない）

1. 場所の無線が間に合うようにする（進む方向の先読み、通り過ぎたあとも鳴らせるようにする）
2. 格上げをやめる、または事実が少ないときだけにする
3. 会話づくりとレビューのシステムプロンプトにプロンプトキャッシュを使う
4. 重複のまとめ漏れと、周辺検索のエラーを直す
