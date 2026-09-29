# Windows + AltStore Classicで個人iPhoneへ入れる

このルートはMac不要・Apple Developer Program未加入でも試せます。

## 必要なもの
- Windows PC
- iPhone
- Apple Account
- AltServer / AltStore Classic
- GitHub Actionsで生成した `VideoTargetFinder-unsigned.ipa`

## 概要
1. WindowsへAltServerを入れます。
2. iPhoneをWindowsへ接続し、AltStore ClassicをiPhoneへ導入します。
3. iPhone側でDeveloper Modeを有効にします。
4. `VideoTargetFinder-unsigned.ipa` をAltStore/AltServerでサイドロードします。
5. 写真アクセスを許可し、短いテスト動画で動作確認します。
6. 問題なければ3.95GBの元動画でテストします。

## 無料Apple Accountの制約
- アプリの署名は7日で失効するため、定期的なRefreshが必要です。
- 同時に有効にできるサイドロードアプリ数などApple側の制約があります。
- このアプリはPhotos/Vision/AVFoundationのみを使い、特別な有料Entitlementを前提にしない設計です。

## 最初の実機テスト順
1. 1〜3分の動画
2. 見本画像1枚
3. 高速モード / 2秒間隔
4. 候補プレビュー
5. 5〜10秒の切り出し保存
6. その後、長時間動画へ拡大
