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
| `paint-adapter/` | WebSocket を paint の canvas へ流す ES モジュール |
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

paint へ流すときは `paint-adapter/nazori-paint.js` を paint のページで読む。
paint 本体には手を入れない。

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
- paint: 筆圧 `0.15+0.8·sin(πt)` の正弦ストロークを送り、線幅が中央で膨らみ
  両端で細るのを画面で確認。paint の状態表示も `P:0.8750` と送った値を返した。
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
