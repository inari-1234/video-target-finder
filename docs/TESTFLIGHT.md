# TestFlight安定運用ルート

7日ごとの再署名を避け、iPhoneへ安定して配布する場合はApple Developer Programを利用します。

## 必要になるもの
- Apple Developer Program membership
- App Store Connectのアプリ登録
- Distribution certificate / provisioning profile または自動署名環境
- App Store Connect API Key等をGitHub Secretsへ安全に登録

## 利点
- TestFlightでiPhoneへ配布できる
- 無料Personal Teamの7日失効を回避できる
- 更新版の配布が容易

## Stage 9で未実施の理由
証明書、秘密鍵、API Keyはユーザー固有の秘密情報です。リポジトリへ直接書かず、実際にTestFlightへ進む時点でGitHub Secretsを使って設定します。
