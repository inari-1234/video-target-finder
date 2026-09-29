# GitHub Actionsで直接ビルドする手順

## 現在の方式

正規ブランチ `video-target-finder` と開発候補ブランチ `video-target-finder-candidate` は、Stage ZIPやpatchを復元せず、リポジトリ内のSwiftソースを直接ビルドします。

workflow:

`.github/workflows/ios-build.yml`

workflow名:

`Video Target Finder Direct Source Build`

## 自動検証内容

push時に次を順番に実行します。

1. Swift全ファイルの構文解析
2. `scripts/verify_source.py` によるリポジトリ回帰検査
3. CandidateBudgetAnalyzerのロジックテスト
4. XcodeGenでXcode project生成
5. iOS Simulator Debug build
6. unsigned iPhone Release build
7. compiler warning確認
8. unsigned IPA生成
9. IPA内部のBundle ID / Version / Build / File Sharing / arm64検査
10. IPAをActions Artifactへ保存

## v0.20.0 / Build 20

Artifact名:

`VideoTargetFinder-v0.20.0-build20-sideload-ipa`

Bundle ID:

`jp.inari1234.videotargetfinder`

## 正規反映手順

1. `video-target-finder-candidate` で変更する
2. candidateのActionsをSUCCESSまで確認する
3. candidateをGitHubから再取得する
4. `video-target-finder` に対して behind 0 を確認する
5. forceなしのfast-forwardで正規ブランチへ反映する
6. 正規ブランチを再取得しcandidateとidenticalを確認する
7. 正規ブランチ側のActionsもSUCCESSまで確認する

## iPhoneへ入れる場合

生成IPAはunsignedです。必要な署名手段で再署名してiPhoneへ導入します。アプリ本体のビルド検証と署名・配布は分離して扱います。
