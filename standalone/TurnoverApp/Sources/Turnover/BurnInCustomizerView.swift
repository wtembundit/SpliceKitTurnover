import AVKit
import SwiftUI

struct BurnInCustomizerView: View {
    @ObservedObject var model: TurnoverModel
    @State private var player: AVPlayer?
    @State private var playerTimeObserver: Any?
    @State private var displayedPlaybackFrame: Int = -1
    @State private var isPlaying = false
    @State private var playbackRate: Float = 1.0
    @State private var playbackTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    @State private var showPresetSection = true
    @State private var showExportSection = true
    @State private var showDisplaySection = true
    @State private var showDataLabelsSection = true
    @State private var showMetadataSection = true
    @State private var showAnalysisSection = true
    @State private var showGlobalStyleSection = true
    @State private var showFieldStyleSection = true

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 12) {
                    preview
                    fieldBuilderPanel
                }
                    .frame(maxWidth: .infinity)
                inspectorPanel
                    .frame(width: 390)
            }
        }
        .padding(24)
        .frame(minWidth: 1260, minHeight: 820)
        .background(Color(red: 0.07, green: 0.10, blue: 0.13))
        .preferredColorScheme(.dark)
        .onAppear {
            model.burnInCustomizerVisible = true
            configurePlayer()
        }
        .onChange(of: model.burnInVideoURL) { _, _ in
            configurePlayer()
        }
        .onChange(of: model.burnInConditions) { _, _ in markCustom() }
        .onReceive(playbackTimer) { _ in syncTimelineFromPlayer() }
        .background(BurnInKeyCaptureView { event in handleKey(event) })
        .onDisappear {
            model.saveSelectedBurnInPreset()
            player?.pause()
            removePlayerTimeObserver()
            isPlaying = false
            model.burnInCustomizerVisible = false
        }
    }

    private var fieldBuilderPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("FIELD BUILDER")
                .sectionLabelStyle()
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("POSITION")
                        .sectionLabelStyle()
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(TurnoverModel.BurnInAnchor.allCases) { anchor in
                            Button {
                                model.selectedBurnInAnchor = anchor
                            } label: {
                                Text(anchor.shortLabel)
                                    .font(.caption)
                                    .frame(maxWidth: .infinity, minHeight: 28)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(model.selectedBurnInAnchor == anchor ? .accentColor : .secondary)
                        }
                    }
                    .frame(width: 260)
                }
                .frame(width: 260, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("CONTENT")
                            .sectionLabelStyle()
                        Spacer()
                        Toggle("Show this field", isOn: selectedField.enabled)
                            .toggleStyle(.checkbox)
                    }
                    TextField("Type plain text here, then insert dynamic data when needed", text: selectedField.template, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...7)
                        .onChange(of: selectedField.wrappedValue.template) { _, _ in markCustom() }
                    HStack {
                        Menu("Insert Data") {
                            ForEach(tokenGroups) { group in
                                Section(group.title) {
                                    ForEach(group.items) { item in
                                        Button(item.title) { insertData(item.value) }
                                    }
                                }
                            }
                        }
                        Spacer()
                    }
                    Text("Plain text stays exactly as typed. Insert Data adds live timeline, source, metadata, audio, VFX, or analysis values.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                conditionsPanel
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(14)
        .background(panelBackground)
    }

    private var inspectorPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                inspectorDisclosure("PRESET", isExpanded: $showPresetSection) {
                    presetSection
                }
                Divider()
                inspectorDisclosure("EXPORT VIDEO", isExpanded: $showExportSection) {
                    exportVideoSection
                }
                Divider()
                inspectorDisclosure("DISPLAY", isExpanded: $showDisplaySection) {
                    displayOptionsSection
                }
                Divider()
                inspectorDisclosure("DATA LABELS", isExpanded: $showDataLabelsSection) {
                    dynamicDataLabelsSection
                }
                Divider()
                inspectorDisclosure("METADATA", isExpanded: $showMetadataSection) {
                    metadataSection
                }
                Divider()
                inspectorDisclosure("ANALYSIS DETAILS", isExpanded: $showAnalysisSection) {
                    analysisDetailsSection
                }
                Divider()
                inspectorDisclosure("GLOBAL STYLE", isExpanded: $showGlobalStyleSection) {
                    globalStyleSection
                }
                Divider()
                inspectorDisclosure("FIELD STYLE", isExpanded: $showFieldStyleSection) {
                    fieldStyleSection
                }
            }
            .padding(14)
        }
        .frame(maxHeight: .infinity)
        .background(panelBackground)
    }

    private func inspectorDisclosure<Content: View>(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            content()
                .padding(.top, 8)
        } label: {
            Text(title)
                .sectionLabelStyle()
        }
    }

    private var conditionsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CONDITIONS")
                    .sectionLabelStyle()
                Spacer()
                Button {
                    model.addBurnInCondition()
                } label: {
                    Label("Add", systemImage: "plus.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .help("Add a condition that appends text when timeline data matches.")
            }

            if model.burnInConditions.isEmpty {
                Text("No conditions. Add one to append text only when timeline data matches.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach($model.burnInConditions) { $condition in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Picker("", selection: $condition.subject) {
                                    ForEach(TurnoverModel.BurnInCondition.Subject.allCases) { subject in
                                        Text(subject.rawValue).tag(subject)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 126)

                                TextField("contains", text: $condition.contains)
                                    .textFieldStyle(.roundedBorder)

                                Button {
                                    model.removeBurnInCondition(id: condition.id)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove this condition.")
                            }

                            HStack(spacing: 8) {
                                TextField("append message, e.g. TEMP AUDIO", text: $condition.message)
                                    .textFieldStyle(.roundedBorder)

                                Menu("Insert Data") {
                                    ForEach(tokenGroups) { group in
                                        Section(group.title) {
                                            ForEach(group.items) { item in
                                                Button(item.title) {
                                                    appendData(item.value, to: $condition.message)
                                                }
                                            }
                                        }
                                    }
                                }
                                .menuStyle(.borderlessButton)
                                .help("Insert dynamic data into this condition message.")
                            }
                        }
                        .padding(8)
                        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            Text("Example: Audio Role contains Dialogue -> TEMP AUDIO. Conditions can match source files, VFX text, or analysis details too.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Picker("Preset", selection: $model.selectedBurnInPresetID) {
                    ForEach(model.burnInPresets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .labelsHidden()
                .frame(width: 128)
                .onChange(of: model.selectedBurnInPresetID) { _, _ in model.applySelectedBurnInPreset() }

                Button {
                    model.saveSelectedBurnInPreset()
                } label: {
                    Label("Save Preset", systemImage: "tray.and.arrow.down")
                }
                .labelStyle(.iconOnly)
                .turnoverHelp("Save changes to the selected preset.")

                Button {
                    model.saveBurnInPresetAs()
                } label: {
                    Label("Save Preset As", systemImage: "plus.square.on.square")
                }
                .labelStyle(.iconOnly)
                .turnoverHelp("Create a new preset from the current settings.")

                Button {
                    model.renameSelectedBurnInPreset()
                } label: {
                    Label("Rename Preset", systemImage: "pencil")
                }
                .labelStyle(.iconOnly)
                .turnoverHelp("Rename the selected preset.")

                Button {
                    model.deleteSelectedBurnInPreset()
                } label: {
                    Label("Delete Preset", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .disabled(model.burnInPresets.count <= 1)
                .turnoverHelp("Delete the selected local preset.")

                Button {
                    model.importBurnInPreset()
                } label: {
                    Label("Import Preset", systemImage: "square.and.arrow.down")
                }
                .labelStyle(.iconOnly)
                .turnoverHelp("Import a preset JSON file.")

                Button {
                    model.exportBurnInPreset()
                } label: {
                    Label("Export Preset", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.iconOnly)
                .turnoverHelp("Export this preset as JSON for another machine.")
            }
            Text("Save updates the selected preset. Save As creates a new named preset. Import/Export uses JSON for sharing.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var exportVideoSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Text("Mode")
                    .frame(width: 44, alignment: .leading)
                Picker("Mode", selection: $model.burnInExportMode) {
                    ForEach(TurnoverModel.BurnInExportMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 220, alignment: .leading)
                .onChange(of: model.burnInExportMode) { _, _ in
                    model.normalizeBurnInExportSettings()
                    markCustom()
                }
            }
            .frame(width: 288, alignment: .leading)
            HStack(spacing: 10) {
                Text("Codec")
                    .frame(width: 44, alignment: .leading)
                Picker("Codec", selection: $model.burnInExportCodec) {
                    ForEach(model.burnInExportMode == .transparentOverlay ? [.proRes4444] : TurnoverModel.BurnInExportCodec.burnedInReleaseCodecs) { codec in
                        Text(codec.rawValue).tag(codec)
                    }
                }
                .labelsHidden()
                .frame(width: 220, alignment: .leading)
                .disabled(model.burnInExportMode == .transparentOverlay)
                .onChange(of: model.burnInExportCodec) { _, _ in
                    model.normalizeBurnInExportSettings()
                    markCustom()
                }
            }
            .frame(width: 288, alignment: .leading)
            if model.burnInExportCodec.usesBitrate && model.burnInExportMode == .burnedInReference {
                HStack(spacing: 10) {
                    Text("Container")
                        .frame(width: 74, alignment: .leading)
                    Picker("Container", selection: $model.burnInExportContainer) {
                        ForEach(TurnoverModel.BurnInExportContainer.allCases) { container in
                            Text(container.rawValue).tag(container)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190, alignment: .leading)
                    .onChange(of: model.burnInExportContainer) { _, _ in markCustom() }
                }
                .frame(width: 288, alignment: .leading)
            }
            if model.burnInExportCodec.usesBitrate {
                HStack {
                    Text("Bitrate \(Int(model.burnInExportBitrateMbps)) Mbps")
                        .frame(width: 126, alignment: .leading)
                    Slider(value: $model.burnInExportBitrateMbps, in: 2...120, step: 1)
                        .onChange(of: model.burnInExportBitrateMbps) { _, _ in markCustom() }
                }
                .frame(width: 288, alignment: .leading)
            }
            Toggle("Reveal when finished", isOn: $model.burnInRevealExportWhenDone)
                .toggleStyle(.checkbox)
                .onChange(of: model.burnInRevealExportWhenDone) { _, _ in markCustom() }
            Button {
                model.prepareBurnInVideoExport()
            } label: {
                Label("Export Video...", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .frame(width: 220, alignment: .leading)
            .disabled(model.burnInDurationSeconds <= 0)
            Text(model.burnInExportEstimateText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 288, alignment: .leading)
            if model.burnInExportProgress != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let progress = model.burnInExportProgress {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(model.burnInExportStatus.isEmpty ? "Exporting..." : model.burnInExportStatus)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text("\(Int(progress * 100))%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                        }
                        .frame(width: 288, alignment: .leading)
                    }
                    Button {
                        model.cancelBurnInExport()
                    } label: {
                        Label("Stop Current", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(width: 140, alignment: .leading)
                    .help("Cancel the current export and continue with the next queued job.")

                    if model.burnInExportQueueCount > 0 {
                        Button {
                            model.cancelAllBurnInExports()
                        } label: {
                            Label("Stop All", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(width: 140, alignment: .leading)
                        .help("Cancel the current export and clear all queued exports.")
                    }
                }
                .frame(width: 288, alignment: .leading)
            }
            exportQueueList
            Text(model.burnInExportMode == .transparentOverlay ? "Transparent overlay is locked to ProRes 4444." : "Burned-in export supports H.264 and HEVC in this release.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 288, alignment: .topLeading)
                .frame(minHeight: 28, alignment: .topLeading)
        }
        .frame(width: 288, alignment: .leading)
    }

    private var exportQueueList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let current = model.burnInCurrentExport {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Now Exporting")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(height: 14)
                    Text(current.filename)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(current.mode) - \(current.codec)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(8)
                .frame(width: 288, alignment: .leading)
                .frame(minHeight: 58, alignment: .leading)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            }

            if !model.burnInQueuedExports.isEmpty {
                HStack {
                    Text("Queued")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") {
                        model.clearQueuedBurnInExports()
                    }
                    .controlSize(.mini)
                    .help("Remove all queued exports. The current export keeps running.")
                }
                ForEach(model.burnInQueuedExports) { item in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.filename)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(item.mode) - \(item.codec)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer()
                        Button {
                            model.removeQueuedBurnInExport(id: item.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this queued export.")
                    }
                    .padding(6)
                    .frame(width: 288, alignment: .leading)
                    .frame(minHeight: 48, alignment: .leading)
                    .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .frame(width: 288, alignment: .leading)
    }

    private var displayOptionsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("Show labels by default", isOn: $model.burnInShowLabels)
                .toggleStyle(.checkbox)
                .onChange(of: model.burnInShowLabels) { _, _ in markCustom() }
            Toggle("Show source file extensions", isOn: $model.burnInShowFileExtensions)
                .toggleStyle(.checkbox)
                .onChange(of: model.burnInShowFileExtensions) { _, _ in markCustom() }
            Stepper("Connected layers \(model.burnInSourceLayerLimit)", value: $model.burnInSourceLayerLimit, in: 0...6)
                .font(.caption)
                .onChange(of: model.burnInSourceLayerLimit) { _, _ in markCustom() }
                .help("Maximum connected video layers to show in Source Layers. Use 0 to hide connected layers.")
            HStack(spacing: 8) {
                Text("Layer display")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $model.burnInSourceLayerDisplayMode) {
                    ForEach(TurnoverModel.BurnInSourceLayerDisplayMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 132)
                .onChange(of: model.burnInSourceLayerDisplayMode) { _, _ in markCustom() }
                .help("Compact shows one short line per connected clip. Detailed uses the selected layer fields below.")
            }
            if model.burnInSourceLayerDisplayMode == .detailed {
                HStack(spacing: 8) {
                    Text("Detail layout")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $model.burnInSourceLayerDetailLayout) {
                        ForEach(TurnoverModel.BurnInSourceLayerDetailLayout.allCases) { layout in
                            Text(layout.rawValue).tag(layout)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 132)
                    .onChange(of: model.burnInSourceLayerDetailLayout) { _, _ in markCustom() }
                    .help("One Line keeps layer details compact. Two Lines separates the layer name from selected source and metadata values.")
                }
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ], alignment: .leading, spacing: 7) {
                    ForEach(TurnoverModel.BurnInSourceLayerDetail.allCases) { detail in
                        Toggle(detail.rawValue, isOn: sourceLayerDetailBinding(detail))
                            .toggleStyle(.checkbox)
                            .font(.caption)
                    }
                }
                Text("Layer details use source, metadata, and retime values from connected clips only. Transform, scale, and position stay in Analysis Details.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("File extension display applies to source filename and source layer lists. Source Layers show connected video clips on the visible sequence timeline. Primary Storyline remains the main source; internal lanes inside primary clips are ignored.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var dynamicDataLabelsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            if activeLabelTokenOptions.isEmpty {
                Text("Insert dynamic data into a field to customize labels here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ], alignment: .leading, spacing: 7) {
                    ForEach(activeLabelTokenOptions) { option in
                        Toggle(option.label, isOn: labelOverrideBinding(option.token))
                            .toggleStyle(.checkbox)
                            .font(.caption)
                    }
                }
            }
            Text("Use this when one data item needs a label while the rest stays clean, or the other way around.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            if model.burnInMetadataOptions.isEmpty {
                Text("Build the Burn-In cache to list metadata found in this FCPXML.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ], alignment: .leading, spacing: 7) {
                    ForEach(model.burnInMetadataOptions) { option in
                        Toggle(option.label, isOn: metadataBinding(option.id))
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .help(option.source.isEmpty ? "Show \(option.label) in Custom Metadata." : "Show \(option.label) from \(option.source).")
                    }
                }
                Text("Selected items feed Custom Metadata. If nothing is selected, Turnover falls back to custom metadata from the source.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var analysisDetailsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
            ], alignment: .leading, spacing: 7) {
                ForEach(TurnoverModel.BurnInAnalysisDetail.allCases) { detail in
                    Toggle(detail.rawValue, isOn: analysisDetailBinding(detail))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
            }
            Text("Controls which analysis sub-items appear when a field uses Analysis Details.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var globalStyleSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            ColorPicker("Color", selection: globalTextColorBinding(), supportsOpacity: false)
            .onChange(of: model.burnInGlobalStyle) { _, _ in markCustom() }
            styleSliders(
                fontSize: $model.burnInGlobalStyle.fontSize,
                horizontalPadding: $model.burnInGlobalStyle.horizontalPadding,
                verticalPadding: $model.burnInGlobalStyle.verticalPadding,
                textOpacity: $model.burnInGlobalStyle.textOpacity,
                backgroundOpacity: $model.burnInGlobalStyle.backgroundOpacity
            )
        }
    }

    private var fieldStyleSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("Use global style for \(model.selectedBurnInAnchor.rawValue)", isOn: selectedField.usesGlobalStyle)
                .toggleStyle(.checkbox)
            Group {
                ColorPicker("Color", selection: fieldTextColorBinding(), supportsOpacity: false)
                styleSliders(
                    fontSize: selectedField.fontSize,
                    horizontalPadding: selectedField.horizontalPadding,
                    verticalPadding: selectedField.verticalPadding,
                    textOpacity: selectedField.textOpacity,
                    backgroundOpacity: selectedField.backgroundOpacity
                )
            }
            .disabled(selectedField.wrappedValue.usesGlobalStyle)
            .opacity(selectedField.wrappedValue.usesGlobalStyle ? 0.42 : 1)
            Text("Turn off global style only for fields that need their own size, color, or padding.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func styleSliders(
        fontSize: Binding<Double>,
        horizontalPadding: Binding<Double>,
        verticalPadding: Binding<Double>,
        textOpacity: Binding<Double>,
        backgroundOpacity: Binding<Double>
    ) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("Font \(Int(fontSize.wrappedValue))")
                    .frame(width: 74, alignment: .leading)
                Slider(value: fontSize, in: 4...96, step: 1)
            }
            HStack {
                Text("X Pad \(Int(horizontalPadding.wrappedValue))")
                    .frame(width: 74, alignment: .leading)
                Slider(value: horizontalPadding, in: 0...240, step: 1)
            }
            HStack {
                Text("Y Pad \(Int(verticalPadding.wrappedValue))")
                    .frame(width: 74, alignment: .leading)
                Slider(value: verticalPadding, in: 0...160, step: 1)
            }
            HStack {
                Text("Text \(Int(textOpacity.wrappedValue * 100))%")
                    .frame(width: 74, alignment: .leading)
                Slider(value: textOpacity, in: 0...1, step: 0.05)
            }
            HStack {
                Text("BG \(Int(backgroundOpacity.wrappedValue * 100))%")
                    .frame(width: 74, alignment: .leading)
                Slider(value: backgroundOpacity, in: 0...1, step: 0.05)
            }
        }
    }

    private var panelBackground: some ShapeStyle {
        Color.white.opacity(0.045)
    }

    private var preview: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 0.12, green: 0.14, blue: 0.16))
                if let player {
                    BurnInPlayerView(player: player, model: model, isPlaying: isPlaying)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 7) {
                        Image(systemName: "square.on.square.dashed")
                            .font(.largeTitle)
                        Button("Choose Video...") {
                            model.chooseBurnInVideo()
                        }
                        .controlSize(.small)
                        Text("Leave blank to export transparent ProRes 4444 overlay.")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                if player == nil {
                    burnInPreviewTextOverlay
                        .allowsHitTesting(false)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .contentShape(Rectangle())
            .onTapGesture {
                focusPreviewForPlayback()
            }
            .onHover { hovering in
                if hovering { focusPreviewForPlayback() }
            }
            .help("Click to focus playback controls. Use Choose Video to replace the preview movie.")

            if model.burnInDurationSeconds > 0 {
                HStack(spacing: 10) {
                    Button {
                        model.chooseBurnInVideo()
                    } label: {
                        Image(systemName: "film")
                    }
                    .buttonStyle(.borderless)
                    .turnoverHelp(model.burnInVideoURL == nil ? "Choose preview video" : "Replace preview video")

                    if model.burnInVideoURL != nil {
                        Button {
                            model.clearBurnInVideo()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .turnoverHelp("Clear preview video")
                    }

                    Button {
                        stepFrames(-1)
                    } label: {
                        Image(systemName: "backward.frame.fill")
                    }
                    .buttonStyle(.borderless)
                    .turnoverHelp("Step backward 1 frame (, or Left Arrow)")

                    Button {
                        togglePlayback()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .turnoverHelp("Play/Pause (Space)")

                    Button {
                        stepFrames(1)
                    } label: {
                        Image(systemName: "forward.frame.fill")
                    }
                    .buttonStyle(.borderless)
                    .turnoverHelp("Step forward 1 frame (. or Right Arrow)")

                    Text("\(playbackRate, specifier: "%.1f")x")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 44, alignment: .trailing)

                    ZStack {
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
                        if model.burnInExportInSeconds != nil || model.burnInExportOutSeconds != nil {
                            exportRangeIndicator
                                .frame(height: 4)
                                .padding(.horizontal, 8)
                                .allowsHitTesting(false)
                        }
                        currentFrameIndicator
                            .frame(height: 14)
                            .padding(.horizontal, 8)
                            .allowsHitTesting(false)
                    }
                    Text(model.burnInTimelineLabel)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 230, alignment: .trailing)
                    HStack(spacing: 4) {
                        Button {
                            model.markBurnInExportIn()
                        } label: {
                            Image(systemName: "arrow.right.to.line.compact")
                        }
                        .buttonStyle(.borderless)
                        .turnoverHelp("Set export In at the current preview frame (I)")

                        Button {
                            model.markBurnInExportOut()
                        } label: {
                            Image(systemName: "arrow.left.to.line.compact")
                        }
                        .buttonStyle(.borderless)
                        .turnoverHelp("Set export Out at the current preview frame (O)")

                        Button {
                            model.clearBurnInExportRange()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .turnoverHelp("Clear export range (X)")
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Button {
                        model.chooseBurnInVideo()
                    } label: {
                        Label(model.burnInVideoURL == nil ? "Choose Video" : "Replace Video", systemImage: "film")
                    }
                    .buttonStyle(.borderless)
                    .turnoverHelp(model.burnInVideoURL == nil ? "Choose preview video" : "Replace preview video")
                    if model.burnInVideoURL != nil {
                        Button {
                            model.clearBurnInVideo()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .turnoverHelp("Clear preview video")
                    }
                    Text("Build the manifest to enable frame-resolved timeline scrubbing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private var exportRangeIndicator: some View {
        GeometryReader { proxy in
            let duration = max(model.burnInDurationSeconds, 0.0001)
            let markIn = min(max(model.burnInExportInSeconds ?? 0, 0), duration)
            let markOut = min(max(model.burnInExportOutSeconds ?? duration, 0), duration)
            let start = min(markIn, markOut)
            let end = max(markIn, markOut)
            let hasRange = model.burnInExportInSeconds != nil || model.burnInExportOutSeconds != nil
            let startX = proxy.size.width * (start / duration)
            let width = max(2, proxy.size.width * ((end - start) / duration))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                if hasRange {
                    Capsule()
                    .fill(Color(red: 1.0, green: 0.60, blue: 0.18).opacity(0.95))
                        .frame(width: width)
                        .offset(x: startX)
                    rangeTick(at: startX)
                    rangeTick(at: min(proxy.size.width - 2, startX + width))
                }
            }
        }
        .turnoverHelp("Marked export range. Use Mark In and Mark Out to export only this section.")
    }

    private var currentFrameIndicator: some View {
        GeometryReader { proxy in
            let duration = max(model.burnInDurationSeconds, 0.0001)
            let position = min(max(model.burnInPositionSeconds, 0), duration)
            let centerX = proxy.size.width * (position / duration)
            let dotSize: CGFloat = 12
            Circle()
                .fill(Color.white)
                .frame(width: dotSize, height: dotSize)
                .shadow(color: .black.opacity(0.45), radius: 1, x: 0, y: 0)
                .offset(x: min(max(centerX - dotSize / 2, 0), max(0, proxy.size.width - dotSize)), y: 1)
        }
    }

    private func rangeTick(at x: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.9))
            .frame(width: 2, height: 8)
            .offset(x: x)
    }

    private var burnInPreviewTextOverlay: some View {
        GeometryReader { proxy in
            let timelineSize = model.burnInTimelineRenderSize()
            let scale = min(
                proxy.size.width / max(timelineSize.width, 1),
                proxy.size.height / max(timelineSize.height, 1)
            )
            ZStack {
                ForEach(model.burnInFields) { field in
                    let text = model.burnInPreviewText(for: field).trimmingCharacters(in: .whitespacesAndNewlines)
                    if field.enabled && !text.isEmpty {
                        burnInPreviewField(text: text, field: field, scale: scale)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func burnInPreviewField(text: String, field: TurnoverModel.BurnInField, scale: CGFloat) -> some View {
        let style = model.effectiveBurnInStyle(for: field)
        let fontSize = max(1, CGFloat(style.fontSize) * scale)
        let horizontalPadding = max(0, CGFloat(style.horizontalPadding) * scale)
        let verticalPadding = max(0, CGFloat(style.verticalPadding) * scale)
        let textInsetX = TurnoverModel.burnInTextInsetX * scale
        let textInsetY = TurnoverModel.burnInTextInsetY * scale
        let foreground = color(from: style.textColorValue ?? .preset(style.textColor))
            .opacity(max(0, min(1, style.textOpacity)))
        let background = Color.black.opacity(max(0, min(1, style.backgroundOpacity)))

        return Text(text)
            .font(.custom("Menlo-Semibold", size: fontSize))
            .foregroundStyle(foreground)
            .multilineTextAlignment(textAlignment(for: field.anchor))
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, textInsetX)
            .padding(.vertical, textInsetY)
            .background(background, in: RoundedRectangle(cornerRadius: TurnoverModel.burnInTextCornerRadius * scale))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(for: field.anchor))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
    }

    private var selectedField: Binding<TurnoverModel.BurnInField> {
        $model.burnInFields[model.selectedBurnInFieldIndex]
    }

    private func globalTextColorBinding() -> Binding<Color> {
        Binding(
            get: {
                color(from: model.burnInGlobalStyle.textColorValue ?? .preset(model.burnInGlobalStyle.textColor))
            },
            set: { color in
                model.burnInGlobalStyle.textColorValue = rgbaColor(from: color)
                markCustom()
            }
        )
    }

    private func fieldTextColorBinding() -> Binding<Color> {
        Binding(
            get: {
                color(from: selectedField.wrappedValue.textColorValue ?? .preset(selectedField.wrappedValue.textColor))
            },
            set: { color in
                selectedField.wrappedValue.textColorValue = rgbaColor(from: color)
                markCustom()
            }
        )
    }

    private func color(from rgba: TurnoverModel.BurnInRGBAColor) -> Color {
        Color(
            red: max(0, min(1, rgba.red)),
            green: max(0, min(1, rgba.green)),
            blue: max(0, min(1, rgba.blue)),
            opacity: max(0, min(1, rgba.alpha))
        )
    }

    private func alignment(for anchor: TurnoverModel.BurnInAnchor) -> Alignment {
        switch anchor {
        case .topLeft: .topLeading
        case .topCenter: .top
        case .topRight: .topTrailing
        case .middleLeft: .leading
        case .middleCenter: .center
        case .middleRight: .trailing
        case .bottomLeft: .bottomLeading
        case .bottomCenter: .bottom
        case .bottomRight: .bottomTrailing
        }
    }

    private func textAlignment(for anchor: TurnoverModel.BurnInAnchor) -> TextAlignment {
        switch anchor {
        case .topLeft, .middleLeft, .bottomLeft:
            .leading
        case .topCenter, .middleCenter, .bottomCenter:
            .center
        case .topRight, .middleRight, .bottomRight:
            .trailing
        }
    }

    private func rgbaColor(from color: Color) -> TurnoverModel.BurnInRGBAColor {
        let nsColor = NSColor(color)
        let rgb = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        return TurnoverModel.BurnInRGBAColor(
            red: Double(rgb.redComponent),
            green: Double(rgb.greenComponent),
            blue: Double(rgb.blueComponent),
            alpha: Double(rgb.alphaComponent)
        )
    }

    private func configurePlayer() {
        removePlayerTimeObserver()
        player?.pause()
        guard let url = model.burnInVideoURL else {
            player = nil
            return
        }
        let next = AVPlayer(url: url)
        next.isMuted = false
        next.volume = 1.0
        player = next
        isPlaying = false
        displayedPlaybackFrame = -1
        installPlayerTimeObserver(on: next)
    }

    private func installPlayerTimeObserver(on player: AVPlayer) {
        let frameDuration = max(model.burnInFrameDurationSeconds, 1.0 / 24.0)
        let interval = CMTime(seconds: frameDuration / 2, preferredTimescale: 600)
        playerTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor in
                guard isPlaying else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                updatePreviewPosition(fromPlayerSeconds: seconds, frameDuration: frameDuration)
            }
        }
    }

    private func removePlayerTimeObserver() {
        if let playerTimeObserver {
            player?.removeTimeObserver(playerTimeObserver)
        }
        playerTimeObserver = nil
    }

    private func markCustom() {
        // Presets are saved explicitly with the preset controls or Done.
    }

    private func focusPreviewForPlayback() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private struct TokenGroup: Identifiable {
        let title: String
        let items: [DataItem]

        var id: String { title }
    }

    private struct DataItem: Identifiable {
        let title: String
        let value: String

        var id: String { value }
    }

    private struct LabelTokenOption: Identifiable {
        let token: String
        let label: String

        var id: String { token }
    }

    private var labelTokenOptions: [LabelTokenOption] {
        [
            LabelTokenOption(token: "project", label: "Project"),
            LabelTokenOption(token: "event", label: "Event"),
            LabelTokenOption(token: "timeline_tc", label: "Timeline TC"),
            LabelTokenOption(token: "timeline_frame", label: "Frame"),
            LabelTokenOption(token: "timeline_fps", label: "Timeline FPS"),
            LabelTokenOption(token: "source_file", label: "File"),
            LabelTokenOption(token: "source_tc", label: "SrcTC"),
            LabelTokenOption(token: "source_frame", label: "Source Frame"),
            LabelTokenOption(token: "source_fps", label: "Source FPS"),
            LabelTokenOption(token: "clip_name", label: "Clip"),
            LabelTokenOption(token: "source_name", label: "Source"),
            LabelTokenOption(token: "source_reel", label: "Reel"),
            LabelTokenOption(token: "source_scene", label: "Scene"),
            LabelTokenOption(token: "source_take", label: "Take"),
            LabelTokenOption(token: "source_camera", label: "Camera"),
            LabelTokenOption(token: "source_angle", label: "Angle"),
            LabelTokenOption(token: "metadata_custom", label: "Metadata"),
            LabelTokenOption(token: "metadata_all", label: "All Metadata"),
            LabelTokenOption(token: "source_layers", label: "Layers"),
            LabelTokenOption(token: "source_layers_tc", label: "Layer TC"),
            LabelTokenOption(token: "source_layers_details", label: "Layer Details"),
            LabelTokenOption(token: "vfx_number", label: "VFX"),
            LabelTokenOption(token: "vfx_note", label: "Note"),
            LabelTokenOption(token: "audio_role", label: "Audio"),
            LabelTokenOption(token: "analysis_flags", label: "Analysis"),
            LabelTokenOption(token: "analysis_effects", label: "Effects"),
            LabelTokenOption(token: "analysis_transform", label: "Transform"),
            LabelTokenOption(token: "analysis_transform_position", label: "Pos"),
            LabelTokenOption(token: "analysis_transform_scale", label: "Scale"),
            LabelTokenOption(token: "analysis_transform_rotation", label: "Rot"),
            LabelTokenOption(token: "analysis_crop", label: "Crop"),
            LabelTokenOption(token: "analysis_distort", label: "Distort"),
            LabelTokenOption(token: "analysis_spatial_conform", label: "Conform"),
            LabelTokenOption(token: "analysis_conform_rate", label: "Rate"),
            LabelTokenOption(token: "analysis_retime", label: "Retime"),
            LabelTokenOption(token: "analysis_stabilization", label: "Stabilize"),
            LabelTokenOption(token: "analysis_optical_flow", label: "Optical Flow"),
            LabelTokenOption(token: "analysis_details", label: "Analysis Details"),
        ]
    }

    private var activeLabelTokenOptions: [LabelTokenOption] {
        let templates = model.burnInFields
            .map(\.template)
            .joined(separator: "\n")
        return labelTokenOptions.filter { templates.contains("{\($0.token)}") }
    }

    private var tokenGroups: [TokenGroup] {
        [
            TokenGroup(title: "Timeline", items: [
                DataItem(title: "Project", value: "{project}"),
                DataItem(title: "Event", value: "{event}"),
                DataItem(title: "Timeline TC", value: "{timeline_tc}"),
                DataItem(title: "Timeline Frame", value: "{timeline_frame}"),
                DataItem(title: "Timeline FPS", value: "{timeline_fps}"),
            ]),
            TokenGroup(title: "Visible Source", items: [
                DataItem(title: "Source Filename", value: "{source_file}"),
                DataItem(title: "Source TC", value: "{source_tc}"),
                DataItem(title: "Source Frame", value: "{source_frame}"),
                DataItem(title: "Source FPS", value: "{source_fps}"),
                DataItem(title: "Clip Name", value: "{clip_name}"),
                DataItem(title: "Source Name", value: "{source_name}"),
                DataItem(title: "Source Layers", value: "{source_layers}"),
                DataItem(title: "Source Layer TC", value: "{source_layers_tc}"),
                DataItem(title: "Source Layer Details", value: "{source_layers_details}"),
            ]),
            TokenGroup(title: "Source Metadata", items: [
                DataItem(title: "Reel", value: "{source_reel}"),
                DataItem(title: "Scene", value: "{source_scene}"),
                DataItem(title: "Take", value: "{source_take}"),
                DataItem(title: "Camera Name", value: "{source_camera}"),
                DataItem(title: "Angle", value: "{source_angle}"),
                DataItem(title: "Custom Metadata", value: "{metadata_custom}"),
                DataItem(title: "All Metadata", value: "{metadata_all}"),
            ]),
            TokenGroup(title: "VFX Title", items: [
                DataItem(title: "VFX Number", value: "{vfx_number}"),
                DataItem(title: "VFX Note", value: "{vfx_note}"),
            ]),
            TokenGroup(title: "Audio", items: [
                DataItem(title: "Audio Role", value: "{audio_role}"),
            ]),
            TokenGroup(title: "Conditions", items: [
                DataItem(title: "Conditional Text", value: "{custom_text}"),
            ]),
            TokenGroup(title: "Clip Analysis", items: [
                DataItem(title: "Analysis Flags", value: "{analysis_flags}"),
                DataItem(title: "Effects", value: "{analysis_effects}"),
                DataItem(title: "Position", value: "{analysis_transform_position}"),
                DataItem(title: "Scale", value: "{analysis_transform_scale}"),
                DataItem(title: "Rotation", value: "{analysis_transform_rotation}"),
                DataItem(title: "Crop", value: "{analysis_crop}"),
                DataItem(title: "Distort", value: "{analysis_distort}"),
                DataItem(title: "Spatial Conform", value: "{analysis_spatial_conform}"),
                DataItem(title: "Conform Rate", value: "{analysis_conform_rate}"),
                DataItem(title: "Retime", value: "{analysis_retime}"),
                DataItem(title: "Stabilize", value: "{analysis_stabilization}"),
                DataItem(title: "Optical Flow", value: "{analysis_optical_flow}"),
                DataItem(title: "Analysis Details", value: "{analysis_details}"),
            ]),
        ]
    }

    private func insertData(_ token: String) {
        let separator = selectedField.wrappedValue.template.isEmpty ? "" : " "
        selectedField.wrappedValue.template += separator + token
        markCustom()
    }

    private func appendData(_ token: String, to text: Binding<String>) {
        let separator = text.wrappedValue.isEmpty ? "" : " "
        text.wrappedValue += separator + token
        markCustom()
    }

    private func labelOverrideBinding(_ token: String) -> Binding<Bool> {
        Binding(
            get: { model.burnInLabelEnabled(for: token) },
            set: { enabled in
                model.setBurnInLabelEnabled(enabled, for: token)
                markCustom()
            }
        )
    }

    private func analysisDetailBinding(_ detail: TurnoverModel.BurnInAnalysisDetail) -> Binding<Bool> {
        Binding(
            get: { model.burnInAnalysisDetailEnabled(detail) },
            set: { enabled in
                model.setBurnInAnalysisDetailEnabled(enabled, for: detail)
                markCustom()
            }
        )
    }

    private func sourceLayerDetailBinding(_ detail: TurnoverModel.BurnInSourceLayerDetail) -> Binding<Bool> {
        Binding(
            get: { model.burnInSourceLayerDetailEnabled(detail) },
            set: { enabled in
                model.setBurnInSourceLayerDetailEnabled(enabled, for: detail)
                markCustom()
            }
        )
    }

    private func metadataBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.burnInMetadataEnabled(id: id) },
            set: { enabled in
                model.setBurnInMetadataEnabled(enabled, id: id)
                markCustom()
            }
        )
    }

    private func togglePlayback() {
        if isPlaying {
            player?.pause()
            snapPreviewToPlayer()
            isPlaying = false
        } else {
            player?.rate = playbackRate
            isPlaying = true
        }
    }

    private func stepFrames(_ count: Int) {
        let frameDuration = max(model.burnInFrameDurationSeconds, 1.0 / 24.0)
        let next = min(max(model.burnInPositionSeconds + (Double(count) * frameDuration), 0), model.burnInDurationSeconds)
        model.burnInPositionSeconds = next
        displayedPlaybackFrame = frameIndex(for: next, frameDuration: frameDuration)
        player?.pause()
        isPlaying = false
        player?.seek(to: CMTime(seconds: next, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func syncTimelineFromPlayer() {
        guard isPlaying else { return }
        let frameDuration = max(model.burnInFrameDurationSeconds, 1.0 / 24.0)
        if let player {
            let seconds = player.currentTime().seconds
            guard seconds.isFinite else { return }
            updatePreviewPosition(fromPlayerSeconds: seconds, frameDuration: frameDuration)
            return
        }
        let seconds: Double
        seconds = model.burnInPositionSeconds + (Double(playbackRate) * frameDuration)
        guard seconds.isFinite else { return }
        if model.burnInDurationSeconds > 0 {
            model.burnInPositionSeconds = min(max(seconds, 0), model.burnInDurationSeconds)
            if model.burnInPositionSeconds >= model.burnInDurationSeconds || model.burnInPositionSeconds <= 0 {
                player?.pause()
                isPlaying = false
            }
        }
    }

    private func snapPreviewToPlayer() {
        guard let player else { return }
        let frameDuration = max(model.burnInFrameDurationSeconds, 1.0 / 24.0)
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        let snapped = (seconds / frameDuration).rounded(.toNearestOrAwayFromZero) * frameDuration
        let clamped = min(max(snapped, 0), model.burnInDurationSeconds)
        model.burnInPositionSeconds = clamped
        displayedPlaybackFrame = frameIndex(for: clamped, frameDuration: frameDuration)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func updatePreviewPosition(fromPlayerSeconds seconds: Double, frameDuration: Double) {
        guard model.burnInDurationSeconds > 0 else { return }
        let clamped = min(max(seconds, 0), model.burnInDurationSeconds)
        let frame = frameIndex(for: clamped, frameDuration: frameDuration)
        guard frame != displayedPlaybackFrame else { return }
        displayedPlaybackFrame = frame
        model.burnInPositionSeconds = Double(frame) * frameDuration
        if clamped >= model.burnInDurationSeconds {
            player?.pause()
            isPlaying = false
        }
    }

    private func frameIndex(for seconds: Double, frameDuration: Double) -> Int {
        max(0, Int((seconds / max(frameDuration, 0.0001)).rounded(.down)))
    }

    private func handleKey(_ event: NSEvent) {
        focusPreviewForPlayback()
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ":
            togglePlayback()
        case "k":
            player?.pause()
            snapPreviewToPlayer()
            isPlaying = false
            playbackRate = 1.0
        case "l":
            playbackRate = min(playbackRate >= 1 ? playbackRate * 2 : 1, 8)
            player?.rate = playbackRate
            isPlaying = true
        case "j":
            playbackRate = max(playbackRate <= -1 ? playbackRate * 2 : -1, -8)
            player?.rate = playbackRate
            isPlaying = true
        case ",":
            stepFrames(-1)
        case ".":
            stepFrames(1)
        case "i":
            model.markBurnInExportIn()
        case "o":
            model.markBurnInExportOut()
        case "x":
            model.clearBurnInExportRange()
        default:
            switch event.keyCode {
            case 123:
                stepFrames(-1)
            case 124:
                stepFrames(1)
            default:
                break
            }
        }
    }
}

private struct BurnInPlayerView: NSViewRepresentable {
    let player: AVPlayer
    @ObservedObject var model: TurnoverModel
    let isPlaying: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerView.player = player
        context.coordinator.attach(to: view, player: player)
        return view
    }

    func updateNSView(_ view: PlayerContainerView, context: Context) {
        context.coordinator.model = model
        context.coordinator.isPlaying = isPlaying
        if view.playerView.player !== player {
            view.playerView.player = player
        }
        context.coordinator.attach(to: view, player: player)
        if !isPlaying {
            context.coordinator.resetFrameTracking()
        }
        context.coordinator.updateOverlay(force: true)
    }

    static func dismantleNSView(_ nsView: PlayerContainerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class PlayerContainerView: NSView {
        let playerView = AVPlayerView()
        let overlayView = NSView()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            playerView.controlsStyle = .none
            playerView.videoGravity = .resizeAspect
            playerView.translatesAutoresizingMaskIntoConstraints = false
            overlayView.translatesAutoresizingMaskIntoConstraints = false
            overlayView.wantsLayer = true
            overlayView.layer?.masksToBounds = false
            addSubview(playerView)
            addSubview(overlayView)
            NSLayoutConstraint.activate([
                playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
                playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
                playerView.topAnchor.constraint(equalTo: topAnchor),
                playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
                overlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
                overlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
                overlayView.topAnchor.constraint(equalTo: topAnchor),
                overlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            overlayView.layer?.frame = bounds
        }
    }

    @MainActor
    final class Coordinator {
        var model: TurnoverModel
        var isPlaying = false
        private weak var container: PlayerContainerView?
        private weak var player: AVPlayer?
        private weak var videoOutputItem: AVPlayerItem?
        private var videoOutput: AVPlayerItemVideoOutput?
        private var displayTimer: Timer?
        private var textLayers: [TurnoverModel.BurnInAnchor: CATextLayer] = [:]
        private var backgroundLayers: [TurnoverModel.BurnInAnchor: CALayer] = [:]
        private var lastFrame = -1
        private var lastSignature = ""

        init(model: TurnoverModel) {
            self.model = model
        }

        func attach(to container: PlayerContainerView, player: AVPlayer) {
            self.container = container
            self.player = player
            attachVideoOutput(to: player.currentItem)
            start()
            updateOverlay(force: true)
        }

        func start() {
            guard displayTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.tick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            displayTimer = timer
        }

        func stop() {
            displayTimer?.invalidate()
            displayTimer = nil
            if let videoOutput, let videoOutputItem {
                videoOutputItem.remove(videoOutput)
            }
            videoOutput = nil
            videoOutputItem = nil
            textLayers.removeAll()
            backgroundLayers.removeAll()
        }

        func tick() {
            guard let player else { return }
            guard isPlaying, abs(player.rate) > 0.0001 else { return }
            attachVideoOutput(to: player.currentItem)
            let seconds = displaySyncedSeconds(fallbackPlayer: player)
            guard seconds.isFinite else { return }
            let frameDuration = max(model.burnInFrameDurationSeconds, 1.0 / 24.0)
            let frame = max(0, Int((seconds / frameDuration).rounded(.down)))
            let signature = settingsSignature()
            guard frame != lastFrame || signature != lastSignature else { return }
            lastFrame = frame
            lastSignature = signature
            let snapped = min(max(Double(frame) * frameDuration, 0), model.burnInDurationSeconds)
            model.burnInPositionSeconds = snapped
            updateOverlay(force: true)
        }

        func resetFrameTracking() {
            lastFrame = -1
            lastSignature = ""
        }

        private func attachVideoOutput(to item: AVPlayerItem?) {
            guard let item else { return }
            if videoOutputItem === item, videoOutput != nil { return }
            if let videoOutput, let videoOutputItem {
                videoOutputItem.remove(videoOutput)
            }
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            videoOutput = output
            videoOutputItem = item
        }

        private func displaySyncedSeconds(fallbackPlayer player: AVPlayer) -> Double {
            if let videoOutput {
                let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
                if itemTime.seconds.isFinite {
                    return itemTime.seconds
                }
            }
            return player.currentTime().seconds
        }

        func updateOverlay(force: Bool = false) {
            guard let overlayLayer = container?.overlayView.layer else { return }
            let bounds = overlayLayer.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let activeAnchors = Set(model.burnInFields.filter(\.enabled).map(\.anchor))
            for anchor in TurnoverModel.BurnInAnchor.allCases where !activeAnchors.contains(anchor) {
                textLayers[anchor]?.removeFromSuperlayer()
                backgroundLayers[anchor]?.removeFromSuperlayer()
                textLayers[anchor] = nil
                backgroundLayers[anchor] = nil
            }
            for field in model.burnInFields where field.enabled {
                let text = model.burnInPreviewText(for: field).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    textLayers[field.anchor]?.isHidden = true
                    backgroundLayers[field.anchor]?.isHidden = true
                    continue
                }
                let style = model.effectiveBurnInStyle(for: field)
                let scale = previewScale(in: bounds.size)
                let frame = layerFrame(for: text, field: field, style: style, scale: scale, bounds: bounds)
                let backgroundLayer = backgroundLayers[field.anchor] ?? {
                    let layer = CALayer()
                    layer.masksToBounds = true
                    layer.actions = Self.disabledLayerActions
                    overlayLayer.addSublayer(layer)
                    backgroundLayers[field.anchor] = layer
                    return layer
                }()
                let textLayer = textLayers[field.anchor] ?? {
                    let layer = CATextLayer()
                    layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
                    layer.isWrapped = true
                    layer.actions = Self.disabledLayerActions
                    overlayLayer.addSublayer(layer)
                    textLayers[field.anchor] = layer
                    return layer
                }()
                backgroundLayer.removeAllAnimations()
                textLayer.removeAllAnimations()
                backgroundLayer.isHidden = false
                textLayer.isHidden = false
                backgroundLayer.frame = frame
                backgroundLayer.cornerRadius = TurnoverModel.burnInTextCornerRadius * scale
                backgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(style.backgroundOpacity).cgColor
                textLayer.frame = frame.insetBy(dx: TurnoverModel.burnInTextInsetX * scale, dy: TurnoverModel.burnInTextInsetY * scale)
                textLayer.string = text
                textLayer.font = "Menlo-Semibold" as CFTypeRef
                textLayer.fontSize = max(1, CGFloat(style.fontSize) * scale)
                textLayer.foregroundColor = NSColor(modelColor: style.textColorValue ?? .preset(style.textColor))
                    .withAlphaComponent(style.textOpacity)
                    .cgColor
                textLayer.alignmentMode = textAlignmentMode(field.anchor)
            }
            CATransaction.commit()
        }

        private func previewScale(in bounds: CGSize) -> CGFloat {
            let timeline = model.burnInTimelineRenderSize()
            return min(bounds.width / max(timeline.width, 1), bounds.height / max(timeline.height, 1))
        }

        private func layerFrame(
            for text: String,
            field: TurnoverModel.BurnInField,
            style: TurnoverModel.BurnInStyle,
            scale: CGFloat,
            bounds: CGRect
        ) -> CGRect {
            let fontSize = max(1, CGFloat(style.fontSize) * scale)
            let horizontalPadding = CGFloat(style.horizontalPadding) * scale
            let verticalPadding = CGFloat(style.verticalPadding) * scale
            let textInsetX = TurnoverModel.burnInTextInsetX * scale
            let textInsetY = TurnoverModel.burnInTextInsetY * scale
            let maxWidth = max(80 * scale, bounds.width - (horizontalPadding * 2))
            let font = NSFont(name: "Menlo-Semibold", size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .semibold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = nsTextAlignment(field.anchor)
            let measured = (text as NSString).boundingRect(
                with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font, .paragraphStyle: paragraph]
            )
            let size = CGSize(
                width: min(maxWidth, max(120 * scale, ceil(measured.width) + (textInsetX * 2))),
                height: max(fontSize * 1.35 + (textInsetY * 2), ceil(measured.height) + (textInsetY * 2))
            )
            let x: CGFloat
            switch field.anchor {
            case .topLeft, .middleLeft, .bottomLeft:
                x = horizontalPadding
            case .topCenter, .middleCenter, .bottomCenter:
                x = (bounds.width - size.width) / 2
            case .topRight, .middleRight, .bottomRight:
                x = bounds.width - horizontalPadding - size.width
            }
            let y: CGFloat
            switch field.anchor {
            case .bottomLeft, .bottomCenter, .bottomRight:
                y = verticalPadding
            case .middleLeft, .middleCenter, .middleRight:
                y = (bounds.height - size.height) / 2
            case .topLeft, .topCenter, .topRight:
                y = bounds.height - verticalPadding - size.height
            }
            return CGRect(x: max(0, x), y: max(0, y), width: size.width, height: size.height)
        }

        private static let disabledLayerActions: [String: CAAction] = [
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull(),
            "contents": NSNull(),
            "string": NSNull(),
            "foregroundColor": NSNull(),
            "backgroundColor": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull(),
        ]

        private func settingsSignature() -> String {
            let fields = model.burnInFields.map { field in
                [
                    field.anchor.rawValue,
                    String(field.enabled),
                    field.template,
                    String(field.usesGlobalStyle),
                    String(format: "%.2f", field.fontSize),
                    String(format: "%.2f", field.horizontalPadding),
                    String(format: "%.2f", field.verticalPadding),
                    field.textColor.rawValue,
                    field.textColorValue.map { String(format: "%.3f,%.3f,%.3f,%.3f", $0.red, $0.green, $0.blue, $0.alpha) } ?? "",
                    String(format: "%.3f", field.textOpacity),
                    String(format: "%.3f", field.backgroundOpacity),
                ].joined(separator: ",")
            }.joined(separator: ";")
            let style = model.burnInGlobalStyle
            let globalStyle = [
                String(format: "%.2f", style.fontSize),
                String(format: "%.2f", style.horizontalPadding),
                String(format: "%.2f", style.verticalPadding),
                style.textColor.rawValue,
                style.textColorValue.map { String(format: "%.3f,%.3f,%.3f,%.3f", $0.red, $0.green, $0.blue, $0.alpha) } ?? "",
                String(format: "%.3f", style.textOpacity),
                String(format: "%.3f", style.backgroundOpacity),
            ].joined(separator: ",")
            return [
                fields,
                globalStyle,
                String(model.burnInShowLabels),
                String(model.burnInShowFileExtensions),
                String(model.burnInLabelOverrides.hashValue),
                String(model.burnInAnalysisDetailOptions.hashValue),
                String(model.burnInMetadataSelections.hashValue),
                String(model.burnInSourceLayerLimit),
            ].joined(separator: "|")
        }

        private func textAlignmentMode(_ anchor: TurnoverModel.BurnInAnchor) -> CATextLayerAlignmentMode {
            switch anchor {
            case .topLeft, .middleLeft, .bottomLeft: .left
            case .topCenter, .middleCenter, .bottomCenter: .center
            case .topRight, .middleRight, .bottomRight: .right
            }
        }

        private func nsTextAlignment(_ anchor: TurnoverModel.BurnInAnchor) -> NSTextAlignment {
            switch anchor {
            case .topLeft, .middleLeft, .bottomLeft: .left
            case .topCenter, .middleCenter, .bottomCenter: .center
            case .topRight, .middleRight, .bottomRight: .right
            }
        }
    }
}

private extension NSColor {
    convenience init(modelColor color: TurnoverModel.BurnInRGBAColor) {
        self.init(
            calibratedRed: max(0, min(1, color.red)),
            green: max(0, min(1, color.green)),
            blue: max(0, min(1, color.blue)),
            alpha: max(0, min(1, color.alpha))
        )
    }
}

private struct BurnInKeyCaptureView: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onKeyDown: onKeyDown)
    }

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.onKeyDown = context.coordinator.onKeyDown
        context.coordinator.installMonitor(for: view)
        DispatchQueue.main.async {
            if view.window?.firstResponder == nil {
                view.window?.makeFirstResponder(view)
            }
        }
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        context.coordinator.onKeyDown = onKeyDown
        view.onKeyDown = context.coordinator.onKeyDown
        context.coordinator.installMonitor(for: view)
    }

    static func dismantleNSView(_ nsView: KeyView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        var onKeyDown: (NSEvent) -> Void
        private weak var view: NSView?
        private var monitor: Any?

        init(onKeyDown: @escaping (NSEvent) -> Void) {
            self.onKeyDown = onKeyDown
        }

        func installMonitor(for view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.shouldHandle(event) else { return event }
                self.onKeyDown(event)
                return nil
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func shouldHandle(_ event: NSEvent) -> Bool {
            guard event.window === view?.window else { return false }
            let key = event.charactersIgnoringModifiers?.lowercased()
            guard key.map({ [" ", "j", "k", "l", ",", ".", "i", "o", "x"].contains($0) }) == true
                || event.keyCode == 123
                || event.keyCode == 124 else { return false }
            if let responder = event.window?.firstResponder,
               String(describing: type(of: responder)).contains("Text") {
                return false
            }
            return true
        }
    }

    final class KeyView: NSView {
        var onKeyDown: ((NSEvent) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            onKeyDown?(event)
        }
    }
}

private struct TurnoverHelpModifier: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content
            .help(text)
    }
}

private extension View {
    func sectionLabelStyle() -> some View {
        font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(1.4)
            .foregroundStyle(.secondary)
    }

    func turnoverHelp(_ text: String) -> some View {
        modifier(TurnoverHelpModifier(text: text))
    }
}

private extension TurnoverModel.BurnInAnchor {
    var shortLabel: String {
        switch self {
        case .topLeft: "Top L"
        case .topCenter: "Top C"
        case .topRight: "Top R"
        case .middleLeft: "Mid L"
        case .middleCenter: "Mid C"
        case .middleRight: "Mid R"
        case .bottomLeft: "Bot L"
        case .bottomCenter: "Bot C"
        case .bottomRight: "Bot R"
        }
    }
}
