#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Reading preference rows, shared by the settings tab and the in-reader sheet.
///
/// These used to exist only inside `ReaderSettingsSheet`, which is why the
/// settings tab showed a single "排版与主题" row that pushed a sheet — reading
/// preferences looked like a separate feature bolted onto the app rather than
/// part of its settings.
///
/// Deliberately *rows only*, not whole `Section`s: a `Section` nested inside a
/// custom view is not flattened by `Form`, so its header and the grouped card
/// background are lost and every row renders bare. The caller owns the
/// `Section`, this type only owns the controls — still a single definition of
/// each slider's range and formatting.
enum ReaderSettingSections {
    // MARK: - Typography

    @ViewBuilder
    static func typography(_ reading: Binding<ReadingSettings>) -> some View {
        sliderRow(
            title: "字号",
            value: reading.fontSize,
            range: 14...30,
            step: 1,
            format: { "\(Int($0)) pt" }
        )

        sliderRow(
            title: "行距",
            value: reading.lineSpacing,
            range: 0...24,
            step: 1,
            format: { String(format: "%.0f", $0) }
        )

        sliderRow(
            title: "段距",
            value: reading.paragraphSpacing,
            range: 0...32,
            step: 2,
            format: { String(format: "%.0f", $0) }
        )

        sliderRow(
            title: "左右边距",
            value: reading.horizontalPadding,
            range: 8...48,
            step: 2,
            format: { String(format: "%.0f", $0) }
        )

        Picker("对齐", selection: reading.alignment) {
            ForEach(BodyAlignment.allCases) { alignment in
                Text(alignment.displayName).tag(alignment)
            }
        }
        .pickerStyle(.segmented)

        Toggle("首行缩进两字", isOn: reading.firstLineIndent)

        Picker("字体", selection: fontFamily(reading)) {
            Text("系统衬线（推荐中文）").tag("")
            Text("系统无衬线").tag("-apple-system")
            Text("苹方 PingFang SC").tag("PingFangSC-Regular")
            Text("宋体 Songti SC").tag("SongtiSC-Regular")
            Text("楷体 Kaiti SC").tag("KaitiSC-Regular")
            Text("圆体 Yuanti SC").tag("YuantiSC-Regular")
        }
    }

    // MARK: - Page turn

    @ViewBuilder
    static func pageTurn(_ reading: Binding<ReadingSettings>) -> some View {
        Picker("方式", selection: reading.pageTurnMode) {
            ForEach(PageTurnMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)

        if reading.wrappedValue.pageTurnMode == .page {
            Picker("效果", selection: reading.pageTurnEffect) {
                ForEach(PageTurnEffect.allCases) { effect in
                    Text(effect.displayName).tag(effect)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Background

    @ViewBuilder
    static func background(_ reading: Binding<ReadingSettings>) -> some View {
        Toggle("跟随系统深色模式", isOn: reading.followSystemAppearance)

        Picker("主题", selection: reading.theme) {
            ForEach(ReaderTheme.allCases) { theme in
                Text(theme.displayName).tag(theme)
            }
        }
        .pickerStyle(.segmented)

        if reading.wrappedValue.followSystemAppearance {
            Text("系统为浅色时用 \(reading.wrappedValue.theme.displayName)，深色时自动换成\(reading.wrappedValue.theme.darkCounterpart.displayName)。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Startup

    /// What the app opens to on launch.
    @ViewBuilder
    static func startup(_ reading: Binding<ReadingSettings>) -> some View {
        Toggle("启动时继续上次阅读", isOn: reading.resumeLastReading)
    }

    // MARK: - Cache

    @ViewBuilder
    static func cache(_ cache: Binding<CacheSettings>) -> some View {
        Stepper(
            "阅读时预缓存 \(cache.wrappedValue.prefetchCount) 章",
            value: cache.prefetchCount,
            in: 0...20
        )

        Stepper(
            cache.wrappedValue.maxCachedChaptersPerBook == 0
                ? "每本最多缓存：不限"
                : "每本最多缓存 \(cache.wrappedValue.maxCachedChaptersPerBook) 章",
            value: cache.maxCachedChaptersPerBook,
            in: 0...3000,
            step: 50
        )

        Toggle("加入书架时缓存全本", isOn: cache.autoCacheOnAdd)
    }

    // MARK: - Helpers

    /// `fontFamily` is `String?` in the model but `""` means "system serif" in
    /// the picker, so the two have to be bridged.
    static func fontFamily(_ reading: Binding<ReadingSettings>) -> Binding<String> {
        Binding(
            get: { reading.wrappedValue.fontFamily ?? "" },
            set: { value in
                reading.wrappedValue.fontFamily = value.isEmpty ? nil : value
            }
        )
    }

    static func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
#endif
