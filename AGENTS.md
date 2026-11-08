# エージェント向けの作業ルール

## テストの実行

`xcodebuild test` を実行するときは、必ず並列テストを無効にする。

```sh
xcodebuild test -project Stockpile.xcodeproj -scheme Stockpile \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -parallel-testing-enabled NO
```

- 理由: 並列テストを有効にすると、`~/Library/Developer/XCTestDevices` にシミュレータの複製が何台も作られて起動する。1 台で約 150 プロセスが動くため、16 GB の Mac ではスワップが埋まり、マシン全体が操作できないほど重くなる。途中で止めると複製が残り、1 台あたり約 4.5 GB のディスクを使う。
- scheme でも `parallelizable = "NO"` にしているが、古いブランチや worktree では `YES` のままのことがある。そのためコマンドでも毎回指定する。
- 使い終わったシミュレータは `xcrun simctl shutdown <UDID>` で止める。
