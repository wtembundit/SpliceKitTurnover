import AVKit
import SwiftUI

struct BurnInCustomizerView: View {
    @ObservedObject var model: TurnoverModel
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Data Burn-In Customizer")
                        .font(.title2.weight(.semibold))
                    Text("Configure six independent fields. Plain text works directly; tokens are optional.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    model.saveBurnInCustomPreset()
                    dismiss()
                }
                    .keyboardShortcut(.defaultAction)
            }

            preview

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("FIELD")
                        .sectionLabelStyle()
                    Picker("Field", selection: $model.selectedBurnInAnchor) {
                        ForEach(TurnoverModel.BurnInAnchor.allCases) { anchor in
                            Text(anchor.rawValue).tag(anchor)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Show this field", isOn: selectedField.enabled)

                    Text("CONTENT")
                        .sectionLabelStyle()
                    TextField("Plain text and optional tokens", text: selectedField.template, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .onChange(of: selectedField.wrappedValue.template) { _, _ in markCustom() }
                    Menu("Insert Token") {
                        ForEach(tokens, id: \.self) { token in
                            Button(token) { insertToken(token) }
                        }
                    }
                    Text("Tokens: {project}, {event}, {timeline_tc}, {timeline_frame}, {source_file}, {source_tc}, {vfx_number}, {vfx_note}, {audio_role}")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Divider()
                    Text("CONDITION")
                        .sectionLabelStyle()
                    HStack {
                        Text("Audio role contains")
                        TextField("Dialogue", text: $model.burnInAudioRoleFilter)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("Append message")
                        TextField("TEMP AUDIO", text: $model.burnInConditionalText)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 12) {
                    Text("STYLE & PLACEMENT")
                        .sectionLabelStyle()
                    Picker("Color", selection: selectedField.textColor) {
                        ForEach(TurnoverModel.BurnInTextColor.allCases) { color in
                            Text(color.rawValue).tag(color)
                        }
                    }
                    HStack {
                        Text("Font \(Int(selectedField.wrappedValue.fontSize))")
                            .frame(width: 74, alignment: .leading)
                        Slider(value: selectedField.fontSize, in: 6...96, step: 1)
                    }
                    HStack {
                        Text("X Pad \(Int(selectedField.wrappedValue.horizontalPadding))")
                            .frame(width: 74, alignment: .leading)
                        Slider(value: selectedField.horizontalPadding, in: 0...240, step: 1)
                    }
                    HStack {
                        Text("Y Pad \(Int(selectedField.wrappedValue.verticalPadding))")
                            .frame(width: 74, alignment: .leading)
                        Slider(value: selectedField.verticalPadding, in: 0...160, step: 1)
                    }
                    HStack {
                        Text("BG \(Int(selectedField.wrappedValue.backgroundOpacity * 100))%")
                            .frame(width: 74, alignment: .leading)
                        Slider(value: selectedField.backgroundOpacity, in: 0...1, step: 0.05)
                    }
                }
                .frame(width: 310)
            }
        }
        .padding(24)
        .frame(minWidth: 900, minHeight: 690)
        .background(Color(red: 0.07, green: 0.10, blue: 0.13))
        .preferredColorScheme(.dark)
        .onAppear { configurePlayer() }
        .onChange(of: model.burnInVideoURL) { _, _ in configurePlayer() }
        .onDisappear { player?.pause() }
    }

    private var preview: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 0.12, green: 0.14, blue: 0.16))
                if let player {
                    BurnInPlayerView(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 7) {
                        Image(systemName: "square.on.square.dashed")
                            .font(.largeTitle)
                        Text("Transparent ProRes 4444 Preview")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                ForEach(model.burnInFields.filter(\.enabled)) { field in
                    Text(model.burnInPreviewText(for: field))
                        .font(.system(size: field.fontSize, weight: .semibold, design: .monospaced))
                        .foregroundStyle(textColor(field.textColor))
                        .multilineTextAlignment(textAlignment(field.anchor))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(field.backgroundOpacity), in: RoundedRectangle(cornerRadius: 5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: previewAlignment(field.anchor))
                        .padding(.horizontal, field.horizontalPadding)
                        .padding(.vertical, field.verticalPadding)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)

            if model.burnInDurationSeconds > 0 {
                HStack(spacing: 10) {
                    Slider(
                        value: Binding(
                            get: { model.burnInPositionSeconds },
                            set: { value in
                                model.burnInPositionSeconds = value
                                player?.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                            }
                        ),
                        in: 0...model.burnInDurationSeconds
                    )
                    Text(model.burnInTimelineLabel)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 230, alignment: .trailing)
                }
            } else {
                Text("Build the manifest to enable frame-resolved timeline scrubbing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectedField: Binding<TurnoverModel.BurnInField> {
        $model.burnInFields[model.selectedBurnInFieldIndex]
    }

    private func previewAlignment(_ anchor: TurnoverModel.BurnInAnchor) -> Alignment {
        switch anchor {
        case .topLeft: .topLeading
        case .topCenter: .top
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomCenter: .bottom
        case .bottomRight: .bottomTrailing
        }
    }

    private func textAlignment(_ anchor: TurnoverModel.BurnInAnchor) -> TextAlignment {
        switch anchor {
        case .topLeft, .bottomLeft: .leading
        case .topCenter, .bottomCenter: .center
        case .topRight, .bottomRight: .trailing
        }
    }

    private func textColor(_ color: TurnoverModel.BurnInTextColor) -> Color {
        switch color {
        case .white: .white
        case .yellow: .yellow
        case .cyan: .cyan
        case .red: .red
        case .black: .black
        }
    }

    private func configurePlayer() {
        player?.pause()
        guard let url = model.burnInVideoURL else {
            player = nil
            return
        }
        let next = AVPlayer(url: url)
        next.isMuted = true
        player = next
    }

    private func markCustom() {
        if model.burnInPreset != .custom {
            model.burnInPreset = .custom
        }
    }

    private var tokens: [String] {
        ["{project}", "{event}", "{timeline_tc}", "{timeline_frame}", "{source_file}", "{source_tc}", "{vfx_number}", "{vfx_note}", "{audio_role}"]
    }

    private func insertToken(_ token: String) {
        let separator = selectedField.wrappedValue.template.isEmpty ? "" : " "
        selectedField.wrappedValue.template += separator + token
        markCustom()
    }
}

private struct BurnInPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

private extension View {
    func sectionLabelStyle() -> some View {
        font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(1.4)
            .foregroundStyle(.secondary)
    }
}
