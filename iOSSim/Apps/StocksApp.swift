import SwiftUI

struct StocksApp: View {
    @State private var selected: Ticker?
    @State private var search = ""
    @State private var focusSearch = false

    @Environment(\.deviceSafeArea) private var safeArea

    var body: some View {
        GeometryReader { geo in
            ZStack {
                list
                    .offset(x: selected == nil ? 0 : -geo.size.width * 0.3)
                    .overlay(Palette.ink.opacity(selected == nil ? 0 : 0.2))
                    .disabled(selected != nil)

                if let ticker = selected {
                    TickerDetail(ticker: ticker) {
                        withAnimation(.appClose) { selected = nil }
                    }
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
                }
            }
        }
        .background(SysColor.groupedBackground)
        .onAppIntent(.stocks) { _ in
            // The watchlist is the root list, so clear anything covering it.
            search = ""
            selected = nil
        }
    }

    private var list: some View {
        AppScaffold(title: "Stocks", searchable: true,
                    searchPlaceholder: "Search", searchText: $search,
                    searchFocus: $focusSearch) {
            VStack(spacing: 0) {
                Text(Date().formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(SysColor.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)

                ForEach(StocksData.tickers.filter(matches)) { ticker in
                    Button {
                        Haptics.tap(.light)
                        withAnimation(.appLaunch) { selected = ticker }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ticker.symbol)
                                    .font(.system(size: 19, weight: .semibold))
                                    .foregroundStyle(SysColor.label)
                                Text(ticker.name)
                                    .font(.system(size: 14))
                                    .foregroundStyle(SysColor.secondaryLabel)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 8)

                            Sparkline(points: ticker.points, color: ticker.isUp ? SysColor.green : SysColor.red)
                                .frame(width: 62, height: 32)

                            VStack(alignment: .trailing, spacing: 4) {
                                Text(ticker.priceText)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(SysColor.label)
                                Text(ticker.changeText)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(SysColor.label)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(ticker.isUp ? SysColor.green : SysColor.red)
                                    )
                            }
                            .frame(width: 84, alignment: .trailing)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(SysColor.separator).frame(height: 0.5).padding(.leading, 20)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } trailing: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18))
                .foregroundStyle(SysColor.blue)
        }
    }

    private func matches(_ ticker: Ticker) -> Bool {
        search.isEmpty
            || ticker.symbol.localizedCaseInsensitiveContains(search)
            || ticker.name.localizedCaseInsensitiveContains(search)
    }
}

struct Sparkline: View {
    let points: [CGFloat]
    let color: Color
    var filled = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if filled {
                    areaPath(in: geo.size)
                        .fill(LinearGradient(colors: [color.opacity(0.35), .clear],
                                             startPoint: .top, endPoint: .bottom))
                }
                linePath(in: geo.size)
                    .stroke(color, style: StrokeStyle(lineWidth: filled ? 2 : 1.6,
                                                      lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func linePath(in size: CGSize) -> Path {
        let step = points.count > 1 ? size.width / CGFloat(points.count - 1) : size.width
        return Path { path in
            for (index, value) in points.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step, y: size.height - value * size.height)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }

    private func areaPath(in size: CGSize) -> Path {
        var path = linePath(in: size)
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }
}

private struct TickerDetail: View {
    let ticker: Ticker
    var onBack: () -> Void

    @Environment(\.deviceSafeArea) private var safeArea
    @State private var range = 2

    var body: some View {
        ZStack(alignment: .top) {
            SysColor.groupedBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ticker.symbol)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(SysColor.label)
                        Text(ticker.name)
                            .font(.system(size: 15))
                            .foregroundStyle(SysColor.secondaryLabel)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(ticker.priceText)
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(SysColor.label)
                        Text(ticker.changeText)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(ticker.isUp ? SysColor.green : SysColor.red)
                    }

                    HStack(spacing: 0) {
                        ForEach(Array(["1D", "1W", "1M", "3M", "6M", "1Y"].enumerated()), id: \.offset) { index, label in
                            Button {
                                Haptics.selection()
                                withAnimation(.snappy) { range = index }
                            } label: {
                                Text(label)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(range == index ? .black : SysColor.secondaryLabel)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background {
                                        if range == index {
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .fill(ticker.isUp ? SysColor.green : SysColor.red)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Sparkline(points: ticker.points,
                              color: ticker.isUp ? SysColor.green : SysColor.red,
                              filled: true)
                        .frame(height: 190)
                        .padding(.vertical, 8)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                              spacing: 16) {
                        stat("OPEN", ticker.priceText)
                        stat("HIGH", String(format: "%.2f", ticker.price * 1.014))
                        stat("LOW", String(format: "%.2f", ticker.price * 0.981))
                        stat("VOL", "48.2M")
                        stat("P/E", "29.4")
                        stat("MKT CAP", "3.42T")
                    }

                    Text("News")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(SysColor.label)
                        .padding(.top, 6)

                    ForEach(["Quarterly results beat expectations",
                             "Analysts raise price target after product event",
                             "Supply chain outlook improves for the quarter"], id: \.self) { headline in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("MARKET WIRE")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(SysColor.secondaryLabel)
                            Text(headline)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(SysColor.label)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(SysColor.secondaryGrouped)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, safeArea.top + 60)
                .padding(.bottom, safeArea.bottom + 40)
            }

            InlineNavBar(title: ticker.symbol, backTitle: "Stocks", onBack: onBack) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(SysColor.blue)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SysColor.secondaryLabel)
            Text(value)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(SysColor.label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
