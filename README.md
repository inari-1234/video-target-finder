# Video Target Finder

iPhone内の長時間動画から、見本画像で指定した「推し」の登場場面を探し、候補を確認して1本のまとめ動画または個別クリップとして書き出すSwiftUIアプリです。

## プロダクト目的

最終目的は「認識精度を調整すること」ではなく、**推しを集めたショート動画をできるだけ少ない操作で作ること**です。

基本導線は次の5工程です。

1. 動画を選ぶ
2. 推しの見本画像を1〜5枚選ぶ
3. 自動解析する
4. 候補を正解/誤検出で確認する
5. 選んだ場面を1本にまとめて書き出す

高度な探索設定、認識精度レポート、粗探索候補、診断情報は通常操作から分離し「詳細設定・診断」にまとめます。

## v0.29.0 / Build 31

- 学習再探索だけの正解/誤検出/precisionを分離表示
- 学習再探索候補だけで「最近傍1枚 / 上位2見本平均 / 見本間中央値」をA/B比較
- 前回の学習再探索について、粗探索・詳細探索・合計時間とsample/sを通常画面から確認可能
- この版では認識採否ロジック自体は変更せず、次の実機データで精度・速度改善案を決定

- 初回の詳細探索件数と通常候補リストは従来どおり維持し、分析専用の軽量reserveを分離して追加
- 標準では通常候補・詳細探索18件を維持しつつ、時刻＋distanceだけを最大72件分析用に保持
- 再探索で正解になった区間を「初回18位以内 / 19位以下 / 初回粗探索にも無し」に分類
- 候補数制限、詳細探索条件、画像特徴表現のどこが見逃し要因かをレポートで切り分け可能
- 認識レポートへ評価スキーマと認識エンジン名を記録し、将来のembedding方式とのA/B比較基盤を追加
- CandidateBudgetAnalyzerの自動テストをGitHub Actionsへ追加
- v0.19の5ステップUI、安全書き出し、再探索回別集計を維持
- チェックポイント削除が認識レポート/診断ログまで消していた共有Application Support削除バグを修正
- 用途別ストレージパスを共通化し、チェックポイント削除をmanifest＋見本画像フォルダだけに限定
- 新しい動画が実際に読み込める前は既存の中断解析を保持し、動画読込失敗で復旧情報を失わないよう修正
- 見本画像を削除した場合は旧見本を含む中断解析を無効化し、古い条件での復旧を防止
- 旧「追跡/連続度」表示を「連続検出/ヒット率」へ修正し、object trackingとは別指標であることをレポートへ明記
- 本番のnearest Feature Print判定は変更せず、見本画像ごとのbest distanceから「nearest / 上位2見本平均 / 中央値」を同時記録するA/B診断を追加
- 正解/誤検出の平均distance差と分布重複を3方式で比較し、Feature Print自体の限界と「複数見本の使い方」の問題を分離可能
- A/B診断は現在方式で候補化された区間だけを対象とし、動画全体のrecall改善を示すものではないことを明記
- ReferenceScoreAnalyzerの純Swift自動テストをGitHub Actionsへ追加
- 再探索で正解になった区間について、K=12/18/24/36/48/72/96の候補数ごとに初回粗候補ランキング上のcoverageを診断
- 初回候補が動画の一部時間帯へ集中していないかを6分割binで計測
- 分析用reserve内で、同じ候補枠数を時間帯へ分散した仮想選択と、現在のglobal distance上位方式で既知正解の時刻coverageを比較
- time-diverse方式は診断専用であり、本番の粗探索候補・詳細探索・しきい値・認識結果は変更しない
- 初回探索・学習再探索・復旧解析ごとに、粗探索/詳細探索の実経過時間・予定sample数・候補/ヒット数・sample/s・最高温度状態を記録
- 性能計測は探索関数の外側だけに追加し、Feature Print・候補順位・しきい値・詳細探索・区間化の本番ロジックは変更しない
- 計測時間は手動一時停止・温度抑制・自動停止中の待機を含む壁時計時間として明示し、復旧解析は復旧位置以降のみ計測
- ScanPerformanceDiagnosticsの純Swift自動テストをGitHub Actionsへ追加
- 残っていた「連続追跡率」「追跡切れ」等の表現を、実態に合わせて「連続検出率」「連続検出切れ」へ統一
- 詳細探索の進捗分母が区間長によって1sample過大になる既存計算（ceil+1）を、実際のwhileループ境界に一致するfloor+1へ修正
- Apple Visionのforeground instance maskとperson instance maskを使うA/B診断を追加。ただし通常の粗探索・詳細探索・候補採否には接続しない
- 初回探索で○/×判定済みの候補だけを対象に、レポートを開く/コピーする時に未計算分だけmask診断し、同一matchThumbnailのbaselineとpaired比較
- 「前景全体（背景除去）」「前景の単一instance最良」「人物の単一instance最良」の3方式について、正解/誤検出のmean gapと分布重複を比較
- foreground全体で改善するかにより背景影響、単一instanceでさらに改善するかにより周辺対象混入の影響を切り分け可能
- person maskは人物として認識された候補だけの補助診断とし、人物以外のキャラクター/着ぐるみを除外しない設計
- mask診断は既に候補化された判定済み区間だけのprecision側A/Bであり、maskにより未検出場面のrecallが改善するかはまだ評価しない
- mask診断結果はsegment ID単位でキャッシュし、同じ候補へのVision mask再実行を避ける
- mask画像はinstance外接矩形へcropせず元matchThumbnailと同じ画角・対象サイズを維持し、背景除去と再構図効果を混同しない
- 単一instance比較は1候補最大8instanceに制限し、上限に達した候補数をレポートへ表示
- mask診断の累計時間を今回分まで加算してからスナップショット保存し、復旧レポートでも診断コストを保持
- mask変換のCore Image処理は候補1件につき1つのCIContextを再利用し、instanceごとのContext生成コストを回避
- mask診断中も端末温度を監視し、seriousでは間隔を空け、criticalでは途中終了して次回レポート表示時に未計算分から再開
- 温度で途中制限されたかをレポートに明示
- MaskingDiagnosticsの純Swift自動テストをGitHub Actionsへ追加
- 初回analysis reserve内の候補時刻を固定し、productionで再取得した同じ局所cropへforeground全体maskを掛けてdistanceだけをshadow再計算する診断を追加
- shadow再順位は最大72候補の同一時刻集合だけを並べ替え、再探索で後から正解だった区間が詳細予算内へ何件入るかをbaselineと比較
- 再取得baselineが保存distanceと4%または0.015以上ずれた候補、mask不可、未処理候補は元distanceへfallbackし、別フレーム取得による偽改善を抑制
- shadow診断はreserve外フレームやmaskによる別region選択を評価しないため、動画全体recallの結論には使わない
- shadow診断は通常UIを増やさず「見逃し診断の詳細」の折りたたみ内から明示実行し、キャンセル・進捗・温度制限に対応
- shadowDistanceのfallback条件もwasProcessedまで含め、温度停止/キャンセル等で未処理の候補が誤ってmask順位へ入る不具合を自動テストで検出・修正
- ForegroundReserveRerankDiagnosticsの純Swift自動テストをGitHub Actionsへ追加
- 正解判定済み初回候補（最大8区間）について、foreground instance label maskからtight bounding boxを抽出するtracking seed診断を追加
- mask label 0=background / その他=instance indexとしてpixel bufferを走査し、各instanceの最小外接矩形を純Swift解析器で算出
- 検索crop内の左上原点boxを動画全体のVision左下原点0...1座標へ変換し、将来VNDetectedObjectObservationへ渡せる形式で評価
- 代表時刻±0.25秒で同じ検索regionを使用し、各時刻でFeature Print距離最小のforeground instanceを選び、隣接IoU・中心移動・面積変動を測定
- 動画端で±0.25秒がclampされる場合は3時刻安定性へ算入せず、同一フレーム重複による偽安定を防止
- 安定判定はIoU>=0.25・中心移動<=0.20・面積最大/最小<=3倍の診断用ヒューリスティックで、実tracking成功率とは明確に分離
- 座標変換テストはCGRectの完全一致ではなく浮動小数点許容誤差で検証し、0.3等の表現差による偽FAILを修正
- TrackingSeedBoxDiagnosticsの純Swift自動テストをGitHub Actionsへ追加
- foreground由来の中央tight boxをVNDetectedObjectObservationへ渡し、VNSequenceRequestHandler + VNTrackObjectRequestで前後各1秒を実際にobject trackingする診断を追加
- trackingは0.125秒間隔で前後各8フレーム、正解判定済み初回候補の上位最大4区間だけに限定し、通常の粗探索・詳細探索・候補採否には接続しない
- mask tight boxと各辺10%余白boxを同一フレーム列・同一参照boxでA/Bし、tracking継続率・confidence・参照IoU・中心差・方向単位の欠損を比較
- 各tracking時刻でforeground+Feature Printによる独立再検出boxも生成し、trackerが返したboxとの一致を測る。ただし独立再検出もground truthではないことを明記
- tracker出力のVNDetectedObjectObservationを次フレームのseedへ引き継ぎ、単なる各フレーム独立検出ではなく実際のsequence trackingとして検証
- v0.26でtracking-seed診断中にも前景mask再順位側の進捗/キャンセルUIが表示される条件混入を発見し、各診断の進捗表示を完全分離
- tracking途中でVision結果が消失またはrequest errorになった場合、その方向の後続フレームは古いseedから再捕捉せずlossのまま扱い、「再捕捉」を連続trackingとして過大評価しない
- ObjectTrackingDiagnosticsの純Swift自動テストをGitHub Actionsへ追加
- coarse候補間引き・percentile threshold・detail window結合・segment groupingを共通ScanPipelineCoreへ抽出し、本番とCI Replayの判断ロジックを共通化
- GitHub Actions内で短いH.264 MOVを生成し、AVAssetImageGeneratorで実デコードしたフレームをFeature Print・hard negative・Vision trackingへ通すruntime smoke testを追加
- 同じ動画fixtureからcoarse→detail→segmentまでheadless replayし、iPhoneへ入れる前にproduction scan判断の回帰を検出できるよう強化
- runtime検証は1本の動画pipeline testへ集約し、無料Actions枠を無駄に消費しない構成を維持

## 現在の認識方式

- Vision `VNGenerateImageFeaturePrintRequest`
- 複数見本画像
- フレーム内の複数局所領域を比較
- 粗探索 → 候補周辺の詳細探索
- 正解候補から追加見本を学習して再探索
- 誤検出候補をhard negativeとして再探索時に抑制

現行方式は「見た目の近さ」を使うため、似たキャラクター同士では正例/負例の距離分布が重なることがあります。今後は、推しショート作成の操作簡略化と並行し、より識別力の高い埋め込み/分類方式への差し替えを検討します。

## 書き出し

結合動画はアプリのDocuments配下へ先に永続保存します。Photosへ直接書き込む経路は、実機で大容量動画保存中にプロセス終了が確認されたため通常フローから外しています。完成後はShare Sheetから「ビデオを保存」を選びます。

## GitHub CI

`.github/workflows/ios-build.yml` が以下を行います。

- Swift構文検査
- 候補予算分析ロジックの自動テスト
- Application Support永続化分離の自動テスト
- ScanPipelineCoreの純Swift回帰テスト
- H.264動画デコード→Feature Print→hard negative→Vision tracking→coarse/detail/segmentのruntime replay
- XcodeGenによるプロジェクト生成
- iOS Simulator Debug build
- iPhoneOS Release unsigned build
- unsigned IPA生成
- Bundle ID / Version / Build / File Sharing / arm64確認
- IPAをActions Artifactへアップロード

Bundle ID: `jp.inari1234.videotargetfinder`

## 次のプロダクト課題

現状の「1本に結合」は選択区間を時系列で連結する機能です。ショート動画作成として完成させるには、目標尺（15/30/60/90秒）、1シーンの最大長、候補の自動優先順位、短い導入/終了、出力プレビューを追加する必要があります。

## CI運用メモ

- `video-target-finder`（canonical）へのpushはUbuntu preflightの後にmacOSフルCIを実行する。
- `video-target-finder-candidate` へのpushはworkflow自体を記録するが、通常commitではjobをskipしてrunnerを割り当てない。
- candidateの節目検証はcommit messageに `[full-ci]` を付けたpushだけUbuntu preflight→macOSフルCIを1回実行する。
- hosted runnerが利用不可の間はcandidateをcanonicalへ昇格しない。
