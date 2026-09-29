import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Label("推し動画メーカー", systemImage: "sparkles.rectangle.stack")
                        .font(.largeTitle.bold())

                    Text("長い動画から推しの登場場面を見つけて、短いまとめ動画を簡単に作れます。")
                        .font(.headline)

                    guideStep(1, "動画を選ぶ", "写真ライブラリから元動画を選びます。長い動画でも順番に解析します。")
                    guideStep(2, "推しの見本を選ぶ", "正面・横向きなど1〜5枚を選びます。推しが大きく写っている画像ほど見つけやすくなります。")
                    guideStep(3, "推しを探す", "「推しの登場場面を探す」を押すと、自動で候補を探します。細かな設定は通常変更しなくて構いません。")
                    guideStep(4, "候補を確認", "候補を再生して、推しなら「正解」、違えば「誤検出」を選びます。必要なら正解を使って見逃しをもう一度探せます。")
                    guideStep(5, "推し動画を作る", "正解にした場面を1本にまとめて書き出します。完成動画は安全保存してから共有・写真保存できます。")

                    GroupBox("長い動画を解析するとき") {
                        Text("解析中は発熱を抑えるため画面を暗めにし、充電しながら使う場合も端末が熱くなったら停止してください。端末温度に応じて自動で減速・停止します。")
                            .font(.subheadline)
                    }

                    Button("使い始める") {
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
                .padding()
            }
            .navigationTitle("はじめに")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func guideStep(_ number: Int, _ title: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 32, height: 32)
                .background(.thinMaterial, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(description).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
