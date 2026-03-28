import SwiftUI
import WebKit

struct DualFindLiveViewSheet: View {
    @Bindable var vm: DualFindViewModel

    var body: some View {
        VStack(spacing: 0) {
            sessionInfoBar

            if let webView = vm.liveViewWebView() {
                LiveWebViewRepresentable(webView: webView)
                    .clipShape(.rect(cornerRadius: 12))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Session not available")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            sessionSwitcher
        }
        .background(Color(.systemBackground))
        .onChange(of: vm.isRunning) { _, newValue in
            if !newValue {
                vm.showLiveView = false
            }
        }
    }

    private var sessionInfoBar: some View {
        HStack(spacing: 10) {
            let isJoe = vm.liveViewSite == .joefortune
            Image(systemName: isJoe ? "suit.spade.fill" : "flame.fill")
                .font(.system(size: 14))
                .foregroundStyle(isJoe ? .green : .orange)

            VStack(alignment: .leading, spacing: 1) {
                Text(vm.liveViewSessionLabel())
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundStyle(.primary)

                let email = vm.liveViewCurrentEmail()
                if !email.isEmpty {
                    Text(email)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Text(vm.liveViewCurrentStatus())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.purple.opacity(0.6))
                .clipShape(Capsule())

            Button {
                vm.showLiveView = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var sessionSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.sessions, id: \.id) { session in
                    let isJoe = session.platform.contains("Joe")
                    let site: LoginTargetSite = isJoe ? .joefortune : .ignition
                    let isSelected = vm.liveViewSite == site && vm.liveViewSessionIndex == session.index
                    let accent: Color = isJoe ? .green : .orange

                    Button {
                        vm.liveViewSite = site
                        vm.liveViewSessionIndex = session.index
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isJoe ? "suit.spade.fill" : "flame.fill")
                                .font(.system(size: 9))
                            Text("\(isJoe ? "J" : "I")\(session.index + 1)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                        }
                        .foregroundStyle(isSelected ? .white : accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isSelected ? accent.opacity(0.8) : accent.opacity(0.15))
                        .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .contentMargins(.horizontal, 0)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }
}

struct LiveWebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        webView.isUserInteractionEnabled = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        for subview in uiView.subviews {
            if let wv = subview as? WKWebView {
                wv.isUserInteractionEnabled = true
                wv.removeFromSuperview()
            }
        }
    }
}
