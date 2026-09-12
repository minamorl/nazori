# nazori

Android のペンタブレット化。端末には**軌跡だけ**が薄く残り、入力そのものは
Mac へ送られる。端末側は絵を持たない。

```
Tab S11 (S Pen)  --USB/adb reverse-->  nazorid (Mac)  --+--> CGEvent (全アプリ)
                                                        +--> ws://…:40119 (paint)
```

## 構成

| 場所 | 中身 |
|---|---|
| `android/` | ペンを拾い、軌跡を描き、記録を送る Kotlin アプリ |
| `host/` | 受けて macOS のイベントへ変換する常駐 `nazorid` |
| `paint-adapter/` | WebSocket を paint の canvas へ流す ES モジュール (参照実装。本番は paint 側 `src/input/nazori.ts`) |
| `tools/` | 検証用の計器。下の実測はこれで取った |
| `PROTOCOL.md` | 40 バイト固定の有線規格 |

## 動かす

```sh
# Android
cd android && ./gradlew :app:installDebug

# Mac
cd host && swift build -c release
./scripts/usb.sh                 # adb reverse + アプリ起動 + 常駐
```

`nazorid` は既定でループバックの TCP しか開かない。Wi-Fi (UDP) は `--wifi`
を付けたときだけ開く。付けると LAN から届くようになる。

### paint (canvas.minamorl.com) へ流す

paint 側の受け口は opt-in。`usb.sh` で `nazorid` を上げたあと:

1. `https://canvas.minamorl.com/paint/?nazori=1` を開く。localStorage
   (`paint.nazori`) に残るので、以後そのブラウザでは毎回
   `ws://127.0.0.1:40119` へ繋ぎに行く。切るときは `?nazori=0`。
2. Chrome (153, macOS) は https のページから `127.0.0.1` へ WebSocket を張る
   とき Local Network Access の許可プロンプト「canvas.minamorl.com が次の許可を
   求めています: このデバイス上の他のアプリやサービスにアクセスする」を出す。
   **許可する**を押す。押すまで WebSocket は CONNECTING のまま黙って待つし、
   プロンプトは Chrome の窓が前面のときにしか出ない。拒否済みや headless では
   `net::ERR_BLOCKED_BY_LOCAL_NETWORK_ACCESS_CHECKS` で即失敗する。許可は
   origin 単位で保存される (戻すのは
   `chrome://settings/content/siteDetails?site=https://canvas.minamorl.com`)。
3. 描く。効いているかはストローク前後の画素差分で見る (線幅が筆圧に追従するか)。
   状態表示の `P:` / `dabs:` はストローク終端の callback で書かれ `dabs:0` に
   戻るので指標にならない。

受け口を入れる前の本番 paint は OS 経路 (CGEvent) しか通らず、筆圧が `1.0` に
潰れていた。paint 内の実装は `src/input/nazori.ts`
(`paint-adapter/nazori-paint.js` の TypeScript 移植)。`nazori-paint.js` は参照
実装として残す。規格を変えるときは両方を直す。

**線の位置。** `nazorid` は同じ記録を CGEvent (OS 全体、カーソルが動く) と
WebSocket の二方向へ配る。受け口が WebSocket の正規化座標だけで描くと、線が
カーソルの真下に乗らない (実測: 表示座標 (700,600) の記録が Chrome には
client (700,483) で届くのに、canvas への contain 写像は (368,449) に落ちて横
332 px ずれた)。paint PR #40 で受け口に位置モードを足した:

- `overlay` (既定の `usb.sh` = inject あり): 位置・down/up・hover は OS 経路の
  trusted な pen 事象から、筆圧・tilt・twist は WebSocket の直近記録から取る。
  trusted 事象は capture phase で止め、同じ座標の合成事象 (pointerId 4242) だけ
  を paint に見せる。線はカーソルの真下に本物の筆圧で乗る。WebSocket が繋がって
  いないときは trusted 事象を素通しにするので、筆圧 `1.0` でも描ける。
- `canvas` (`nazorid --no-inject`、trusted な pen 事象が来ない環境用): 従来の
  contain 写像。タブレット全面が canvas に写る。

既定は auto で、trusted な pen 事象を一度観測したら `overlay` に切り替える。
`nazori-paint.js` (参照実装) に `overlay` は無く、`canvas` 写像だけ。

## 実測した限界 — 筆圧は Mac 全体へは届かない

ここは「たぶん通る」で済ませられない箇所なので、計器を作って測った
(`tools/pentap.swift`, `tools/penwindow.swift`, `tools/presstest2.swift`)。

送った値: 筆圧 `0.375`、tilt `(30°, -45°)`。

| 観測点 | 位置 | tilt | 筆圧 |
|---|---|---|---|
| セッションのイベント列 (`CGEventTap`) | 一致 | `0.3333 / -0.5000` 一致 | `0.3750` 一致 |
| アプリ内の `CGEvent` field 19 | 一致 | 一致 | **`0.3750` 一致** |
| アプリ内の `CGEvent` field 5 | — | — | **`0.0000` 消える** |
| アプリの `NSEvent.pressure` | — | `0.3333 / -0.5000` 一致 | **`1.0000` ボタン状態から再生成** |

つまり:

- **位置・傾き・回転・近接・消しゴム判定は、macOS の全アプリへそのまま届く。**
- **筆圧は `NSEvent.pressure` には載らない。** `kCGMouseEventPressure` (field 5)
  はユーザ空間から書いても window server に潰される。書く順序、`tabletPointButtons`
  の有無、`privateState` ソース、tap の位置 (`cghid` / `cgSession`) — 四通り
  試して全て `0.0000`。
- 筆圧は `kCGTabletEventPointPressure` (field 19) としては**アプリのプロセスまで
  正しく届いている**。読むアプリがあれば使える。ただし Krita や Photoshop を
  含む普通のアプリは `NSEvent.pressure` を読むので、そこには `1.0` が見える。
- `cgAnnotatedSessionEventTap` への post と、native な `kCGEventTabletPointer`
  型イベントの post は、そもそも配送されなかった。

全アプリで本物の筆圧を出すには DriverKit の HID ドライバ (`com.apple.developer
.driverkit.family.hid.device`) が要る。これは Apple の審査が要る別の道。

**paint へ流す経路にはこの制限はない。** 筆圧も傾きも完全に通る (下記)。

## 検証済みのこと

- Android→Mac: 実機 SM-X730 から 74 記録、`seq` の跳びなし、不正 0。
- HELLO 交換: 端末が受信した Mac の 1920x1080 から有効領域を 2500x1403 (=16:9)
  に自動レターボックス。受信座標から逆算して確認。
- paint (ローカル): 筆圧 `0.15+0.8·sin(πt)` の正弦ストロークを送り、線幅が
  中央で膨らみ両端で細るのを画面で確認。paint の状態表示も `P:0.8750` と送った
  値を返した。
- paint (本番 `canvas.minamorl.com/paint/?nazori=1`, main 509829f = PR #39
  配信後, 2026-09-12): Chrome 153 で上の許可を通した profile に
  `tools/send_stroke.py` (筆圧 `0.15+0.8·sin(πt)`) を流し、ストローク前後の
  画素差分 6,059 px、線幅がストロークの 10% / 50% / 90% 地点で 6 / 10 / 5 px と
  筆圧に追従した。同じ手順を `vite preview` で取ると 42,555 px、12 / 21 / 11 px
  (ブラシサイズ設定が違うだけで比は同じ)。
- paint 位置 (`vite preview` + `nazorid`, PR #40, 2026-09-12): 表示座標
  x 200..1100・y 600±80 の正弦ストローク (筆圧 0.15..0.95) を流し、trusted の
  pointermove が paint に届いた数 0、合成事象 59 件 (筆圧 0.15..0.95)、描画位置は
  カーソルの真下 (canvas 内 y≈452±80 CSS px) に一致。
- macOS 全体: 上の表のとおり。

## 設計のメモ

- **軌跡に低遅延フロントバッファを使っていない。** フェードは古い画素を触る
  ので、追記専用の front buffer とは目的が合わない。毎フレーム全再描画する
  `SurfaceView` + `Choreographer` にして、代わりに `requestUnbufferedDispatch`
  で入力の間引きを外し、`MotionEventPredictor` で穂先に追従させている。
  送信経路は描画を待たないので、この選択は Mac 側の遅延に影響しない。
- **予測点は送らない。** 予測は見た目のためだけで、次の入力で捨てる。
- **指は完全に無視する。** ペンタブであって、タッチパネルではない。
- **落ちたら指を上げる。** 接続が切れたら `releaseStuckContact()` がボタンを
  離す。ストローク途中で切れてもボタンが押しっぱなしにならない。
